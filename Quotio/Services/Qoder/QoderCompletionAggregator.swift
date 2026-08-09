//
//  QoderCompletionAggregator.swift
//  Quotio
//
//  Non-streaming aggregation for the Qoder OpenAI path (issue #9, ADR 0014).
//
//  The OpenAI Chat Completions schema defaults `stream` to `false`
//  (https://github.com/openai/openai-openai/blob/c309ca1/openapi.yaml#L32968-L32977).
//  Qoder's gateway only speaks SSE, so for a `stream != true` request Quotio
//  keeps consuming the SSE upstream but folds the streamed deltas into a single
//  `chat.completion` JSON object — the shape a non-streaming OpenAI client
//  expects. This type does that folding.
//
//  It consumes the OpenAI-shape SSE chunks that `QoderSSEReparser` *already*
//  emits (the streaming path's output), so there is exactly one parser of the
//  Qoder envelope (the reparser). ProxyBridge feeds those chunks here instead
//  of to the agent socket when the client asked for a non-streaming response.
//
//  Pure value type — no I/O, no actor state — mirroring `QoderSSEReparser`'s
//  design: `nonisolated struct` so it opts out of the project's MainActor
//  default, `mutating func ingest` for testability and single-domain ownership.
//

import Foundation

/// Folds a sequence of OpenAI-shape SSE chunks (as emitted by
/// `QoderSSEReparser`) into one non-streaming `chat.completion` JSON object.
///
/// Bytes fed via `ingest(_:)` are `data: {...}\n\n` frames — exactly what the
/// reparser produces and what the streaming path writes to the socket. Frames
/// may split across `ingest` calls (TCP segmentation); a partial trailing
/// frame is buffered until its `\n\n` boundary arrives.
///
/// After the upstream stream ends, `completionJSON(requestModel:)` produces the
/// single object to serialize and return with `Content-Type: application/json`.
/// `capturedUsage` mirrors `QoderSSEReparser.capturedUsage` so ProxyBridge's
/// `RequestMetadata` token accounting is identical across streaming and
/// non-streaming responses.
nonisolated struct QoderCompletionAggregator {

    /// Bytes received but not yet terminated by a frame boundary (`\n\n`).
    /// SSE frames can split across TCP segments, same constraint as the
    /// reparser's line buffer.
    private var buffer: String = ""

    /// Concatenated `delta.content` across the stream. Becomes
    /// `choices[0].message.content`.
    private var content: String = ""

    /// Concatenated `delta.reasoning_content` across the stream. Held so mixed
    /// streams (reasoning + content deltas) parse cleanly, but intentionally
    /// NOT surfaced on the non-streaming `message` object — the OpenAI
    /// non-streaming `message` schema has no field for it. See ADR 0014.
    private var reasoning: String = ""

    /// Per-index tool-call accumulator. Becomes `choices[0].message.tool_calls`,
    /// sorted ascending by index for a stable surface regardless of arrival
    /// order.
    private var toolCalls: [Int: ToolCallAccumulator] = [:]

    /// `finish_reason` from the final choice delta, if one arrived. Defaults to
    /// `"stop"` at emission when nil — OpenAI's default for a normally-ended
    /// completion, and a safe fallback if the upstream truncated before a
    /// finish frame.
    private var finishReason: String?

    /// Captured top-level `usage` block. Surfaced on the completion and via
    /// `capturedUsage` for ProxyBridge's accounting.
    private(set) var capturedUsage: [String: Any]?

    /// Stable response id / created, stamped from the first chunk carrying
    /// them (OpenAI clients expect a stable `id` for a completion).
    private var responseID: String?
    private var createdStamp: Int?

    init() {}

    // MARK: - Ingest

    /// Append OpenAI-shape SSE bytes, peeling complete `data: {...}\n\n` frames
    /// and folding each into the aggregate. Frames may straddle `ingest` calls.
    ///
    /// Throws on malformed JSON inside a `data:` frame — same tolerance policy
    /// as the reparser's `drainLines` (skip malformed), but surfaced here so a
    /// strict caller can choose. Today ProxyBridge treats the aggregator as
    /// best-effort and lets the streaming reparser's gate own hard failures.
    mutating func ingest(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer.append(text)

        // Peel complete frames on `\n\n`. CRLF is normalized first so a frame
        // terminated by `\r\n\r\n` still splits (SSE allows it). Same rationale
        // as the reparser's normalization in `feed`.
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")

        while let range = buffer.range(of: "\n\n") {
            let frame = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            processFrame(frame)
        }
    }

    /// Process one `\n\n`-delimited SSE frame. A frame may carry several SSE
    /// lines (e.g. `event:` + `data:`); only `data:` lines carry JSON here.
    private mutating func processFrame(_ frame: String) {
        for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(":") { continue }   // boundary / comment
            guard line.hasPrefix("data:") else { continue }        // ignore event:/id:/retry:
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]" else { continue }
            guard let lineData = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                // Skip malformed lines — same tolerance as the reparser's
                // `drainLines` swallowing `.malformedSSELine`.
                continue
            }
            ingestChunk(chunk)
        }
    }

    /// Fold one parsed OpenAI streaming chunk into the aggregate.
    private mutating func ingestChunk(_ chunk: [String: Any]) {
        if responseID == nil, let id = chunk["id"] as? String, !id.isEmpty {
            responseID = id
        }
        if createdStamp == nil, let created = chunk["created"] as? Int {
            createdStamp = created
        }
        if let usage = chunk["usage"] as? [String: Any], !usage.isEmpty {
            capturedUsage = usage
        }

        guard let choices = chunk["choices"] as? [Any], !choices.isEmpty else { return }
        guard let choice = choices[0] as? [String: Any] else { return }

        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String, !text.isEmpty {
                content += text
            }
            if let think = delta["reasoning_content"] as? String, !think.isEmpty {
                reasoning += think
            }
            if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty {
                for raw in calls {
                    guard let tc = raw as? [String: Any] else { continue }
                    ingestToolCall(tc)
                }
            }
        }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }
    }

    private mutating func ingestToolCall(_ tc: [String: Any]) {
        let index = (tc["index"] as? Int) ?? 0
        var acc = toolCalls[index] ?? ToolCallAccumulator()
        if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
        if let type = tc["type"] as? String, !type.isEmpty { acc.type = type }
        if let fn = tc["function"] as? [String: Any] {
            if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
            if let args = fn["arguments"] as? String { acc.arguments += args }
        }
        toolCalls[index] = acc
    }

    // MARK: - Emit

    /// Build the non-streaming `chat.completion` object. `requestModel` is the
    /// model the agent requested (with the `qoder/` prefix, as the agent sees
    /// it) — OpenAI echoes the request model on the response.
    func completionJSON(requestModel: String) -> [String: Any] {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content,
        ]
        // Tool calls are present only when the stream carried at least one. An
        // empty array would be a worse contract than an absent field.
        if !toolCalls.isEmpty {
            let sortedIndices = toolCalls.keys.sorted()
            message["tool_calls"] = sortedIndices.map { idx in
                let acc = toolCalls[idx]!
                var entry: [String: Any] = ["index": idx]
                if !acc.id.isEmpty { entry["id"] = acc.id }
                if !acc.type.isEmpty { entry["type"] = acc.type }
                var fn: [String: Any] = [:]
                if !acc.name.isEmpty { fn["name"] = acc.name }
                // Always carry `arguments` (even "" if the stream sent none) —
                // OpenAI's non-streaming schema requires it under `function`.
                fn["arguments"] = acc.arguments
                entry["function"] = fn
                return entry
            }
        }

        let choice: [String: Any] = [
            "index": 0,
            "message": message,
            "finish_reason": finishReason ?? "stop",
        ]
        var json: [String: Any] = [
            "id": responseID ?? "chatcmpl-qoder",
            "object": "chat.completion",
            "created": createdStamp ?? Int(Date().timeIntervalSince1970.rounded(.down)),
            "model": requestModel,
            "choices": [choice],
        ]
        if let capturedUsage {
            json["usage"] = capturedUsage
        }
        return json
    }

    // MARK: - Tool-call accumulator

    /// One tool-call index's accumulated state. Mirrors `QoderToolCallState`
    /// but keyed/indexed for the non-streaming surface (id/type/name ride the
    /// assembled `message.tool_calls[]` entry once).
    private struct ToolCallAccumulator {
        var id: String = ""
        var type: String = ""
        var name: String = ""
        /// Concatenated argument fragments — a JSON string built across deltas.
        var arguments: String = ""
    }
}
