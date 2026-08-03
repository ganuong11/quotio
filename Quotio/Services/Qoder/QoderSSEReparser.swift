//
//  QoderSSEReparser.swift
//  Quotio
//
//  Phase 2a → 2b (ADR 0001, ADR 0004, ADR 0005, ADR 0007 §3): parses Qoder's
//  SSE response frames and emits OpenAI-shape SSE deltas for the CLI agent.
//  Pure value type — no I/O, no actor state. Owned as a `var` inside the
//  ProxyBridge actor (ticket #7), which feeds raw upstream bytes in and writes
//  the returned OpenAI-shape bytes to the agent socket.
//
//  Reference: pi-provider-qoder/src/stream.ts lines ~290-470 (SSE parse loop).
//  Ported for algorithmic parity; the OpenAI re-encode is a Quotio addition
//  (pi emits pi-ai SDK events, not OpenAI SSE).
//
//  Phase 2b surface (full parity):
//   - `delta.content` → fed through `QoderThinkingTagParser` so thinking tags
//     embedded in the content stream split into `delta.reasoning_content`
//     (thinking) and `delta.content` (text). One thinking block per stream
//     (pi's one-shot `thinkingExtracted` rule).
//   - `delta.reasoning_content` → `stripThinkingTags` then re-emit as
//     `delta.reasoning_content`. Qoder's backend sometimes routes a literal
//     `<thinking>` opener into this channel (closer into `content`); stripping
//     keeps the thinking block clean (ADR 0004 §Decision).
//   - `delta.tool_calls` → OpenAI `delta.tool_calls`, streamed fragment by
//     fragment (index-keyed state machine so each index's id/name land once
//     and argument fragments accumulate on the agent side as OpenAI expects).
//   - `inner.usage` (final chunk) → OpenAI `usage`, passed through verbatim.
//     Per ADR 0005 §2, Qoder follows OpenAI semantics (`prompt_tokens`
//     INCLUDES `cached_tokens`); do NOT replicate pi's cache subtraction.
//

import Foundation

/// Errors thrown while reparsing Qoder's SSE stream into OpenAI-shape SSE.
/// None of these carry token/secret content. ProxyBridge (ticket #7) maps each
/// to its wire representation — a mid-stream abort.
nonisolated enum QoderSSEReparserError: Error, LocalizedError {
    /// Qoder envelope's `statusCodeValue` was non-200. Pi throws in the same
    /// spot; ProxyBridge terminates the agent stream. Snippet is ≤200 chars,
    /// redacted of any `pt-`/`jt-` runs (QoderPATService convention).
    case upstreamStatus(status: Int, snippet: String)
    /// A `data:` line carried malformed JSON. Pi skips these (a single bad
    /// SSE line shouldn't kill the stream); we surface them so ProxyBridge can
    /// decide — most callers will log-and-continue via the throwing `feed`.
    case malformedSSELine(snippet: String)

    var errorDescription: String? {
        switch self {
        case .upstreamStatus(let status, let snippet):
            let capped = String(snippet.prefix(200))
            return capped.isEmpty
                ? "Qoder upstream returned status \(status)."
                : "Qoder upstream returned status \(status): \(capped)"
        case .malformedSSELine(let snippet):
            return "Qoder SSE: malformed line (\(String(snippet.prefix(120))))."
        }
    }
}

/// Parses Qoder SSE → OpenAI SSE. Owns the line buffer and the per-stream
/// state (response ID, model, stashed usage/finish_reason).
///
/// Not `Sendable` by intent: ProxyBridge holds it as a per-request `var` and
/// never shares it. A `struct` with `mutating func feed` keeps the reparser
/// trivially testable (no actor hops in tests) and isolated to the owning
/// actor's domain in production. AGENTS.md's actor rule scopes to async
/// services; this is synchronous.
///
/// `nonisolated struct` → callable from any isolation domain (the project's
/// default isolation is MainActor; a pure synchronous value type opts out
/// explicitly, like `QoderWAFEncoder` / `QoderCOSYSigner`).
nonisolated struct QoderSSEReparser {
    /// Bytes received but not yet terminated by `\n`. SSE frames can split
    /// across TCP segments, so partial trailing lines must survive a `feed`
    /// call (advisor watch-item).
    private var buffer: String = ""

    /// Response ID from the first chunk carrying `inner.id`. Stamped on every
    /// emitted OpenAI chunk so agents can correlate (OpenAI clients expect a
    /// stable `id`).
    private var responseID: String?

    /// Model from the first chunk carrying `inner.model`. Same treatment.
    private var model: String?

    /// Created-at timestamp, set once on the first chunk so all emitted chunks
    /// share it (advisor watch-item). Matches OpenAI's `created` (unix seconds).
    private let created: Int

    /// Stashed `usage` from the final chunk. Emitted in the last OpenAI chunk
    /// (OpenAI puts usage on the final chunk, optionally behind a
    /// `stream_options: {include_usage: true}` request — we always include it).
    ///
    /// `internal` so ProxyBridge's Qoder pump (ticket #7) can read the final
    /// usage after `finish()` and populate `RequestMetadata`'s token fields for
    /// the Quotio-side usage accumulator (ADR 0005 §2). OpenAI semantics
    /// (`prompt_tokens` INCLUDES `cached_tokens`) — pass through unchanged.
    private(set) var stashedUsage: [String: Any]?

    /// Read-only accessor for the captured usage block, used by ProxyBridge
    /// (ticket #7) after the stream ends to populate `RequestMetadata` token
    /// fields. Returns nil if the upstream stream never carried a usage chunk.
    var capturedUsage: [String: Any]? { stashedUsage }

    /// Stashed `finish_reason`. Emitted on the final chunk before `[DONE]`.
    private var stashedFinishReason: String?

    /// Whether `finish()` has emitted its terminal `[DONE]`. Guards against
    /// double-emit on repeated `finish()` calls.
    private var finished: Bool = false

    /// Streaming splitter for thinking tags embedded in the `content` channel
    /// (Phase 2b). One per stream — owns cross-delta buffering and the one-shot
    /// "first thinking block only" rule. See `QoderThinkingTagParser`.
    private var thinkingParser: QoderThinkingTagParser = QoderThinkingTagParser()

    /// Per-stream tool-call state, keyed by the OpenAI `tool_calls[].index`.
    /// Phase 2b port of pi's `toolCallsState` (stream.ts ~29, 407-435). Tracks
    /// whether each index has emitted its first delta (so id/type/name ride the
    /// first chunk and argument fragments stream after). We re-emit each
    /// fragment as an OpenAI `delta.tool_calls` chunk (true streaming), unlike
    /// pi which buffers arguments and JSON.parses at stream end — that's pi-ai
    /// `toolcall_end` machinery ADR 0004 explicitly skips. The non-empty check
    /// also drives the `finish_reason: "tool_calls"` override (OpenAI clients
    /// require this when tool_calls streamed, else the stream is malformed).
    private var toolCallsState: [Int: QoderToolCallState] = [:]

    /// New reparser. `created` defaults to now; tests can pin via the second
    /// initializer to assert byte-exact OpenAI chunk output.
    init() {
        self.created = Int(Date().timeIntervalSince1970.rounded(.down))
    }

    /// Test initializer pinning the `created` timestamp.
    init(created: Int) {
        self.created = created
    }

    // MARK: - Feed

    /// Append raw upstream bytes, parse complete SSE lines, and return the
    /// OpenAI-shape SSE bytes to write to the agent socket. Returns empty
    /// `Data` when no complete frame is available yet (buffering).
    ///
    /// Throws on `statusCodeValue != 200` and malformed JSON lines. A thrown
    /// error does NOT corrupt the reparser state — the caller may continue
    /// feeding if it chooses to swallow `.malformedSSELine` (pi's behavior).
    mutating func feed(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        guard let chunk = String(data: data, encoding: .utf8) else {
            throw QoderSSEReparserError.malformedSSELine(snippet: "<non-UTF8 chunk>")
        }
        buffer.append(chunk)
        // Normalize line endings: SSE allows `\r\n` and bare `\r`. Swift String
        // treats `\r\n` as one grapheme cluster, so `firstIndex(of: "\n")`
        // would miss it — collapse to `\n` first. `replacingOccurrences` uses
        // NSString (UTF16) semantics, so it sees `\r\n` even though Swift's
        // grapheme-based `contains("\r")` does not (which is why we run the
        // replacement unconditionally). Doing this on the full buffer per feed
        // is O(n) but n is small (one TCP chunk), and it correctly stitches a
        // `\r` at the tail of the previous feed to a `\n` at the head of the
        // next.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
        return try drainLines(terminal: false)
    }

    /// Flush the buffer and emit the terminal `[DONE]`. Call once the upstream
    /// stream ends. Idempotent — a second call returns empty.
    ///
    /// If a usage block was stashed but no chunk yet carried it (e.g. the
    /// upstream ended on a chunk with usage AND finish_reason together, which
    /// the parse loop already emitted), `finish` still emits a final usage-only
    /// chunk when usage is stashed, matching OpenAI's `stream_options.include_usage`
    /// behavior of a trailing usage chunk.
    mutating func finish() throws -> Data {
        guard !finished else { return Data() }
        finished = true
        var out = try drainLines(terminal: true)

        // Flush the thinking-tag parser: any held-back partial-tag prefix at
        // the tail of the last content delta (or an open thinking block whose
        // closer never arrived) must surface before [DONE]. Phase 2b — pi
        // does this in stream.ts ~459-461 (`thinkingParser.finalize()`).
        let pendingEmissions = thinkingParser.finalize()
        for emission in pendingEmissions {
            switch emission {
            case .text(let text):
                out.append(buildContentChunk(text))
            case .thinking(let thinking):
                out.append(buildReasoningChunk(thinking))
            }
        }

        // Trailing usage chunk (OpenAI convention: usage rides on its own
        // final chunk with an empty `choices` array). Only emit if we have
        // stashed usage that wasn't already attached to a content chunk.
        if let usage = stashedUsage {
            let chunk = buildChunk(delta: nil, finishReason: nil, usage: usage)
            out.append(chunk)
        }
        out.append(contentsOf: "data: [DONE]\n\n".utf8)
        return out
    }

    // MARK: - Line parsing

    /// Drain complete `\n`-terminated lines from the buffer. `terminal` keeps
    /// the final partial line (no trailing `\n`) in the buffer when false,
    /// and forces it through when true (stream end).
    private mutating func drainLines(terminal: Bool) throws -> Data {
        var out = Data()
        while true {
            // SSE lines end with `\n`. Pi splits on `\n` then `.trim()`s, so
            // `\r\n` and bare `\r` are handled by trimming. We mirror that.
            guard let nlIndex = buffer.firstIndex(of: "\n") else {
                if terminal && !buffer.isEmpty {
                    let leftover = buffer
                    buffer.removeAll(keepingCapacity: false)
                    do {
                        let lineData = try processLine(leftover)
                        if !lineData.isEmpty { out.append(lineData) }
                    } catch QoderSSEReparserError.malformedSSELine {
                        // Pi skips malformed SSE lines (pi parity). Buffer is
                        // already drained; just drop the leftover.
                    }
                    // Non-malformed throws (e.g. .upstreamStatus) propagate
                    // and the buffer is already drained — acceptable, a thrown
                    // upstream status means we're terminating anyway.
                }
                return out
            }
            let line = String(buffer[buffer.startIndex..<nlIndex])
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            do {
                let lineData = try processLine(line)
                if !lineData.isEmpty { out.append(lineData) }
            } catch QoderSSEReparserError.malformedSSELine {
                // Pi skips malformed SSE lines (a single bad line shouldn't
                // kill the stream). Mirror that by swallowing here; callers
                // who want strict mode can switch on the thrown type at a
                // higher seam. The buffer is already past this line.
                continue
            }
        }
    }

    /// Process one SSE line (already `\n`-stripped). Returns the OpenAI-shape
    /// SSE bytes to emit (empty if the line produced no output). A single
    /// inner delta can carry reasoning + content + tool_calls, so this may
    /// concatenate several OpenAI chunks; pi's order is preserved
    /// (reasoning_content → content → tool_calls, stream.ts ~349-435).
    ///
    /// Throws on `statusCodeValue != 200` and on malformed JSON. Throws
    /// `.malformedSSELine` for JSON parse failures — the caller (`drainLines`)
    /// swallows those by default (pi parity).
    private mutating func processLine(_ rawLine: String) throws -> Data {
        // Surrounding whitespace trim (SSE spec: ignore leading/trailing
        // spaces around the field). CRLF was already collapsed in `feed`.
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return Data() }   // SSE event boundary
        if line.hasPrefix(":") { return Data() }   // SSE comment / keep-alive
        if !line.hasPrefix("data:") { return Data() }   // ignore `event:`, `id:`, `retry:`
        let dataStr = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if dataStr.isEmpty { return Data() }
        if dataStr == "[DONE]" { return Data() }   // upstream [DONE] handled by finish()

        // Parse outer envelope. A malformed line throws and is swallowed by
        // drainLines (pi parity).
        guard let envelopeData = dataStr.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
            throw QoderSSEReparserError.malformedSSELine(snippet: dataStr)
        }

        // Upstream status gate. Pi throws on non-200; we propagate.
        if let statusCodeValue = envelope["statusCodeValue"] as? Int,
           statusCodeValue != 200 {
            let body = envelope["body"]
            let snippet = Self.redactedSnippet(body)
            throw QoderSSEReparserError.upstreamStatus(status: statusCodeValue, snippet: snippet)
        }

        // Inner body is itself a JSON *string* (Qoder's JSON-in-JSON envelope).
        // Empty / "[DONE]" inner → no chunk to emit.
        guard let innerStr = envelope["body"] as? String,
              !innerStr.isEmpty,
              innerStr != "[DONE]" else {
            return Data()
        }
        guard let innerData = innerStr.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            throw QoderSSEReparserError.malformedSSELine(snippet: innerStr)
        }

        // Stamp response ID / model on first appearance.
        if responseID == nil, let id = inner["id"] as? String, !id.isEmpty {
            responseID = id
        }
        if model == nil, let m = inner["model"] as? String, !m.isEmpty {
            model = m
        }

        // Stash usage; emit it in finish() as a trailing usage chunk (OpenAI
        // convention). We do NOT attach usage to a content chunk because
        // OpenAI's streaming spec puts usage on its own final chunk.
        if let usage = inner["usage"] as? [String: Any], !usage.isEmpty {
            stashedUsage = usage
        }

        // Extract deltas + finish_reason. A line may produce several OpenAI
        // chunks (reasoning + content-via-parser + tool_calls); accumulate them.
        var out = Data()
        var producedContentThisLine = false
        if let choices = inner["choices"] as? [Any], !choices.isEmpty {
            guard let choice = choices[0] as? [String: Any] else {
                throw QoderSSEReparserError.malformedSSELine(snippet: innerStr)
            }
            if let delta = choice["delta"] as? [String: Any] {
                // 1. reasoning_content (Phase 2b). Pi strips thinking-tag
                //    artifacts (a literal <thinking> opener sometimes lands
                //    here, closer in `content`) then emits a thinking_delta.
                //    We strip then re-emit as OpenAI delta.reasoning_content.
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                    let cleaned = qoderStripThinkingTags(reasoning)
                    if !cleaned.isEmpty {
                        out.append(buildReasoningChunk(cleaned))
                    }
                }

                // 2. content (Phase 2b). Feed through the thinking-tag parser
                //    so an embedded <thinking>...</thinking> pair in the
                //    content stream splits into reasoning + text. OpenAI SSE
                //    has no explicit "thinking_end" token — the channel simply
                //    switches — so unlike pi (which emits thinking_end when
                //    content arrives mid-block, stream.ts ~376-385) we just let
                //    the next delta's field carry the switch.
                if let content = delta["content"] as? String, !content.isEmpty {
                    let emissions = thinkingParser.processChunk(content)
                    for emission in emissions {
                        switch emission {
                        case .text(let text):
                            out.append(buildContentChunk(text))
                            producedContentThisLine = true
                        case .thinking(let thinking):
                            out.append(buildReasoningChunk(thinking))
                        }
                    }
                }

                // 3. tool_calls (Phase 2b). Index-keyed state machine ported
                //    from stream.ts ~407-435. Upstream opens a tool-call with a
                //    header-only delta (`{index, id, type}`, no `function`), then
                //    follows with `function.name` + `function.arguments`
                //    fragments. Pi only acts when `function.arguments` arrives;
                //    we additionally flush on a non-empty `name` so the canonical
                //    OpenAI opening frame `{name, arguments:""}` still streams.
                //
                //    OpenAI's streaming schema requires every emitted
                //    `tool_calls[].function` to be an object, so a header-only
                //    delta MUST be buffered, never re-emitted as-is (a stray
                //    `{"type":"function","index":0}` makes strict clients reject
                //    the whole turn — observed against the ZCode agent's zod
                //    validator). The buffered id/type ride the first function-
                //    bearing chunk for this index.
                if let toolCalls = delta["tool_calls"] as? [Any], !toolCalls.isEmpty {
                    for raw in toolCalls {
                        guard let tc = raw as? [String: Any] else { continue }
                        let index = (tc["index"] as? Int) ?? 0
                        var state = toolCallsState[index] ?? QoderToolCallState()
                        // Accumulate id/type/name from this delta into state
                        // before deciding whether to emit, so a header-only
                        // delta is captured even if it produces no chunk.
                        state.recordDelta(tc)
                        if let chunk = buildToolCallChunk(index: index, state: state, delta: tc) {
                            out.append(chunk)
                            state.emittedHeader = true
                        }
                        toolCallsState[index] = state
                    }
                }
            }
            if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                // Phase 2b finish_reason override: when any tool_calls were
                // streamed this response, OpenAI clients require
                // `finish_reason: "tool_calls"` (the OpenAI name; pi-ai calls
                // it "toolUse", stream.ts ~496-498). If the upstream sent a
                // generic "stop", force the correct value so the agent knows
                // to execute the tool calls. A meaningful upstream finish_reason
                // ("length", "content_filter") wins.
                let effective = (!toolCallsState.isEmpty && finishReason == "stop")
                    ? "tool_calls"
                    : finishReason
                stashedFinishReason = effective
                // Emit the finish chunk immediately when there's no pending
                // content delta this line (the common case: a separate chunk
                // carries finish_reason). When content and finish land
                // together, content was already emitted above; emit finish
                // separately next.
                if !producedContentThisLine {
                    out.append(buildChunk(delta: nil, finishReason: effective, usage: nil))
                    stashedFinishReason = nil
                }
            }
        }
        return out
    }

    // MARK: - OpenAI chunk builder

    /// Build one OpenAI-shape SSE chunk (`data: {...}\n\n`). `delta` is the
    /// text delta (nil → omit `delta` entirely, used for usage/finish chunks).
    /// `finishReason` non-nil → set `choices[0].finish_reason` and clear
    /// `delta`. `usage` non-nil → attach at top level.
    private func buildChunk(
        delta: String?,
        finishReason: String?,
        usage: [String: Any]?
    ) -> Data {
        var choice: [String: Any] = ["index": 0]
        if let delta {
            choice["delta"] = ["content": delta]
        }
        if let finishReason {
            choice["finish_reason"] = finishReason
        }
        return emitChunk(choice: choice, usage: usage)
    }

    /// Build a text-only content delta chunk (`delta.content`).
    private func buildContentChunk(_ text: String) -> Data {
        let choice: [String: Any] = [
            "index": 0,
            "delta": ["content": text],
        ]
        return emitChunk(choice: choice, usage: nil)
    }

    /// Build a reasoning delta chunk (`delta.reasoning_content`). Phase 2b —
    /// OpenAI's reasoning models carry chain-of-thought under this field;
    /// CLI agents that surface reasoning (e.g. for transparency) read it.
    private func buildReasoningChunk(_ reasoning: String) -> Data {
        let choice: [String: Any] = [
            "index": 0,
            "delta": ["reasoning_content": reasoning],
        ]
        return emitChunk(choice: choice, usage: nil)
    }

    /// Build a tool-call delta chunk (`delta.tool_calls`) for one upstream
    /// delta. Returns nil (→ no chunk emitted) when the delta carries no usable
    /// `function` payload.
    ///
    /// Emission rules (mirrors pi's stream.ts ~407-435, broadened to also flush
    /// on a non-empty `name`):
    /// - A header-only delta (`{index, id, type}`, no `function`) is buffered
    ///   into `state` and produces NO chunk. OpenAI's streaming schema requires
    ///   `tool_calls[].function` to be an object on every emitted entry, so
    ///   re-emitting `{"type":"function","index":0}` makes strict clients reject
    ///   the whole turn (observed: ZCode agent zod validator,
    ///   `function: expected object, received undefined`).
    /// - The first function-bearing delta for an index (a non-empty `name`
    ///   and/or a non-empty `arguments`) emits the opening frame: it carries
    ///   the buffered `id`/`type` from any header-only preamble, plus `name`
    ///   and/or the first `arguments` fragment.
    /// - Subsequent argument-fragment deltas emit a sparse chunk carrying only
    ///   `{index, function:{arguments}}` — `id`/`type`/`name` ride the opening
    ///   frame only (OpenAI streaming convention; clients concatenate
    ///   `function.arguments` across chunks).
    private func buildToolCallChunk(
        index: Int,
        state: QoderToolCallState,
        delta tcDelta: [String: Any]
    ) -> Data? {
        // Pull any function payload this delta carries.
        let fnDelta = tcDelta["function"] as? [String: Any] ?? [:]
        let nameDelta = (fnDelta["name"] as? String) ?? ""
        // `arguments` may be "" (legitimate first-frame sentinel) or a fragment;
        // only treat a present key as a payload signal (an absent key with a
        // present-but-empty name is a header-only delta in disguise).
        let hasArgumentsFragment = fnDelta["arguments"] is String
        let hasName = !nameDelta.isEmpty

        // No usable function payload yet → buffer only, emit nothing.
        guard state.emittedHeader || hasName || hasArgumentsFragment else { return nil }

        var fnOut: [String: Any] = [:]
        if hasName { fnOut["name"] = nameDelta }
        if let args = fnDelta["arguments"] as? String { fnOut["arguments"] = args }
        guard !fnOut.isEmpty else { return nil }

        var entry: [String: Any] = ["index": index, "function": fnOut]
        // id/type ride the OPENING frame only. Once `emittedHeader` is set
        // (after this call returns), later argument-fragment deltas skip this
        // and emit sparse `{index, function:{arguments}}` chunks.
        if !state.emittedHeader {
            if !state.id.isEmpty { entry["id"] = state.id }
            if !state.type.isEmpty { entry["type"] = state.type }
        }

        let choice: [String: Any] = [
            "index": 0,
            "delta": ["tool_calls": [entry]],
        ]
        return emitChunk(choice: choice, usage: nil)
    }

    /// Serialize one chunk's choice (+ optional usage) into a `data: {...}\n\n`
    /// SSE frame. Shared by all chunk builders. JSONSerialization is
    /// deterministic per-call but key order is not guaranteed; OpenAI clients
    /// parse JSON, so order is irrelevant.
    private func emitChunk(choice: [String: Any], usage: [String: Any]?) -> Data {
        var chunk: [String: Any] = [
            "id": responseID ?? "chatcmpl-qoder",
            "object": "chat.completion.chunk",
            "created": created,
            "model": model ?? "",
            "choices": [choice],
        ]
        if let usage {
            chunk["usage"] = usage
        }
        guard let data = try? JSONSerialization.data(withJSONObject: chunk) else {
            return Data()
        }
        return Data("data: ".utf8) + data + Data("\n\n".utf8)
    }

    // MARK: - Snippet redaction

    /// Body can be a string or an object; coerce to a short, redacted snippet
    /// for error messages. Reuses `QoderPATService.redactTokens` so the
    /// `pt-`/`jt-` scrubbing rule is defined in exactly one place.
    private static func redactedSnippet(_ body: Any?) -> String {
        let text: String
        if let s = body as? String {
            text = s
        } else if let data = try? JSONSerialization.data(withJSONObject: body),
                  let s = String(data: data, encoding: .utf8) {
            text = s
        } else if body == nil {
            return ""
        } else {
            text = "\(body)"
        }
        return String(QoderPATService.redactTokens(in: text).prefix(200))
    }
}

// MARK: - QoderToolCallState

/// Mutable accumulator for one tool-call index across a stream (Phase 2b).
/// Port of pi's `ToolCallState` (stream.ts ~29-36). The reparser records the
/// id/name on first sighting and concatenates argument fragments; the OpenAI
/// re-emit is done from the live delta (not this state), so the state's main
/// job is tracking which indices have been seen — kept lightweight to mirror
/// pi and to leave room for a future buffered-emit path if an OpenAI client
/// ever needs a fully-assembled `toolcall_end` shape.
nonisolated struct QoderToolCallState: Sendable {
    var id: String = ""
    var type: String = ""
    var name: String = ""
    /// Concatenated argument fragments (a JSON string built up across deltas).
    /// Unused by the current streaming re-emit but retained for parity with
    /// pi and for the diagnostic/state-completeness it provides.
    var arguments: String = ""
    /// True once this index has emitted its opening frame. Set after
    /// `buildToolCallChunk` emits; later deltas (argument fragments) stream
    /// through regardless of the `function.name`/header check.
    var emittedHeader: Bool = false

    /// Record fields from one upstream `delta.tool_calls[]` entry. Called before
    /// the chunk is built so a header-only delta's id/type are captured even
    /// when it produces no chunk.
    mutating func recordDelta(_ tc: [String: Any]) {
        if let id = tc["id"] as? String, !id.isEmpty { self.id = id }
        if let type = tc["type"] as? String, !type.isEmpty { self.type = type }
        if let fn = tc["function"] as? [String: Any] {
            if let name = fn["name"] as? String, !name.isEmpty { self.name = name }
            if let args = fn["arguments"] as? String { self.arguments += args }
        }
    }
}
