//
//  QoderResponsesWiringTests.swift
//  QuotioTests
//
//  Integration-level tests for the Responses API wiring (issue #11 Task B).
//
//  Task B routes `/v1/responses` requests through Task A's translators:
//    - dispatch synthesizes a Chat Completions body via
//      `QoderResponsesTranslator.synthesizeChatBody` (so COSY/failover/reparser
//      stay byte-identical to the Chat path);
//    - the streaming branch feeds the reparser's OpenAI-chunk output through
//      `QoderResponsesAdapter` to emit Responses events;
//    - the non-streaming branch returns a 501 placeholder (follow-up issue).
//
//  `processRequest` / `forwardQoderRequest` are MainActor-isolated methods on
//  the ProxyBridge `@Observable` tied to live `NWConnection`s, so the dispatch
//  decision itself is covered by manual/integration verification. These tests
//  pin the CONTRACTS the wiring depends on — the dispatch synthesis (cases 1-2)
//  and the adapter-as-reparser-consumer contract (case 3) — without spinning up
//  a brittle ProxyBridge harness.
//

import XCTest
@testable import Quotio

final class QoderResponsesWiringTests: XCTestCase {

    // MARK: - Helpers

    /// Build a JSON `Data` body from a dictionary.
    private func body(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    /// Build one OpenAI Chat Completions streaming chunk wrapped in an SSE
    /// `data:` frame — the exact bytes `QoderSSEReparser` emits and the
    /// streaming branch feeds to `QoderResponsesAdapter` in responsesMode.
    private func chatChunk(_ inner: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: inner)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// A content-delta Chat chunk (mirrors QoderSSEReparser.emitChunk's shape).
    private func contentDelta(_ text: String) -> [String: Any] {
        [
            "id": "resp_1",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "qoder/x",
            "choices": [["index": 0, "delta": ["content": text]]],
        ]
    }

    /// Parse a Responses SSE byte stream back into (type, payload) tuples.
    /// Same frame-peel as QoderResponsesAdapterTests: each Responses event is a
    /// two-line frame (`event: <type>\n` + `data: {<payload>}\n\n`).
    private func responsesEvents(_ data: Data) -> [(type: String, payload: [String: Any])] {
        var events: [(String, [String: Any])] = []
        let text = String(data: data, encoding: .utf8) ?? ""
        for frame in text.components(separatedBy: "\n\n") {
            var type: String?
            var payload: [String: Any]?
            for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("event: ") {
                    type = String(line.dropFirst("event: ".count))
                } else if line.hasPrefix("data: ") {
                    let s = String(line.dropFirst("data: ".count))
                    if let d = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        payload = obj
                    }
                }
            }
            if let type, let payload {
                events.append((type, payload))
            }
        }
        return events
    }

    // MARK: - Dispatch contract: synthesize → Chat parse

    /// A `/v1/responses` body synthesized via the dispatch path's translator
    /// must round-trip through `QoderChatTranslator.parse` as a valid Chat
    /// Completions body. This is the byte shape ProxyBridge hands to
    /// `QoderFailoverRouter.openStream` in responsesMode — pinning it catches
    /// drift between the dispatch synthesis and the router's input contract.
    func testResponsesBodySynthesizesToChatBody() throws {
        let responsesBody = body([
            "model": "qoder/x",
            "input": [["type": "message", "role": "user", "content": "hi"]],
        ])
        // Dispatch synthesis (ProxyBridge.processRequest, responsesMode branch).
        let chatBody = try QoderResponsesTranslator.synthesizeChatBody(from: responsesBody)
        // The router's translator parses the synthesized body — if this throws,
        // the wiring feeds the router a shape it rejects.
        let parsed = try QoderChatTranslator.parse(body: chatBody)
        XCTAssertEqual(parsed.model, "qoder/x")
        XCTAssertEqual(parsed.messages.count, 1)
        XCTAssertEqual(parsed.messages[0].role, "user")
    }

    /// `instructions` (the Responses instruction channel) prepends a
    /// role:developer message at synthesis, and
    /// `transformMessagesForQoder` folds developer→system downstream (issue
    /// #17). This proves the Responses path benefits from the #17 fix end-to-
    /// end: a Responses client setting `instructions` lands a system message
    /// on the upstream gateway, not a dropped/unknown role.
    func testResponsesInstructionsPrependDeveloperThenNormalizeToSystem() throws {
        let responsesBody = body([
            "model": "qoder/x",
            "instructions": "be concise",
            "input": [["type": "message", "role": "user", "content": "hi"]],
        ])
        let chatBody = try QoderResponsesTranslator.synthesizeChatBody(from: responsesBody)
        let parsed = try QoderChatTranslator.parse(body: chatBody)
        // Synthesis emits developer (the Responses spelling); the synthesized
        // body carries it verbatim.
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].role, "developer")
        XCTAssertEqual(parsed.messages[1].role, "user")
        // transformMessagesForQoder (runs inside `translate` downstream) folds
        // developer→system — verify that fold here so the wiring contract is
        // pinned end-to-end.
        let transformed = QoderChatTranslator.transformMessagesForQoder(parsed.messages)
        XCTAssertEqual(transformed.first?.role, "system")
    }

    // MARK: - Adapter consumes reparser output (wiring contract)

    /// The streaming branch feeds the reparser's OpenAI-chunk output through
    /// `QoderResponsesAdapter`. Pin the contract: a content chunk (reparser-
    /// shaped) fires the lazy opener + one output_text.delta, and `finish()`
    /// emits the terminal trio + `response.completed`. Overlaps Task A's adapter
    /// tests but documents the wiring seam — the adapter must accept reparser
    /// output, not Qoder-envelope bytes.
    func testResponsesAdapterConsumesReparsrOutput() throws {
        var adapter = QoderResponsesAdapter()
        var out = try adapter.ingest(chatChunk(contentDelta("Hel")))
        out.append(try adapter.ingest(chatChunk(contentDelta("lo"))))
        out.append(try adapter.finish())
        let events = responsesEvents(out)

        // Opener fires exactly once (lazy, on first content delta).
        let createdCount = events.filter { $0.type == "response.created" }.count
        XCTAssertEqual(createdCount, 1)
        // Two content deltas → two output_text.delta events.
        let deltas = events.filter { $0.type == "response.output_text.delta" }
        XCTAssertEqual(deltas.count, 2)
        // finish() emits the terminal sequence, ending in response.completed.
        let types = events.map(\.type)
        XCTAssertEqual(types.last, "response.completed")

        // The completed Response object carries the assembled text — the
        // wiring must not drop content between reparser and adapter.
        let completed = events.first { $0.type == "response.completed" }
        let response = try XCTUnwrap(completed?.payload["response"] as? [String: Any])
        let output = try XCTUnwrap(response["output"] as? [Any])
        let item = try XCTUnwrap(output[0] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [Any])
        let part = try XCTUnwrap(content[0] as? [String: Any])
        XCTAssertEqual(part["text"] as? String, "Hello")
    }
}
