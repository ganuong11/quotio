//
//  QoderResponsesAdapter.swift
//  Quotio
//
//  Output translator for the OpenAI Responses API path (issue #11 Task A).
//
//  The OpenAI Responses API streams a different SSE event vocabulary than Chat
//  Completions: `response.created`, `response.output_text.delta`,
//  `response.completed`, ... instead of `chat.completion.chunk` frames. Qoder's
//  gateway only emits Chat Completions chunks, so Quotio's strategy (ADR 0014
//  + this issue) is to consume the OpenAI-shape chunks that `QoderSSEReparser`
//  ALREADY produces (the streaming path's normalized output) and re-encode them
//  as Responses API events.
//
//  It does NOT re-parse the Qoder envelope — there is exactly one parser of
//  that envelope (the reparser). This adapter sits at the SAME seam
//  `QoderCompletionAggregator` uses (see its `ingest(_:)` and the
//  `data: {...}\n\n` frame-peel), so the streaming path's byte output is fed
//  here unchanged.
//
//  Pure value type — no I/O, no actor state. `nonisolated struct` with
//  `mutating func ingest(_:)` and `mutating func finish()`, mirroring
//  `QoderCompletionAggregator`'s declaration style so the adapter opts out of
//  the project's MainActor default and is callable from any isolation domain.
//
//  Streaming-only for now (issue #11 Task A). The non-streaming Responses
//  shape is a separate follow-up; for `stream:false` the synthesized Chat body
//  still flows through the Chat path and Task B decides how to fold it.
//

import Foundation

/// Converts OpenAI Chat Completions SSE chunks (as emitted by
/// `QoderSSEReparser`) into OpenAI Responses API streaming events.
///
/// Bytes fed via `ingest(_:)` are `data: {...}\n\n` frames — exactly what the
/// reparser produces and what the streaming path writes to the socket. Frames
/// may split across `ingest` calls (TCP segmentation); a partial trailing
/// frame is buffered until its `\n\n` boundary arrives (same constraint as the
/// reparser's and the aggregator's line buffers).
///
/// After the upstream stream ends, `finish()` emits the terminal events
/// (`response.output_text.done`, `response.output_item.done`,
/// `response.function_call_arguments.done` as needed, and `response.completed`).
nonisolated struct QoderResponsesAdapter {

    /// Bytes received but not yet terminated by a frame boundary (`\n\n`).
    /// SSE frames can split across TCP segments — same constraint as the
    /// reparser's and the aggregator's buffers.
    private var buffer: String = ""

    /// Monotonically increasing sequence number for every emitted Responses
    /// event. OpenAI's Responses stream requires per-event `sequence_number`
    /// strictly increasing within a stream; we start at 1 and increment by 1
    /// per event so callers can assert monotonicity in tests.
    private var sequenceNumber: Int = 0

    /// Next sequence number to stamp on an emitted event. Pre-increment so the
    /// first event is sequence_number = 1 (matching OpenAI's convention).
    private mutating func nextSequence() -> Int {
        sequenceNumber += 1
        return sequenceNumber
    }

    /// Stable response id, stamped from the first chunk carrying `id`. OpenAI
    /// clients expect a stable id for a Response; when none arrives (or the
    /// caller overrides via `init`), synthesize `resp_qoder`.
    private var responseID: String

    /// Model stamped from the first chunk carrying `model`; falls back to the
    /// caller-supplied value or `""`. Surfaced on `response.created` /
    /// `response.completed`.
    private var model: String

    /// Created-at (unix seconds), stamped from the first chunk carrying
    /// `created`; falls back to "now" so timestamps are always present.
    private var createdAt: Int

    /// Stable id for the message output item synthesized from the assistant
    /// content stream. `msg_<responseID>` (or `msg_qoder` when no response id).
    private var messageItemID: String

    /// Whether the opener (response.created / in_progress / output_item.added /
    /// content_part.added) has fired. The opener is lazy: it fires on the FIRST
    /// content delta, not on construction or on a role-only opener chunk. This
    /// matches the reparser's lazy-emit posture (empty openers emit nothing).
    private var opened: Bool = false

    /// Concatenated `delta.content` across the stream. Becomes the
    /// `output_text.done` text and the message item's content in
    /// `response.completed`.
    private var content: String = ""

    /// Concatenated `delta.reasoning_content` across the stream. Surfaced via
    /// `reasoning_summary_text.delta`; we do not emit a full reasoning-item
    /// lifecycle (that's a follow-up — see file header).
    private var reasoning: String = ""

    /// Per-index tool-call accumulator, keyed by the Chat chunk's
    /// `tool_calls[].index`. Each index gets its own Responses output item
    /// (`fc_<index>`) and is allocated an `output_item.added` on first sight.
    /// `finish()` emits `function_call_arguments.done` and `output_item.done`
    /// for each.
    private var toolCalls: [Int: ToolCallAccumulator] = [:]

    /// Captured top-level `usage` from the chunks. Surfaced on
    /// `response.completed` with `prompt_tokens`→`input_tokens` /
    /// `completion_tokens`→`output_tokens` (Responses vocabulary).
    private var capturedUsage: [String: Any]?

    init(responseID: String? = nil, model: String? = nil) {
        let now = Int(Date().timeIntervalSince1970.rounded(.down))
        let id = responseID ?? ""
        self.responseID = id
        self.model = model ?? ""
        self.createdAt = now
        self.messageItemID = "msg_\(id.isEmpty ? "qoder" : id)"
    }

    // MARK: - Ingest

    /// Append reparser-output bytes (`data: {...}\n\n` frames), peel complete
    /// frames, and return the Responses-shaped SSE bytes to emit. Frames may
    /// straddle `ingest` calls. Returns empty `Data` when no complete frame is
    /// available yet (buffering) or when a frame carries no
    /// content/reasoning/tool delta to translate.
    ///
    /// Throws on malformed JSON inside a `data:` frame — same tolerance policy
    /// as the aggregator's `processFrame`. Today Task B treats the adapter as
    /// best-effort and lets the streaming reparser's gate own hard failures.
    mutating func ingest(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let text = String(data: data, encoding: .utf8) else { return Data() }
        buffer.append(text)

        // Peel complete frames on `\n\n`. CRLF normalized first (SSE allows
        // `\r\n\r\n`); same rationale as the aggregator's normalization.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")

        var out = Data()
        while let range = buffer.range(of: "\n\n") {
            let frame = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            out.append(processFrame(frame))
        }
        return out
    }

    /// Process one `\n\n`-delimited SSE frame. A frame may carry several SSE
    /// lines (`event:` + `data:`); only `data:` lines carry JSON here.
    private mutating func processFrame(_ frame: String) -> Data {
        var out = Data()
        for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let lineData = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            out.append(ingestChunk(chunk))
        }
        return out
    }

    /// Translate one parsed OpenAI streaming chunk into Responses events.
    /// Stamps `responseID` / `model` / `createdAt` from the first chunk
    /// carrying them (same rule as the aggregator) and emits the lazy opener
    /// on the first content delta.
    private mutating func ingestChunk(_ chunk: [String: Any]) -> Data {
        // Stamp stable id/model/created once. The init-supplied values are
        // fallbacks only — the stream wins when it carries them.
        if responseID.isEmpty, let id = chunk["id"] as? String, !id.isEmpty {
            responseID = id
            messageItemID = "msg_\(id)"
        }
        if model.isEmpty, let m = chunk["model"] as? String, !m.isEmpty {
            model = m
        }
        if let created = chunk["created"] as? Int {
            // Only stamp from the stream if init left the default (now). Keeps
            // a stable timestamp across the stream — same posture as the
            // aggregator, which sets createdAt from the first chunk.
            createdAt = created
        }
        if let usage = chunk["usage"] as? [String: Any], !usage.isEmpty {
            capturedUsage = usage
        }

        var out = Data()

        guard let choices = chunk["choices"] as? [Any], !choices.isEmpty else {
            return out
        }
        guard let choice = choices[0] as? [String: Any] else { return out }
        guard let delta = choice["delta"] as? [String: Any] else { return out }

        // Reasoning deltas ride on `reasoning_summary_text` per the Responses
        // spec. We do NOT emit a reasoning item lifecycle (a follow-up); we
        // only stream the summary text deltas.
        if let think = delta["reasoning_content"] as? String, !think.isEmpty {
            reasoning += think
            // The opener for the message item does NOT fire on reasoning —
            // reasoning rides a separate item in Responses. Emit a delta only.
            out.append(emitReasoningSummaryDelta(think))
        }

        // Content deltas fire the lazy opener (created/in_progress/added/
        // content_part.added) the first time, then stream output_text.delta.
        if let text = delta["content"] as? String, !text.isEmpty {
            if !opened {
                out.append(emitOpener())
                opened = true
            }
            content += text
            out.append(emitOutputTextDelta(text))
        }

        // Tool-call deltas allocate a Responses function_call output item per
        // Chat `tool_calls[].index` on first sight, then stream
        // function_call_arguments.delta fragments.
        if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty {
            for raw in calls {
                guard let tc = raw as? [String: Any] else { continue }
                out.append(ingestToolCall(tc))
            }
        }

        return out
    }

    /// Fold one tool-call delta into the per-index accumulator. On first sight
    /// of an index, emit `output_item.added` for a function_call item; always
    /// emit `function_call_arguments.delta` for the argument fragment.
    private mutating func ingestToolCall(_ tc: [String: Any]) -> Data {
        let index = (tc["index"] as? Int) ?? 0
        var acc = toolCalls[index] ?? ToolCallAccumulator(outputIndex: nextOutputIndexForTool())
        var out = Data()
        let isFirst = toolCalls[index] == nil
        if isFirst {
            if let id = tc["id"] as? String, !id.isEmpty { acc.callID = id }
            if let type = tc["type"] as? String, !type.isEmpty { acc.type = type }
            if let fn = tc["function"] as? [String: Any] {
                if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
            }
            out.append(emitToolCallItemAdded(acc))
        } else {
            // Update call_id/name if the stream re-sends them (rare but legal).
            if acc.callID.isEmpty, let id = tc["id"] as? String { acc.callID = id }
            if acc.name.isEmpty, let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String {
                acc.name = name
            }
        }
        if let fn = tc["function"] as? [String: Any] {
            if let args = fn["arguments"] as? String {
                acc.arguments += args
                out.append(emitFunctionCallArgumentsDelta(itemID: acc.itemID, outputIndex: acc.outputIndex, args: args))
            }
        }
        toolCalls[index] = acc
        return out
    }

    /// Allocate the next output_index for a function_call item. The message
    /// output item lives at output_index 0; tool calls get indices starting
    /// from 1 (or from 0 when no message content arrived — an all-tools
    /// response). This matches OpenAI's Responses layout where the assistant
    /// turn's output array carries items in arrival order.
    private func nextOutputIndexForTool() -> Int {
        // The message item claims index 0 only when it has fired its opener;
        // otherwise tool calls may start at 0.
        let base = opened ? 1 : 0
        return base + toolCalls.count
    }

    // MARK: - Finish

    /// Emit terminal events after the upstream stream ends. Order:
    ///   1. If content was emitted: output_text.done, content_part.done,
    ///      output_item.done for the message item.
    ///   2. For each tool call: function_call_arguments.done and
    ///      output_item.done for that item.
    ///   3. response.completed carrying the full Response object.
    ///
    /// Idempotent — a second call returns empty.
    mutating func finish() throws -> Data {
        var out = Data()

        // 1. Message-item terminals (only if content actually streamed).
        if !content.isEmpty {
            out.append(emitOutputTextDone())
            out.append(emitContentPartDone())
            out.append(emitMessageItemDone())
        }

        // 2. Per-tool-call terminals, in ascending index order for a stable
        // surface regardless of arrival order.
        let sortedToolIndices = toolCalls.keys.sorted()
        for idx in sortedToolIndices {
            guard let acc = toolCalls[idx] else { continue }
            out.append(emitFunctionCallArgumentsDone(acc))
            out.append(emitToolCallItemDone(acc))
        }

        // 3. response.completed with the full Response object.
        out.append(emitResponseCompleted())
        return out
    }

    // MARK: - Event emitters (Chat → Responses)

    /// The lazy opener: fires on the first content delta. Emits four events:
    ///   - response.created
    ///   - response.in_progress
    ///   - response.output_item.added (the message item)
    ///   - response.content_part.added (the output_text part)
    /// Each carries the next sequence_number.
    private mutating func emitOpener() -> Data {
        var out = Data()
        let response = responseObject(status: "in_progress")
        out.append(emitEvent("response.created", payload: [
            "type": "response.created",
            "response": response,
            "sequence_number": nextSequence(),
        ]))
        out.append(emitEvent("response.in_progress", payload: [
            "type": "response.in_progress",
            "response": responseObject(status: "in_progress"),
            "sequence_number": nextSequence(),
        ]))
        out.append(emitEvent("response.output_item.added", payload: [
            "type": "response.output_item.added",
            "output_index": 0,
            "item": messageItemShell(status: "in_progress", content: []),
            "sequence_number": nextSequence(),
        ]))
        out.append(emitEvent("response.content_part.added", payload: [
            "type": "response.content_part.added",
            "item_id": messageItemID,
            "output_index": 0,
            "content_index": 0,
            "part": outputTextPart(text: ""),
            "sequence_number": nextSequence(),
        ]))
        return out
    }

    /// `response.output_text.delta` — one per content delta chunk.
    private mutating func emitOutputTextDelta(_ text: String) -> Data {
        emitEvent("response.output_text.delta", payload: [
            "type": "response.output_text.delta",
            "item_id": messageItemID,
            "output_index": 0,
            "content_index": 0,
            "delta": text,
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.reasoning_summary_text.delta` — one per reasoning delta chunk.
    /// The reasoning rides under summary_index 0 of a synthesized `rs_<id>`
    /// item; the full reasoning item lifecycle is out of scope (follow-up).
    private mutating func emitReasoningSummaryDelta(_ text: String) -> Data {
        emitEvent("response.reasoning_summary_text.delta", payload: [
            "type": "response.reasoning_summary_text.delta",
            "item_id": "rs_\(responseID.isEmpty ? "qoder" : responseID)",
            "output_index": 0,
            "summary_index": 0,
            "delta": text,
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.output_item.added` for a function_call item. Emitted on first
    /// sight of a tool-call index, before its first argument fragment.
    private mutating func emitToolCallItemAdded(_ acc: ToolCallAccumulator) -> Data {
        emitEvent("response.output_item.added", payload: [
            "type": "response.output_item.added",
            "output_index": acc.outputIndex,
            "item": functionCallItemShell(acc, status: "in_progress"),
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.function_call_arguments.delta` — one per tool-call argument
    /// fragment.
    private mutating func emitFunctionCallArgumentsDelta(itemID: String, outputIndex: Int, args: String) -> Data {
        emitEvent("response.function_call_arguments.delta", payload: [
            "type": "response.function_call_arguments.delta",
            "item_id": itemID,
            "output_index": outputIndex,
            "delta": args,
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.output_text.done` — emitted by `finish()` when content
    /// accumulated. Carries the full text.
    private mutating func emitOutputTextDone() -> Data {
        emitEvent("response.output_text.done", payload: [
            "type": "response.output_text.done",
            "item_id": messageItemID,
            "output_index": 0,
            "content_index": 0,
            "text": content,
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.content_part.done` — the output_text part with full text.
    private mutating func emitContentPartDone() -> Data {
        emitEvent("response.content_part.done", payload: [
            "type": "response.content_part.done",
            "item_id": messageItemID,
            "output_index": 0,
            "content_index": 0,
            "part": outputTextPart(text: content),
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.output_item.done` for the message item, with content array
    /// populated and status "completed".
    private mutating func emitMessageItemDone() -> Data {
        emitEvent("response.output_item.done", payload: [
            "type": "response.output_item.done",
            "output_index": 0,
            "item": messageItemShell(status: "completed", content: [outputTextPart(text: content)]),
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.function_call_arguments.done` for one tool call. Carries the
    /// accumulated arguments + the function name.
    private mutating func emitFunctionCallArgumentsDone(_ acc: ToolCallAccumulator) -> Data {
        emitEvent("response.function_call_arguments.done", payload: [
            "type": "response.function_call_arguments.done",
            "item_id": acc.itemID,
            "output_index": acc.outputIndex,
            "name": acc.name,
            "arguments": acc.arguments,
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.output_item.done` for one function_call item, with
    /// status "completed" and the accumulated arguments.
    private mutating func emitToolCallItemDone(_ acc: ToolCallAccumulator) -> Data {
        emitEvent("response.output_item.done", payload: [
            "type": "response.output_item.done",
            "output_index": acc.outputIndex,
            "item": functionCallItemShell(acc, status: "completed"),
            "sequence_number": nextSequence(),
        ])
    }

    /// `response.completed` — full Response object with status "completed", the
    /// assembled output array (message item + function_call items), and the
    /// mapped usage block (null if none arrived).
    private mutating func emitResponseCompleted() -> Data {
        var output: [[String: Any]] = []
        // Message item only when content actually streamed — a pure tool-call
        // response has no message item.
        if !content.isEmpty {
            output.append(messageItemCompleted())
        }
        for idx in toolCalls.keys.sorted() {
            if let acc = toolCalls[idx] {
                output.append(functionCallItemCompleted(acc))
            }
        }
        var response = responseObject(status: "completed")
        response["output"] = output
        response["completed_at"] = Int(Date().timeIntervalSince1970.rounded(.down))
        if let capturedUsage {
            response["usage"] = mapUsage(capturedUsage)
        } else {
            response["usage"] = NSNull()
        }
        return emitEvent("response.completed", payload: [
            "type": "response.completed",
            "response": response,
            "sequence_number": nextSequence(),
        ])
    }

    // MARK: - Builders

    /// Minimal Response object: `{id, object:"response", created_at, status,
    /// model, output:[]}`. The `output` and `usage` fields are added by callers
    /// that need them (opener uses empty output; completed populates output +
    /// usage + completed_at).
    private func responseObject(status: String) -> [String: Any] {
        [
            "id": responseID.isEmpty ? "resp_qoder" : responseID,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "model": model,
            "output": [[String: Any]](),
        ]
    }

    /// The assistant message item shell. `content` is `[]` for the
    /// `output_item.added` opener and `[output_text part]` for `.done`.
    private func messageItemShell(status: String, content: [[String: Any]]) -> [String: Any] {
        [
            "id": messageItemID,
            "type": "message",
            "status": status,
            "role": "assistant",
            "content": content,
        ]
    }

    /// The completed assistant message item, with content array populated.
    private func messageItemCompleted() -> [String: Any] {
        messageItemShell(status: "completed", content: [outputTextPart(text: content)])
    }

    /// The `output_text` part shape: `{type:"output_text", text, annotations:[]}`.
    private func outputTextPart(text: String) -> [String: Any] {
        [
            "type": "output_text",
            "text": text,
            "annotations": [[String: Any]](),
        ]
    }

    /// The function_call item shell, used for both `.added` (status
    /// "in_progress") and `.done` (status "completed"). Carries the call_id,
    /// name, and accumulated arguments verbatim.
    private func functionCallItemShell(_ acc: ToolCallAccumulator, status: String) -> [String: Any] {
        [
            "id": acc.itemID,
            "type": "function_call",
            "status": status,
            "call_id": acc.callID,
            "name": acc.name,
            "arguments": acc.arguments,
        ]
    }

    /// The completed function_call item. Same shape as the shell with status
    /// "completed"; exposed separately for clarity at the call site.
    private func functionCallItemCompleted(_ acc: ToolCallAccumulator) -> [String: Any] {
        functionCallItemShell(acc, status: "completed")
    }

    /// Map a Chat `usage` block to Responses vocabulary:
    ///   - `prompt_tokens` → `input_tokens`
    ///   - `completion_tokens` → `output_tokens`
    ///   - `total_tokens` preserved
    /// Other fields (e.g. `cached_tokens`) are passed through unchanged.
    private func mapUsage(_ usage: [String: Any]) -> [String: Any] {
        var out = usage
        if let prompt = usage["prompt_tokens"] as? Int {
            out["input_tokens"] = prompt
            // Remove the Chat-vocabulary key so the surface matches the
            // Responses schema; OpenAI's Responses clients read input_tokens.
            out.removeValue(forKey: "prompt_tokens")
        }
        if let completion = usage["completion_tokens"] as? Int {
            out["output_tokens"] = completion
            out.removeValue(forKey: "completion_tokens")
        }
        return out
    }

    /// Serialize one event as a two-line SSE frame: `event: <type>\n` then
    /// `data: {<payload>}\n\n`. Mirrors the SSE wire shape the streaming path
    /// writes; OpenAI Responses clients split on `event:`/`data:` pairs.
    private func emitEvent(_ type: String, payload: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            return Data()
        }
        return Data("event: \(type)\n".utf8) + Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    // MARK: - Tool-call accumulator

    /// One tool-call index's accumulated state. `outputIndex` is the position
    /// in the Response's `output` array (allocated on first sight, stable
    /// thereafter). The `itemID` is `fc_<outputIndex>` for a stable, predictable
    /// id matching the spec's example shape.
    private struct ToolCallAccumulator {
        /// Output index in the Response's `output` array. Stable once allocated.
        let outputIndex: Int
        var itemID: String { "fc_\(outputIndex)" }
        /// OpenAI tool_call id (the value the prior function_call_output
        /// correlates on). Empty until the stream carries it.
        var callID: String = ""
        var type: String = "function"
        var name: String = ""
        /// Concatenated argument fragments — a JSON string built across deltas.
        var arguments: String = ""
    }
}
