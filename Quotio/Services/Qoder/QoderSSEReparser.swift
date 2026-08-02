//
//  QoderSSEReparser.swift
//  Quotio
//
//  Phase 2a (ADR 0001, ADR 0004, ADR 0005): parses Qoder's SSE response frames
//  and emits OpenAI-shape SSE deltas for the CLI agent. Pure value type — no
//  I/O, no actor state. Owned as a `var` inside the ProxyBridge actor (ticket
//  #7), which feeds raw upstream bytes in and writes the returned OpenAI-shape
//  bytes to the agent socket.
//
//  Reference: pi-provider-qoder/src/stream.ts lines ~290-470 (SSE parse loop).
//  Ported for algorithmic parity; the OpenAI re-encode is a Quotio addition
//  (pi emits pi-ai SDK events, not OpenAI SSE).
//
//  Text path only:
//   - `delta.content` → OpenAI `delta.content` (passed through unchanged).
//   - `inner.usage` (final chunk) → OpenAI `usage`, passed through verbatim.
//     Per ADR 0005 §2, Qoder follows OpenAI semantics (`prompt_tokens`
//     INCLUDES `cached_tokens`); do NOT replicate pi's cache subtraction.
//   - `delta.reasoning_content` → throws `.reasoningContentNotSupported`.
//     The reparser cannot re-send an HTTP status mid-stream (the SSE response
//     already returned 200), so it throws a typed error and ProxyBridge (#7)
//     owns the wire representation — closing the agent socket with a trailing
//     error chunk is the documented behavior, NOT a true HTTP 400. (Phase 2b
//     ticket #8 lifts this gate and emits `delta.reasoning_content` instead.)
//   - `delta.tool_calls` → throws `.toolCallsNotSupported` for the same reason.
//     Tools were already rejected at the request boundary, so this is
//     defensive against upstream behavior drift.
//

import Foundation

/// Errors thrown while reparsing Qoder's SSE stream into OpenAI-shape SSE.
/// None of these carry token/secret content. ProxyBridge (ticket #7) maps each
/// to its wire representation — a mid-stream abort for the text-path gates.
nonisolated enum QoderSSEReparserError: Error, LocalizedError {
    /// Qoder envelope's `statusCodeValue` was non-200. Pi throws in the same
    /// spot; ProxyBridge terminates the agent stream. Snippet is ≤200 chars,
    /// redacted of any `pt-`/`jt-` runs (QoderPATService convention).
    case upstreamStatus(status: Int, snippet: String)
    /// A `data:` line carried malformed JSON. Pi skips these (a single bad
    /// SSE line shouldn't kill the stream); we surface them so ProxyBridge can
    /// decide — most callers will log-and-continue via the throwing `feed`.
    case malformedSSELine(snippet: String)
    /// `delta.reasoning_content` appeared in a chunk. Phase 2a text path does
    /// not re-emit reasoning; Phase 2b (ticket #8) handles it.
    case reasoningContentNotSupported
    /// `delta.tool_calls` appeared. Tools were rejected at the request
    /// boundary; this is defensive against upstream drift.
    case toolCallsNotSupported

    var errorDescription: String? {
        switch self {
        case .upstreamStatus(let status, let snippet):
            let capped = String(snippet.prefix(200))
            return capped.isEmpty
                ? "Qoder upstream returned status \(status)."
                : "Qoder upstream returned status \(status): \(capped)"
        case .malformedSSELine(let snippet):
            return "Qoder SSE: malformed line (\(String(snippet.prefix(120))))."
        case .reasoningContentNotSupported:
            return "Qoder SSE: reasoning_content is not supported on the text path (Phase 2b)."
        case .toolCallsNotSupported:
            return "Qoder SSE: tool_calls are not supported on the text path (Phase 2b)."
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
    private var stashedUsage: [String: Any]?

    /// Stashed `finish_reason`. Emitted on the final chunk before `[DONE]`.
    private var stashedFinishReason: String?

    /// Whether `finish()` has emitted its terminal `[DONE]`. Guards against
    /// double-emit on repeated `finish()` calls.
    private var finished: Bool = false

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
    /// Throws on `statusCodeValue != 200`, malformed JSON lines, and the
    /// reasoning/tool_calls text-path gates. A thrown error does NOT corrupt
    /// the reparser state — the caller may continue feeding if it chooses to
    /// swallow `.malformedSSELine` (pi's behavior) — but a thrown gate
    /// (`.reasoningContentNotSupported` / `.toolCallsNotSupported`) signals
    /// the caller should terminate the agent stream.
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
                    if let lineData = try? processLine(leftover) {
                        out.append(lineData)
                    }
                    // processLine may throw on a gate; if it did, the throw
                    // propagates and the buffer is already drained. Acceptable:
                    // a thrown gate means we're terminating anyway.
                }
                return out
            }
            let line = String(buffer[buffer.startIndex..<nlIndex])
            buffer.removeSubrange(buffer.startIndex...nlIndex)
            do {
                if let lineData = try processLine(line) {
                    out.append(lineData)
                }
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
    /// SSE bytes to emit, or nil if the line produced no output (comments,
    /// events, keep-alives, `[DONE]`, etc.).
    ///
    /// Throws on `statusCodeValue != 200` and on the reasoning/tool_calls
    /// gates. Throws `.malformedSSELine` for JSON parse failures — the caller
    /// (`drainLines`) swallows those by default (pi parity).
    private mutating func processLine(_ rawLine: String) throws -> Data? {
        // Surrounding whitespace trim (SSE spec: ignore leading/trailing
        // spaces around the field). CRLF was already collapsed in `feed`.
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return nil }   // SSE event boundary
        if line.hasPrefix(":") { return nil }   // SSE comment / keep-alive
        if !line.hasPrefix("data:") { return nil }   // ignore `event:`, `id:`, `retry:`
        let dataStr = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if dataStr.isEmpty { return nil }
        if dataStr == "[DONE]" { return nil }   // upstream [DONE] handled by finish()

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
            return nil
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

        // Extract content delta + finish_reason. Empty deltas (e.g. role-only
        // opener chunks, usage-only final chunks) emit nothing here.
        var emitted: Data?
        if let choices = inner["choices"] as? [Any], !choices.isEmpty {
            guard let choice = choices[0] as? [String: Any] else {
                throw QoderSSEReparserError.malformedSSELine(snippet: innerStr)
            }
            if let delta = choice["delta"] as? [String: Any] {
                // Text-path gate: reasoning_content.
                if delta["reasoning_content"] != nil {
                    throw QoderSSEReparserError.reasoningContentNotSupported
                }
                // Defensive text-path gate: tool_calls. Tools were already
                // rejected at the request boundary (translator gate 1), so a
                // well-behaved upstream never emits this. If it appears, it
                // signals upstream drift or a misrouted request — fail loudly
                // rather than silently drop tool-call deltas the agent can't
                // act on. Ticket #8 lifts this when tool support lands.
                if delta["tool_calls"] != nil {
                    throw QoderSSEReparserError.toolCallsNotSupported
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    emitted = buildChunk(delta: content, finishReason: nil, usage: nil)
                }
            }
            if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                stashedFinishReason = finishReason
                // Emit the finish chunk immediately when there's no pending
                // content delta (the common case: a separate chunk carries
                // finish_reason). When content and finish land together, we
                // already emitted content above; emit finish separately next.
                if emitted == nil {
                    emitted = buildChunk(delta: nil, finishReason: finishReason, usage: nil)
                    stashedFinishReason = nil
                }
            }
        }
        return emitted
    }

    // MARK: - OpenAI chunk builder

    /// Build one OpenAI-shape SSE chunk (`data: {...}\n\n`). `delta` is the
    /// text delta (nil → omit `delta` entirely, used for usage/finish chunks).
    /// `finishReason` non-nil → set `choices[0].finish_reason` and clear
    /// `delta`. `usage` non-nil → attach at top level.
    private mutating func buildChunk(
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

        // JSONSerialization is deterministic per-call but key order is not
        // guaranteed; OpenAI clients parse JSON, so order is irrelevant.
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
