//
//  QoderOpenAIErrorTests.swift
//  QuotioTests
//
//  Tests for the OpenAI error envelope builder (issue #16, ADR 0010).
//  `QoderOpenAIError` is a port of CPA's `BuildErrorResponseBody`, so these
//  tests pin the status→type/code map, the empty-message → reason-phrase
//  fallback, the status<=0 → 500 default, the valid-JSON pass-through, and the
//  SSE terminal-frame shape. The builder is a pure value type with no I/O, so
//  every case is covered by a direct call and a JSON parse of the output.
//

import XCTest
@testable import Quotio

final class QoderOpenAIErrorTests: XCTestCase {

    // MARK: - Helpers

    /// Parse the builder's output as a JSON object. Fails the test if the body
    /// isn't a JSON object (every non-pass-through case must produce one).
    private func envelope(_ data: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("body is not a JSON object: \(String(data: data, encoding: .utf8) ?? "")")
            return [:]
        }
        return obj
    }

    /// The inner `error` dict, typed.
    private func errorDict(_ data: Data) -> [String: Any] {
        envelope(data)["error"] as? [String: Any] ?? [:]
    }

    // MARK: - Status → type/code map (ADR 0010 §Envelope shape)

    /// 400 → `invalid_request_error`, no `code` key present (Go's `omitempty`
    /// omits the empty string).
    func test400MapsToInvalidRequestNoCode() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 400, message: "bad"))
        XCTAssertEqual(err["type"] as? String, "invalid_request_error")
        XCTAssertEqual(err["message"] as? String, "bad")
        XCTAssertNil(err["code"], "400 must omit code (omitempty)")
    }

    /// 401 → `authentication_error` / `invalid_api_key`.
    func test401MapsToAuthenticationInvalidApiKey() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 401, message: "no key"))
        XCTAssertEqual(err["type"] as? String, "authentication_error")
        XCTAssertEqual(err["code"] as? String, "invalid_api_key")
    }

    /// 403 → `permission_error` / `insufficient_quota`.
    func test403MapsToPermissionInsufficientQuota() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 403, message: "no"))
        XCTAssertEqual(err["type"] as? String, "permission_error")
        XCTAssertEqual(err["code"] as? String, "insufficient_quota")
    }

    /// 404 → `invalid_request_error` / `model_not_found`.
    func test404MapsToInvalidRequestModelNotFound() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 404, message: "nope"))
        XCTAssertEqual(err["type"] as? String, "invalid_request_error")
        XCTAssertEqual(err["code"] as? String, "model_not_found")
    }

    /// 429 → `rate_limit_error` / `rate_limit_exceeded`.
    func test429MapsToRateLimitRateLimitExceeded() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 429, message: "slow"))
        XCTAssertEqual(err["type"] as? String, "rate_limit_error")
        XCTAssertEqual(err["code"] as? String, "rate_limit_exceeded")
    }

    /// 413 → `invalid_request_error` with no `code` (the default 4xx arm).
    /// Pins both the status→type/code map for 413 (issue #14's byte-size caps
    /// surface as 413) and the reason phrase used when the message is empty.
    func test413MapsToInvalidRequestNoCode() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 413, message: "too big"))
        XCTAssertEqual(err["type"] as? String, "invalid_request_error")
        XCTAssertEqual(err["message"] as? String, "too big")
        XCTAssertNil(err["code"], "413 must omit code (default 4xx arm, omitempty)")
    }

    /// 413 with an empty message falls back to "Payload Too Large" (issue #14
    /// acceptance: the reason phrase table must carry 413, otherwise an empty-
    /// message 413 response would ship with "Internal Server Error").
    func test413ReasonPhraseIsPayloadTooLarge() {
        XCTAssertEqual(QoderOpenAIError.reasonPhrase(for: 413), "Payload Too Large")
        let err = errorDict(QoderOpenAIError.body(statusCode: 413, message: ""))
        XCTAssertEqual(err["message"] as? String, "Payload Too Large")
    }

    /// 500 → `server_error` / `internal_server_error`. The whole 5xx arm maps
    /// the same way; parameterize across 500/502/503 to prove it.
    func test500MapsToServerErrorInternalServerError() throws {
        for status in [500, 502, 503] {
            let err = errorDict(QoderOpenAIError.body(statusCode: status, message: "x"))
            XCTAssertEqual(err["type"] as? String, "server_error", "status \(status)")
            XCTAssertEqual(err["code"] as? String, "internal_server_error", "status \(status)")
        }
    }

    // MARK: - JSON pass-through (ADR 0010 §JSON pass-through)

    /// A message that is itself valid JSON passes through verbatim — the key
    /// CPA-preserving case for upstream Qoder error payloads.
    func testJSONPassThrough() throws {
        // Plain object.
        let plain = #"{"foo":"bar"}"#
        let plainOut = QoderOpenAIError.body(statusCode: 400, message: plain)
        XCTAssertEqual(String(data: plainOut, encoding: .utf8), plain)

        // An upstream Qoder-shaped error envelope must be preserved byte for
        // byte — re-wrapping it would double-wrap the `error` key.
        let qoderShape = #"{"error":{"message":"quota","type":"quota_exceeded"}}"#
        let qoderOut = QoderOpenAIError.body(statusCode: 403, message: qoderShape)
        XCTAssertEqual(String(data: qoderOut, encoding: .utf8), qoderShape)
    }

    // MARK: - Empty message → HTTP reason phrase (CPA parity)

    /// Empty message falls back to the canonical HTTP reason phrase for the
    /// status (CPA: `errText = http.StatusText(status)`).
    func testEmptyMessageFallsBackToReasonPhrase() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 400, message: ""))
        XCTAssertEqual(err["message"] as? String, "Bad Request")
        XCTAssertEqual(err["type"] as? String, "invalid_request_error")

        // Spot-check a couple more phrases to pin the map.
        XCTAssertEqual(errorDict(QoderOpenAIError.body(statusCode: 401, message: ""))["message"] as? String, "Unauthorized")
        XCTAssertEqual(errorDict(QoderOpenAIError.body(statusCode: 429, message: ""))["message"] as? String, "Too Many Requests")
        XCTAssertEqual(errorDict(QoderOpenAIError.body(statusCode: 503, message: ""))["message"] as? String, "Service Unavailable")
    }

    // MARK: - status <= 0 → 500 (CPA parity)

    /// `status <= 0` defaults to 500, which then maps to server_error /
    /// internal_server_error with the 500 reason phrase.
    func testStatusZeroDefaultsTo500() throws {
        let err = errorDict(QoderOpenAIError.body(statusCode: 0, message: ""))
        XCTAssertEqual(err["type"] as? String, "server_error")
        XCTAssertEqual(err["code"] as? String, "internal_server_error")
        XCTAssertEqual(err["message"] as? String, "Internal Server Error")

        // Negative behaves the same (CPA: status <= 0 → 500).
        let neg = errorDict(QoderOpenAIError.body(statusCode: -1, message: ""))
        XCTAssertEqual(neg["type"] as? String, "server_error")
    }

    // MARK: - SSE terminal frame (ADR 0010 §Mid-stream)

    /// The terminal frame is two `data:` lines: the envelope JSON, then
    /// `[DONE]`. The Chat Completions streaming path emits this on a mid-stream
    /// failure (the Responses path uses `QoderResponsesAdapter.errorEvent`
    /// instead — covered in its own tests).
    func testSSETerminalFrameShape() throws {
        let frame = QoderOpenAIError.sseTerminalFrame(statusCode: 502, message: "boom")
        let text = String(data: frame, encoding: .utf8) ?? ""

        // Opens with the envelope line and closes with the DONE sentinel. The
        // envelope's `error` is an object (not a string), so the first data
        // line is `data: {"error":{...}}`. (Key order in the serialized dict is
        // not guaranteed, so we only assert the opening `error` key here and
        // compare the rest structurally below.)
        XCTAssertTrue(text.hasPrefix(#"data: {"error":{"#), "frame must open with the envelope line: \(text)")
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"), "frame must end with data: [DONE]\\n\\n: \(text)")

        // The envelope between the framing carries the same error payload `body`
        // produces. Compare structurally (parsed dicts), not byte-for-byte —
        // `JSONSerialization` over a `[String:Any]` dict is not guaranteed to
        // emit keys in the same order across two calls, so a string compare of
        // the two serializations would be flaky. Both must deserialize to the
        // same `error` object.
        let lines = text.components(separatedBy: "\n")
        let dataLines = lines.filter { $0.hasPrefix("data: ") }
        XCTAssertEqual(dataLines.count, 2, "frame must carry exactly two data: lines: \(text)")
        XCTAssertEqual(dataLines.last, "data: [DONE]", "second data: line must be [DONE]: \(text)")

        let envelopePayload = String(dataLines.first!.dropFirst("data: ".count))
        let envelopeErr = errorDict(Data(envelopePayload.utf8))
        let bodyErr = errorDict(QoderOpenAIError.body(statusCode: 502, message: "boom"))
        XCTAssertEqual(envelopeErr["type"] as? String, bodyErr["type"] as? String)
        XCTAssertEqual(envelopeErr["code"] as? String, bodyErr["code"] as? String)
        XCTAssertEqual(envelopeErr["message"] as? String, bodyErr["message"] as? String)
    }
}
