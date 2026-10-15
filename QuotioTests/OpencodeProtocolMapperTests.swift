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

    // MARK: - Chat → Responses (Phase 2b — the reverse translator)

    private func translateBack(_ dict: [String: Any]) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: dict)
        let out = try OpencodeProtocolMapper.chatRequestToResponses(body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func testLeadingSystemBecomesInstructions() throws {
        // Only a LEADING system message feeds `instructions`; the rest of the
        // conversation maps to input items in order (plan §2b).
        let responses = try translateBack([
            "model": "opencode/muse-spark-1.3-contributor-free",
            "messages": [
                ["role": "system", "content": "be terse"],
                ["role": "user", "content": "hi"],
            ],
        ])
        XCTAssertEqual(responses["instructions"] as? String, "be terse")
        XCTAssertEqual(responses["model"] as? String, "opencode/muse-spark-1.3-contributor-free")
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
    }

    func testInterleavedSystemStaysInPlaceAsItem() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [
                ["role": "user", "content": "first"],
                ["role": "system", "content": "mid-course correction"],
                ["role": "user", "content": "second"],
            ],
        ])
        XCTAssertNil(responses["instructions"], "no leading system → no instructions")
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["role"] as? String }, ["user", "system", "user"])
    }

    func testUserTextBecomesInputTextPart() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
        ])
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "input_text")
        XCTAssertEqual(parts[0]["text"] as? String, "hi")
    }

    func testAssistantTextHistoryBecomesOutputTextPart() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "assistant", "content": "hello"],
            ],
        ])
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "output_text")
    }

    func testContentPartsMapWithImages() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "what is this"],
                    ["type": "image_url", "image_url": ["url": "https://x.example/i.png"]],
                ],
            ]],
        ])
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        let parts = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "input_text")
        XCTAssertEqual(parts[1]["type"] as? String, "input_image")
        XCTAssertEqual(parts[1]["image_url"] as? String, "https://x.example/i.png")
    }

    func testToolCallsBecomeFunctionCallItems() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [
                ["role": "user", "content": "read /x"],
                [
                    "role": "assistant", "content": NSNull(),
                    "tool_calls": [[
                        "id": "call_1", "type": "function",
                        "function": ["name": "read", "arguments": #"{"filePath":"/x"}"#],
                    ]],
                ],
                ["role": "tool", "tool_call_id": "call_1", "content": "file bytes"],
                ["role": "user", "content": "thanks"],
            ],
        ])
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["type"] as? String ?? "message" },
                       ["message", "function_call", "function_call_output", "message"])
        let call = try XCTUnwrap(input[1])
        XCTAssertEqual(call["call_id"] as? String, "call_1")
        XCTAssertEqual(call["name"] as? String, "read")
        XCTAssertEqual(call["arguments"] as? String, #"{"filePath":"/x"}"#)
        let output = try XCTUnwrap(input[2])
        XCTAssertEqual(output["call_id"] as? String, "call_1")
        XCTAssertEqual(output["output"] as? String, "file bytes")
    }

    func testTokenSpellingsMapToMaxOutputTokens() throws {
        let legacy = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]], "max_tokens": 128,
        ])
        XCTAssertEqual(legacy["max_output_tokens"] as? Int, 128)
        let modern = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "max_completion_tokens": 256,
        ])
        XCTAssertEqual(modern["max_output_tokens"] as? Int, 256)
    }

    func testReasoningEffortBecomesReasoningObject() throws {
        let responses = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "reasoning_effort": "low",
        ])
        XCTAssertEqual((responses["reasoning"] as? [String: Any])?["effort"] as? String, "low")
    }

    func testNestedToolsBecomeFlatResponsesShape() throws {
        let responses = try translateBack([
            "model": "m",
            "messages": [["role": "user", "content": "hi"]],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "lookup", "description": "look things up",
                    "parameters": ["type": "object", "properties": ["q": ["type": "string"]]],
                ],
            ]],
        ])
        let tools = try XCTUnwrap(responses["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["name"] as? String, "lookup")
        XCTAssertEqual(tools[0]["description"] as? String, "look things up")
        XCTAssertNotNil((tools[0]["parameters"] as? [String: Any])?["properties"],
                        "responses tools are flat: name/description/parameters at top level")
    }

    func testToolChoiceObjectFlattens() throws {
        let stringForm = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]], "tool_choice": "auto",
        ])
        XCTAssertEqual(stringForm["tool_choice"] as? String, "auto")

        let objectForm = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "tool_choice": ["type": "function", "function": ["name": "lookup"]],
        ])
        let choice = try XCTUnwrap(objectForm["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "function")
        XCTAssertEqual(choice["name"] as? String, "lookup")
    }

    func testResponseFormatMapsToTextFormat() throws {
        let jsonObject = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "response_format": ["type": "json_object"],
        ])
        XCTAssertEqual(
            ((jsonObject["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String,
            "json_object")

        let jsonSchema = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "out", "schema": ["type": "object"], "strict": true],
            ],
        ])
        let format = try XCTUnwrap((jsonSchema["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["name"] as? String, "out")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertNotNil(format["schema"])
    }

    func testSamplingParametersPassThroughOnReverse() throws {
        let responses = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "temperature": 0.2, "top_p": 0.9, "parallel_tool_calls": false, "user": "u-1",
        ])
        XCTAssertEqual(responses["temperature"] as? Double, 0.2)
        XCTAssertEqual(responses["top_p"] as? Double, 0.9)
        XCTAssertEqual(responses["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual(responses["user"] as? String, "u-1")
    }

    func testStopIsDropped() throws {
        // `stop` has no Responses equivalent — documented drop (plan Risks).
        let responses = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "stop": ["\n"],
        ])
        XCTAssertNil(responses["stop"])
    }

    func testStreamOptionsDroppedOnReverse() throws {
        // `stream_options` is a chat-surface knob; usage placement on the
        // responses surface is the terminal event, always present.
        let responses = try translateBack([
            "model": "m", "messages": [["role": "user", "content": "hi"]],
            "stream": false, "stream_options": ["include_usage": true],
        ])
        XCTAssertNil(responses["stream_options"])
    }

    func testLegacyFunctionRoleMapsToFunctionCallOutput() throws {
        // The deprecated `function` role is the legacy spelling of `tool` —
        // it must not become a message item with an invalid role.
        let responses = try translateBack([
            "model": "m",
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "function", "name": "lookup", "content": "result bytes"],
            ],
        ])
        let input = try XCTUnwrap(responses["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["type"] as? String, "function_call_output")
    }
}
