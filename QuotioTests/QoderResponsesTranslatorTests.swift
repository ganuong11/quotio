//
//  QoderResponsesTranslatorTests.swift
//  QuotioTests
//
//  Tests for the input translator on the Responses API path (issue #11 Task A).
//  `QoderResponsesTranslator` parses an OpenAI Responses API request body
//  (`{model, input, instructions, ...}`) into the same `OpenAIChatRequest`
//  shape `QoderChatTranslator.parse(body:)` produces, so Task B can hand the
//  synthesized body to the existing Chat path. These tests pin the translation
//  rules with constructed JSON bodies — no I/O, no actor.
//

import XCTest
@testable import Quotio

final class QoderResponsesTranslatorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a JSON `Data` body from a dictionary.
    private func body(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - parseResponses

    /// `input: "hi"` (string shorthand) → a single user message.
    func testParsesStringInputAsUserMessage() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": "hi",
        ]))
        XCTAssertEqual(req.model, "qoder/x")
        XCTAssertEqual(req.messages.count, 1)
        XCTAssertEqual(req.messages[0].role, "user")
        XCTAssertEqual(req.messages[0].content, .text("hi"))
    }

    /// `input: [{type:"message",...}]` with user + assistant turns preserves
    /// roles and flattens text parts.
    func testParsesMessageItemsWithRoles() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": [
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "hello"]]],
            ],
        ]))
        XCTAssertEqual(req.messages.count, 2)
        XCTAssertEqual(req.messages[0].role, "user")
        XCTAssertEqual(req.messages[0].content, .parts([.text("hi")]))
        XCTAssertEqual(req.messages[1].role, "assistant")
        XCTAssertEqual(req.messages[1].content, .parts([.text("hello")]))
    }

    /// Top-level `instructions` prepends a role:developer message (the
    /// Responses instruction channel). The developer→system normalization is
    /// handled downstream by transformMessagesForQoder.
    func testInstructionsPrependDeveloperMessage() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "instructions": "be nice",
            "input": [["type": "message", "role": "user", "content": "hi"]],
        ]))
        XCTAssertEqual(req.messages.count, 2)
        XCTAssertEqual(req.messages[0].role, "developer")
        XCTAssertEqual(req.messages[0].content, .text("be nice"))
        XCTAssertEqual(req.messages[1].role, "user")
        XCTAssertEqual(req.messages[1].content, .text("hi"))
    }

    /// A `function_call` item (assistant's prior tool call) maps to an assistant
    /// message carrying a single tool call. The Responses `call_id` becomes the
    /// OpenAI tool_call `id` (the value the function_call_output correlates on).
    func testFunctionCallItemMapsToAssistantToolCall() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": [
                [
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_42",
                    "name": "get_weather",
                    "arguments": "{\"loc\":\"SF\"}",
                ],
            ],
        ]))
        XCTAssertEqual(req.messages.count, 1)
        XCTAssertEqual(req.messages[0].role, "assistant")
        let toolCalls = try XCTUnwrap(req.messages[0].toolCalls)
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls[0].id, "call_42")
        XCTAssertEqual(toolCalls[0].function.name, "get_weather")
        XCTAssertEqual(toolCalls[0].function.arguments, "{\"loc\":\"SF\"}")
    }

    /// A `function_call_output` item (a tool's result) maps to a role:tool
    /// message with toolCallID and text content.
    func testFunctionCallOutputMapsToToolMessage() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": [
                [
                    "type": "function_call_output",
                    "call_id": "call_42",
                    "output": "65F",
                ],
            ],
        ]))
        XCTAssertEqual(req.messages.count, 1)
        XCTAssertEqual(req.messages[0].role, "tool")
        XCTAssertEqual(req.messages[0].content, .text("65F"))
        XCTAssertEqual(req.messages[0].toolCallID, "call_42")
    }

    /// Unknown item types are skipped (do not throw), matching the translator's
    /// skip-unknown-role policy.
    func testUnknownItemTypesAreSkipped() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": [
                ["type": "reasoning", "content": "should be skipped"],
                ["type": "message", "role": "user", "content": "kept"],
            ],
        ]))
        XCTAssertEqual(req.messages.count, 1)
        XCTAssertEqual(req.messages[0].role, "user")
        XCTAssertEqual(req.messages[0].content, .text("kept"))
    }

    /// Responses spells max tokens as `max_output_tokens`; this maps to
    /// `maxTokens` on the synthesized Chat request.
    func testMaxOutputTokensMapsToMaxTokens() throws {
        let req = try QoderResponsesTranslator.parseResponses(body: body([
            "model": "qoder/x",
            "input": "hi",
            "max_output_tokens": 4096,
        ]))
        XCTAssertEqual(req.maxTokens, 4096)
    }

    // MARK: - synthesizeChatBody

    /// The synthesized body parses as a Chat Completions request with model +
    /// messages round-tripped. This is the byte shape Task B hands to
    /// QoderFailoverRouter.openStream.
    func testSynthesizeChatBodyProducesValidChatCompletionsJSON() throws {
        let synthesized = try QoderResponsesTranslator.synthesizeChatBody(from: body([
            "model": "qoder/x",
            "instructions": "be nice",
            "input": [["type": "message", "role": "user", "content": "hi"]],
            "max_output_tokens": 1024,
        ]))
        // The synthesized body must round-trip through QoderChatTranslator's
        // parser — proves the synthesized shape is a valid Chat Completions
        // body the failover router's translator will accept.
        let parsed = try QoderChatTranslator.parse(body: synthesized)
        XCTAssertEqual(parsed.model, "qoder/x")
        XCTAssertEqual(parsed.maxTokens, 1024)
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].role, "developer")
        XCTAssertEqual(parsed.messages[0].content, .text("be nice"))
        XCTAssertEqual(parsed.messages[1].role, "user")
        XCTAssertEqual(parsed.messages[1].content, .text("hi"))
    }

    // MARK: - Errors

    /// Missing/empty `model` → malformedRequest.
    func testMissingModelThrows() {
        XCTAssertThrowsError(
            try QoderResponsesTranslator.parseResponses(body: body(["input": "hi"]))
        ) { error in
            guard case .malformedRequest(let detail) = error as? QoderTranslatorError else {
                return XCTFail("expected .malformedRequest, got \(error)")
            }
            XCTAssertTrue(detail.contains("model"))
        }
    }

    /// Missing both `input` and `instructions` → malformedRequest (need at
    /// least one to form a turn).
    func testMissingInputAndInstructionsThrows() {
        XCTAssertThrowsError(
            try QoderResponsesTranslator.parseResponses(body: body(["model": "qoder/x"]))
        ) { error in
            guard case .malformedRequest = error as? QoderTranslatorError else {
                return XCTFail("expected .malformedRequest, got \(error)")
            }
        }
    }

    /// Body that isn't a JSON object → malformedRequest.
    func testNonObjectBodyThrows() {
        let arr = try! JSONSerialization.data(withJSONObject: ["not", "an", "object"])
        XCTAssertThrowsError(try QoderResponsesTranslator.parseResponses(body: arr)) { error in
            guard case .malformedRequest = error as? QoderTranslatorError else {
                return XCTFail("expected .malformedRequest, got \(error)")
            }
        }
    }
}
