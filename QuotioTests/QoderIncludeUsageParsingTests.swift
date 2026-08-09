//
//  QoderIncludeUsageParsingTests.swift
//  QuotioTests
//
//  Issue #19: tests for ProxyBridge's `stream_options.include_usage` parsing
//  seam. The OpenAI streaming contract emits the trailing usage-only chunk
//  ONLY when this field is `true`; missing/malformed → `false` (spec default).
//  ProxyBridge reads this flag from the request body and threads it into the
//  QoderSSEReparser; these tests pin the parser boundary behavior directly
//  (the reparser-side gating is covered in QoderSSEReparserTests).
//

import XCTest
@testable import Quotio

final class QoderIncludeUsageParsingTests: XCTestCase {

    /// Helper: build a JSON body from a dictionary.
    private func body(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Truthy cases

    /// Explicit `stream_options.include_usage: true` → true.
    func testExplicitIncludeUsageTrue() {
        let body = body([
            "model": "qoder/x",
            "stream": true,
            "stream_options": ["include_usage": true] as [String: Any],
        ])
        XCTAssertTrue(ProxyBridge.includeUsageFlag(in: body))
    }

    // MARK: - Falsy cases (issue #19 acceptance: the three required cases)

    /// Explicit `stream_options.include_usage: false` → false.
    func testExplicitIncludeUsageFalse() {
        let body = body([
            "model": "qoder/x",
            "stream": true,
            "stream_options": ["include_usage": false] as [String: Any],
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// Missing `stream_options` entirely → false (spec default).
    func testMissingStreamOptions() {
        let body = body([
            "model": "qoder/x",
            "stream": true,
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// Missing `stream` field entirely → false. (The reparser is only reached
    /// on the streaming path, but the parser must still tolerate a body with
    /// neither field — guards a client that sent `include_usage` somewhere
    /// unexpected or nothing at all.)
    func testMissingStream() {
        let body = body(["model": "qoder/x"])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    // MARK: - Boundary / malformed cases

    /// `stream_options` present but `include_usage` absent → false (the inner
    /// field defaults to false; a stream_options object without it is not an
    /// opt-in).
    func testStreamOptionsWithoutIncludeUsage() {
        let body = body([
            "model": "qoder/x",
            "stream_options": [:] as [String: Any],
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// `stream_options` is a non-object value (string) → false. Tolerates a
    /// client that sent a malformed `stream_options`.
    func testStreamOptionsIsString() {
        let body = body([
            "model": "qoder/x",
            "stream_options": "true",   // malformed — not an object
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// `stream_options` is a number → false (non-object).
    func testStreamOptionsIsNumber() {
        let body = body([
            "model": "qoder/x",
            "stream_options": 1,
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// `include_usage` is a non-boolean truthy value (string "true") → false.
    /// The OpenAI contract expects a JSON boolean; a string is not an opt-in.
    func testIncludeUsageIsString() {
        let body = body([
            "model": "qoder/x",
            "stream_options": ["include_usage": "true"] as [String: Any],
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// `include_usage` is a number (1) → false. Only a JSON boolean `true`
    /// opts in.
    func testIncludeUsageIsNumber() {
        let body = body([
            "model": "qoder/x",
            "stream_options": ["include_usage": 1] as [String: Any],
        ])
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// Entirely malformed body (not valid JSON) → false. The parser must
    /// never throw; a parse failure is treated as no opt-in.
    func testMalformedJSONBody() {
        let body = Data("{\"model\": \"qoder/x\",".utf8)   // truncated JSON
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: body))
    }

    /// Empty body → false.
    func testEmptyBody() {
        XCTAssertFalse(ProxyBridge.includeUsageFlag(in: Data()))
    }

    /// `include_usage: true` is honored even when `stream: false` — the parser
    /// only reflects the client's stated intent, it does not second-guess it.
    /// (ProxyBridge's routing decides whether the reparser is even reached.)
    func testIncludeUsageTrueIndependentOfStream() {
        let body = body([
            "model": "qoder/x",
            "stream": false,
            "stream_options": ["include_usage": true] as [String: Any],
        ])
        XCTAssertTrue(ProxyBridge.includeUsageFlag(in: body),
                      "parser must reflect the stated opt-in; routing is a separate concern")
    }
}
