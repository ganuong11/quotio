//
//  OpencodeProtocolMapperTests.swift
//  QuotioTests
//
//  Fixture-pair tests for the ADR 0021 chat→responses request translation
//  (`OpencodeProtocolMapper.responsesRequestToChat`). Message/item structure
//  is the reused Qoder translator's (pinned by QoderResponsesTranslatorTests);
//  these tests pin the OVERLAY: request-level fields the Qoder DTO does not
//  carry, plus the hard-fail carve-out for server-side conversation state.
//

import Foundation
import XCTest
@testable import Quotio

final class OpencodeProtocolMapperTests: XCTestCase {

    private func translate(_ dict: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: dict)
        let out = try OpencodeProtocolMapper.responsesRequestToChat(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    // MARK: - Structure (reuse seams)

    func testStringInputBecomesUserMessage() throws {
        let chat = try translate([
            "model": "opencode/mimo-v2.6-flash-free",
            "input": "hi",
        ])
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hi")
        // The client's model (prefix included) passes through verbatim —
        // prefix stripping belongs to the router's shaping step.
        XCTAssertEqual(chat["model"] as? String, "opencode/mimo-v2.6-flash-free")
    }

    func testInstructionsPrependDeveloperMessage() throws {
        let chat = try translate([
            "model": "m",
            "instructions": "be terse",
            "input": [["type": "message", "role": "user", "content": "hi"]],
        ])
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "developer")
        XCTAssertEqual(messages.first?["content"] as? String, "be terse")
        XCTAssertEqual(messages.count, 2)
    }

    func testInterleavedSystemMessageStaysInPlace() throws {
        // Interleaved system/developer content maps to in-place messages,
        // not instructions-flattening — ordering is preserved (plan §2a).
        let chat = try translate([
            "model": "m",
            "input": [
                ["type": "message", "role": "user", "content": "first"],
                ["type": "message", "role": "system", "content": "mid-course correction"],
                ["type": "message", "role": "user", "content": "second"],
            ],
        ])
        let roles = try XCTUnwrap(chat["messages"] as? [[String: Any]]).compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["user", "system", "user"])
    }

    func testFunctionCallHistoryMapsToToolMessages() throws {
        let chat = try translate([
            "model": "m",
            "input": [
                ["type": "function_call", "call_id": "call_1", "name": "read", "arguments": #"{"filePath":"/x"}"#],
                ["type": "function_call_output", "call_id": "call_1", "output": "file bytes"],
                ["type": "message", "role": "user", "content": "thanks"],
            ],
        ])
        let messages = try XCTUnwrap(chat["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "assistant")
        XCTAssertNotNil(messages[0]["tool_calls"])
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "call_1")
    }

    func testFlatToolsBecomeNestedChatShape() throws {
        let chat = try translate([
            "model": "m",
            "input": "hi",
            "tools": [[
                "type": "function",
                "name": "lookup",
                "description": "look things up",
                "parameters": ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"]],
            ]],
        ])
        let tools = try XCTUnwrap(chat["tools"] as? [[String: Any]])
        let fn = try XCTUnwrap((tools[0]["function"] as? [String: Any]))
        XCTAssertEqual(fn["name"] as? String, "lookup")
        XCTAssertNotNil((fn["parameters"] as? [String: Any])?["properties"])
    }

    // MARK: - Token fields

    func testMaxOutputTokensCarriesBothSpellings() throws {
        // Both spellings ride the translated body — an openai-compatible
        // upstream may honor only the legacy `max_tokens`, and dropping it
        // would silently lose the cap.
        let chat = try translate(["model": "m", "input": "hi", "max_output_tokens": 512])
        XCTAssertEqual(chat["max_completion_tokens"] as? Int, 512)
        XCTAssertEqual(chat["max_tokens"] as? Int, 512)
    }

    // MARK: - Overlays (fields the Qoder DTO does not carry)

    func testSamplingParametersPassThrough() throws {
        let chat = try translate([
            "model": "m", "input": "hi", "temperature": 0.2, "top_p": 0.9,
            "parallel_tool_calls": false,
        ])
        XCTAssertEqual(chat["temperature"] as? Double, 0.2)
        XCTAssertEqual(chat["top_p"] as? Double, 0.9)
        XCTAssertEqual(chat["parallel_tool_calls"] as? Bool, false)
    }

    func testToolChoiceStringPassesThroughAndObjectNests() throws {
        let stringForm = try translate(["model": "m", "input": "hi", "tool_choice": "required"])
        XCTAssertEqual(stringForm["tool_choice"] as? String, "required")

        let objectForm = try translate([
            "model": "m", "input": "hi",
            "tool_choice": ["type": "function", "name": "lookup"],
        ])
        let choice = try XCTUnwrap(objectForm["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "function")
        XCTAssertEqual((choice["function"] as? [String: Any])?["name"] as? String, "lookup")
    }

    func testUnknownToolChoiceShapeDrops() throws {
        let chat = try translate([
            "model": "m", "input": "hi",
            "tool_choice": ["type": "file_search"],
        ])
        XCTAssertNil(chat["tool_choice"])
    }

    func testTextFormatMapsToResponseFormat() throws {
        let jsonObject = try translate([
            "model": "m", "input": "hi",
            "text": ["format": ["type": "json_object"]],
        ])
        XCTAssertEqual(
            (jsonObject["response_format"] as? [String: Any])?["type"] as? String,
            "json_object")

        let jsonSchema = try translate([
            "model": "m", "input": "hi",
            "text": ["format": [
                "type": "json_schema", "name": "out",
                "schema": ["type": "object"], "strict": true,
            ]],
        ])
        let format = try XCTUnwrap(jsonSchema["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let nested = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(nested["name"] as? String, "out")
        XCTAssertEqual(nested["strict"] as? Bool, true)
        XCTAssertNotNil(nested["schema"])

        let plainText = try translate([
            "model": "m", "input": "hi", "text": ["format": ["type": "text"]],
        ])
        XCTAssertNil(plainText["response_format"])
    }

    // MARK: - Hard-fail carve-out (ADR 0021)

    func testPreviousResponseIDThrows() {
        XCTAssertThrowsError(
            try OpencodeProtocolMapper.responsesRequestToChat(
                Data(#"{"model":"m","input":"hi","previous_response_id":"resp_1"}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? OpencodeMapperError,
                .statefulConversation(field: "previous_response_id"))
        }
    }

    func testConversationThrows() {
        XCTAssertThrowsError(
            try OpencodeProtocolMapper.responsesRequestToChat(
                Data(#"{"model":"m","input":"hi","conversation":"conv_1"}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? OpencodeMapperError,
                .statefulConversation(field: "conversation"))
        }
    }

    func testEmptyPreviousResponseIDIgnored() throws {
        // Absent or empty is not stateful — only a real reference fails.
        _ = try translate(["model": "m", "input": "hi", "previous_response_id": ""])
        _ = try translate(["model": "m", "input": "hi"])
    }
}
