//
//  OpencodeChatSSEAdapter.swift
//  Quotio
//
//  Output translator for the opencode Phase 2b arm (ADR 0021): a Chat
//  Completions client (`POST /v1/chat/completions`) requesting a
//  responses-native model (e.g. muse-spark) gets the upstream Responses SSE
//  event stream re-encoded as `chat.completion.chunk` frames — the mirror of
//  `QoderResponsesAdapter` (which goes chat→responses for the 2a arm).
//
//  Event mapping (plan Phase 2b):
//    - `response.output_text.delta` → `delta.content`
//    - `response.reasoning_summary_text.delta` /
//      `response.reasoning_text.delta` → `delta.reasoning_content` — the
//      repo's established chat-dialect for reasoning (the
//      `QoderThinkingTagParser` mapping), NOT think tags in content.
//    - `response.output_item.done` (function_call) → `delta.tool_calls`
//    - `response.completed` → `finish_reason` ("stop", or "tool_calls" when
//      function calls streamed) + usage (reverse-mapped to the chat
//      vocabulary, riding its own `choices:[]` chunk per the include_usage
//      convention) + `data: [DONE]`
//    - `response.incomplete` (`reason:"max_output_tokens"`) →
//      `finish_reason:"length"`; `content_filter` maps to itself
//    - `response.failed` → a chat-shaped terminal error frame + [DONE]
//    - clean EOF with no terminal event → synthesized `stop` terminal
//      (ADR 0018 precedent) + [DONE]
//
//  The emitted frames are exactly what `QoderCompletionAggregator` consumes,
//  so the non-streaming fold for this arm is adapter → aggregator (one
//  pipeline for both client modes).
//
//  Pure value type — no I/O, no actor state. `public nonisolated struct` with
//  `mutating func ingest(_:)` / `finish()`, mirroring
//  `QoderResponsesAdapter`'s declaration style so it opts out of the
//  project's MainActor default and is callable from any isolation domain.
//

import Foundation

public nonisolated struct OpencodeChatSSEAdapter {

    /// Bytes received but not yet terminated by a frame boundary (`\n\n`).
    /// Responses SSE frames can split across TCP segments — same constraint
    /// as the sibling adapters' buffers.
    private var buffer: String = ""

    /// Stable response id, stamped from the first event carrying one
    /// (`response.created`'s response object). Chat chunk ids are
    /// `chatcmpl-<responseID>`; synthesized `chatcmpl-opencode` when the
    /// stream never carried one.
    private var responseID: String = ""

    /// Model stamped on every chunk; the caller-supplied request model is
    /// the fallback (OpenAI echoes the request model).
    private let model: String

    /// Created-at (unix seconds), stamped from the response object; falls
    /// back to "now" so timestamps are always present.
    private var createdAt: Int

    /// Whether the assistant-role opener chunk has fired. Lazy — it rides
    /// the first delta of any channel (content, reasoning, or tool calls),
    /// matching the ADR 0011 chunk template posture (empty openers emit
    /// nothing).
    private var opened: Bool = false

    /// Next `tool_calls[].index`. Responses delivers complete function_call
    /// items; each becomes one delta at the next chat index.
    private var toolCallIndex: Int = 0

    /// Whether any function_call item streamed — decides the synthesized
    /// `finish_reason` ("tool_calls" vs "stop") on `response.completed`.
    private var sawToolCalls: Bool = false

    /// Whether a terminal (completed/incomplete/failed/error) already
    /// emitted its finish sequence — makes `finish()` idempotent-empty and
    /// drops any events after the terminal (nothing may follow [DONE]).
    private var terminalEmitted: Bool = false

    /// Whether the upstream reported a failure (`response.failed` or a
    /// top-level `error` event). Surfaced so the non-streaming fold can
    /// answer with a true HTTP error instead of folding the error frame's
    /// (choices-less) bytes into an empty-but-200 completion.
    private(set) var failed: Bool = false

    /// The upstream's failure message when `failed` — relayed by the
    /// non-streaming fold's error response.
    private(set) var failureMessage: String?

    public init(model: String) {
        self.model = model
        self.createdAt = Int(Date().timeIntervalSince1970.rounded(.down))
    }

    // MARK: - Ingest

    /// Append Responses-SSE bytes, peel complete `data: {...}\n\n` frames,
    /// and return the chat-chunk SSE bytes to emit. Frames may straddle
    /// `ingest` calls. Returns empty `Data` when nothing complete is
    /// available yet or an event carries no translatable delta.
    public mutating func ingest(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        guard let text = String(data: data, encoding: .utf8) else { return Data() }
        buffer.append(text)

        // Peel complete frames on `\n\n`. CRLF normalized first (SSE allows
        // `\r\n\r\n`); same rationale as the sibling adapters.
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
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            out.append(handleEvent(event))
        }
        return out
    }

    private mutating func handleEvent(_ event: [String: Any]) -> Data {
        guard let type = event["type"] as? String else { return Data() }
        // One terminal per stream: everything after it (a second terminal,
        // stray deltas) would emit chunks after [DONE] — drop them.
        guard !terminalEmitted else { return Data() }
        switch type {
        case "response.created", "response.in_progress":
            stampIdentity(event["response"])
            return Data()
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return Data() }
            var out = openerIfNeeded()
            out.append(chunk(delta: ["content": delta]))
            return out
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return Data() }
            var out = openerIfNeeded()
            out.append(chunk(delta: ["reasoning_content": delta]))
            return out
        case "response.output_item.done":
            return handleItemDone(event["item"])
        case "response.completed", "response.incomplete":
            return handleTerminal(
                type: type,
                response: event["response"],
                incompleteReason: (event["response"] as? [String: Any]).flatMap {
                    ($0["incomplete_details"] as? [String: Any])?["reason"] as? String
                })
        case "response.failed":
            return handleFailure(response: event["response"])
        case "error":
            // A top-level Responses error event — same terminal posture as
            // response.failed, with the event's own error object.
            return emitErrorFrame(errorObject: event["error"])
        default:
            // output_item.added / content_part.* / *text.done / function_
            // call_arguments.* — lifecycle scaffolding with no chat-chunk
            // equivalent (the .done items carry the complete calls).
            return Data()
        }
    }

    /// Stamp id/created from a response object if not yet stamped.
    private mutating func stampIdentity(_ raw: Any?) {
        guard let response = raw as? [String: Any] else { return }
        if responseID.isEmpty, let id = response["id"] as? String, !id.isEmpty {
            responseID = id
        }
        if let created = response["created_at"] as? Int {
            createdAt = created
        }
    }

    /// The lazy assistant-role opener chunk (ADR 0011 chunk template):
    /// empty until the first delta of any channel, then fired once.
    private mutating func openerIfNeeded() -> Data {
        guard !opened else { return Data() }
        opened = true
        return chunk(delta: ["role": "assistant", "content": ""])
    }

    /// `response.output_item.done`: function_call items become complete
    /// `delta.tool_calls` entries at the next chat index; message items are
    /// already streamed via their deltas.
    private mutating func handleItemDone(_ raw: Any?) -> Data {
        guard let item = raw as? [String: Any],
              (item["type"] as? String) == "function_call" else { return Data() }
        sawToolCalls = true
        var call: [String: Any] = ["index": toolCallIndex, "type": "function"]
        toolCallIndex += 1
        if let id = item["call_id"] as? String, !id.isEmpty { call["id"] = id }
        var function: [String: Any] = [:]
        if let name = item["name"] as? String { function["name"] = name }
        // Always carry arguments (even "") — the chat schema requires the
        // field under `function`.
        function["arguments"] = (item["arguments"] as? String) ?? ""
        call["function"] = function
        var out = openerIfNeeded()
        out.append(chunk(delta: ["tool_calls": [call]]))
        return out
    }

    /// `response.completed` / `response.incomplete`: finish_reason chunk,
    /// usage chunk (when present), and the [DONE] sentinel.
    private mutating func handleTerminal(
        type: String, response raw: Any?, incompleteReason: String?
    ) -> Data {
        terminalEmitted = true
        stampIdentity(raw)

        let finishReason: String
        if type == "response.completed" {
            finishReason = sawToolCalls ? "tool_calls" : "stop"
        } else {
            finishReason = incompleteReason == "content_filter" ? "content_filter" : "length"
        }

        var out = chunk(delta: [:], finishReason: finishReason)
        if let response = raw as? [String: Any],
           let usage = response["usage"] as? [String: Any], !usage.isEmpty {
            out.append(usageChunk(Self.reverseMapUsage(usage)))
        }
        out.append(doneSentinel())
        return out
    }

    /// `response.failed`: re-emit the upstream error object verbatim in a
    /// chat-shaped terminal frame (byte-faithful posture — ADR 0020/0021),
    /// then [DONE]. No finish_reason chunk follows a failure.
    private mutating func handleFailure(response raw: Any?) -> Data {
        terminalEmitted = true
        stampIdentity(raw)
        let error = (raw as? [String: Any])?["error"]
        return emitErrorFrame(errorObject: error)
    }

    /// A chat-shaped terminal error frame. Re-emits a well-formed upstream
    /// error object verbatim; fabricates a minimal envelope otherwise.
    private mutating func emitErrorFrame(errorObject: Any?) -> Data {
        terminalEmitted = true
        failed = true
        let error: [String: Any]
        if let upstream = errorObject as? [String: Any], upstream["message"] != nil {
            error = upstream
            failureMessage = upstream["message"] as? String
        } else {
            error = [
                "message": "opencode responses stream failed.",
                "type": "internal_server_error",
            ]
            failureMessage = nil
        }
        guard let json = try? JSONSerialization.data(withJSONObject: ["error": error]) else {
            return doneSentinel()
        }
        return Data("data: ".utf8) + json + Data("\n\n".utf8) + doneSentinel()
    }

    // MARK: - Finish

    /// Emit the terminal sequence after the upstream stream ends. A terminal
    /// event already emitted it — returns empty (idempotent). A clean EOF
    /// with NO terminal synthesizes the `stop` finish (ADR 0018 precedent:
    /// better a short-but-successful completion than an unusable stream) +
    /// [DONE]. Idempotent — a second call returns empty.
    public mutating func finish() throws -> Data {
        guard !terminalEmitted else { return Data() }
        terminalEmitted = true
        return chunk(delta: [:], finishReason: sawToolCalls ? "tool_calls" : "stop")
            + doneSentinel()
    }

    /// ADR 0010: a chat-shaped SSE terminal frame for a mid-stream
    /// TRANSPORT failure (after the `200 OK` head shipped and the HTTP
    /// status can no longer change). Reuses `QoderOpenAIError`'s builder —
    /// one error-envelope source of truth across the chat-surface paths.
    /// Does NOT go through `ingest`; the frame is built directly. Appends
    /// [DONE] (the chat surface's sentinel).
    public mutating func errorEvent(message: String) -> Data {
        QoderOpenAIError.sseTerminalFrame(statusCode: 502, message: message)
    }

    // MARK: - Chunk builders

    /// One `chat.completion.chunk` frame. `delta` is the choices[0].delta
    /// payload; `finishReason` rides choices[0] when non-nil (JSON null
    /// otherwise, per OpenAI's streaming schema).
    private func chunk(delta: [String: Any], finishReason: String? = nil) -> Data {
        let payload: [String: Any] = [
            "id": chunkID,
            "object": "chat.completion.chunk",
            "created": createdAt,
            "model": model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason.map { $0 as Any } ?? NSNull(),
            ]],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            return Data()
        }
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// The usage carrier: its own chunk with `choices: []` — the OpenAI
    /// include_usage convention (the 2a arm injects the flag for the same
    /// reason; on this arm usage rides the responses terminal event).
    private func usageChunk(_ usage: [String: Any]) -> Data {
        let payload: [String: Any] = [
            "id": chunkID,
            "object": "chat.completion.chunk",
            "created": createdAt,
            "model": model,
            "choices": [[String: Any]](),
            "usage": usage,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            return Data()
        }
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    private var chunkID: String {
        "chatcmpl-\(responseID.isEmpty ? "opencode" : responseID)"
    }

    private func doneSentinel() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }

    /// Responses usage → Chat vocabulary: `input_tokens`→`prompt_tokens`,
    /// `output_tokens`→`completion_tokens`; `total_tokens` and any extras
    /// pass through. The reverse of `QoderResponsesAdapter.mapUsage`.
    private static func reverseMapUsage(_ usage: [String: Any]) -> [String: Any] {
        var out = usage
        if let input = usage["input_tokens"] as? Int {
            out["prompt_tokens"] = input
            out.removeValue(forKey: "input_tokens")
        }
        if let output = usage["output_tokens"] as? Int {
            out["completion_tokens"] = output
            out.removeValue(forKey: "output_tokens")
        }
        return out
    }
}
