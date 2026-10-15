//
//  OpencodeResponsesAggregator.swift
//  Quotio
//
//  Non-streaming aggregation for the opencode responses-native passthrough
//  arm (ADR 0021). The free-tier gate forces `stream:true` upstream, so a
//  client that sent `stream:false` on `/v1/responses` for a responses-native
//  model (e.g. muse-spark) must receive one `response` JSON object — the
//  upstream instead emits Responses SSE events, which we fold here.
//
//  The Qoder aggregator (`QoderCompletionAggregator`) cannot serve this arm:
//  it consumes chat.completion.chunk frames, and this arm's upstream bytes
//  are Responses events. The reverse arm (responses client, chat-native
//  model) reuses `QoderCompletionAggregator.responsesObject` — this type is
//  only the responses-native passthrough's folder.
//
//  Strategy: the Responses protocol's own terminal events carry the complete
//  response object — `response.completed`/`response.failed`/
//  `response.incomplete` each embed `payload.response`, which IS the
//  non-streaming body. Capture it when it arrives; fall back to folding
//  `response.output_text.delta` + function_call `output_item.done` events
//  into the same object shape `QoderCompletionAggregator.responsesObject`
//  produces (msg_/fc_ item ids, `QoderResponsesAdapter.outputTextPart` for
//  the text part schema — one source of truth for the part shape).
//
//  Pure value type — no I/O, no actor state. `nonisolated struct` with
//  `mutating func ingest(_:)`, mirroring `QoderCompletionAggregator`'s
//  declaration style so it opts out of the project's MainActor default.
//

import Foundation

nonisolated struct OpencodeResponsesAggregator {

    /// Bytes received but not yet terminated by a frame boundary (`\n\n`).
    private var buffer: String = ""

    /// The complete response object captured from a terminal event, if one
    /// arrived. Preferred verbatim over the folded fallback.
    private var capturedResponse: [String: Any]?

    // Fallback fold state (used only when no terminal event arrives).
    private var content: String = ""
    private var functionCalls: [[String: Any]] = []
    private var responseID: String?
    private var createdStamp: Int?

    init() {}

    // MARK: - Ingest

    /// Append Responses-SSE bytes, peeling complete `data: {...}\n\n` frames.
    /// Frames may straddle `ingest` calls (TCP segmentation). Malformed JSON
    /// inside a frame is skipped — same tolerance policy as the Qoder
    /// aggregator.
    mutating func ingest(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        buffer.append(text)
        buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
        while let range = buffer.range(of: "\n\n") {
            let frame = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            processFrame(frame)
        }
    }

    private mutating func processFrame(_ frame: String) {
        for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let lineData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handleEvent(event)
        }
    }

    private mutating func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "response.created":
            // Stamp id/created for the fallback fold; the captured terminal
            // (when it arrives) carries its own.
            if let response = event["response"] as? [String: Any] {
                if responseID == nil, let id = response["id"] as? String, !id.isEmpty {
                    responseID = id
                }
                if createdStamp == nil, let created = response["created_at"] as? Int {
                    createdStamp = created
                }
            }
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                content += delta
            }
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call" else { return }
            var call: [String: Any] = ["type": "function_call", "status": "completed"]
            for key in ["id", "call_id", "name", "arguments"] {
                if let value = item[key] { call[key] = value }
            }
            functionCalls.append(call)
        case "response.completed", "response.failed", "response.incomplete":
            if let response = event["response"] as? [String: Any] {
                capturedResponse = response
            }
        default:
            break
        }
    }

    // MARK: - Emit

    /// The non-streaming `response` object. A captured terminal event's
    /// response wins (verbatim except the model echo); otherwise the folded
    /// fallback mirrors `QoderCompletionAggregator.responsesObject`'s shape
    /// conventions so both responses-surface arms emit one schema.
    ///
    /// `requestModel` echoes the model the agent requested (with the
    /// `opencode/` prefix), as OpenAI echoes the request model.
    func responseObject(requestModel: String) -> [String: Any] {
        if var captured = capturedResponse {
            captured["model"] = requestModel
            return captured
        }

        var output: [[String: Any]] = []
        if !content.isEmpty {
            let id = responseID ?? "resp_opencode"
            output.append([
                "id": "msg_\(id)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [QoderResponsesAdapter.outputTextPart(text: content)],
            ])
        }
        let base = content.isEmpty ? 0 : 1
        for (position, call) in functionCalls.enumerated() {
            var item = call
            item["id"] = "fc_\(base + position)"
            output.append(item)
        }

        var response: [String: Any] = [
            "id": responseID ?? "resp_opencode",
            "object": "response",
            "created_at": createdStamp ?? Int(Date().timeIntervalSince1970.rounded(.down)),
            "status": "completed",
            "model": requestModel,
            "output": output,
            "completed_at": Int(Date().timeIntervalSince1970.rounded(.down)),
        ]
        // The Responses contract puts usage on the terminal event; without
        // one we have none to report — NSNull, matching the Qoder arm.
        response["usage"] = NSNull()
        return response
    }
}
