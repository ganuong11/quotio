//
//  OpencodeRouteGateTests.swift
//  QuotioTests
//

import XCTest
@testable import QuotioDomain

final class OpencodeRouteGateTests: XCTestCase {

    private let allFree: (String) -> Bool = { _ in true }
    private let noneFree: (String) -> Bool = { _ in false }

    func testFreeModelChatCompletions() {
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/chat/completions",
                model: "opencode/big-pickle", isFreeModel: allFree),
            .chat
        )
    }

    func testFreeModelResponses() {
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/responses",
                model: "opencode/muse-spark-1.3-contributor-free", isFreeModel: allFree),
            .responses
        )
    }

    /// Either surface is valid for any free model — the client picks.
    func testSameModelBothSurfaces() {
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/responses",
                model: "opencode/big-pickle", isFreeModel: allFree),
            .responses
        )
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/chat/completions",
                model: "opencode/muse-spark-1.3-contributor-free", isFreeModel: allFree),
            .chat
        )
    }

    func testNotInFreeSet() {
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/chat/completions",
                model: "opencode/paid-model", isFreeModel: noneFree),
            .notInFreeSet
        )
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/responses",
                model: "opencode/paid-model", isFreeModel: noneFree),
            .notInFreeSet
        )
    }

    func testWrongMethodRejected() {
        for method in ["GET", "PUT", "DELETE", "post"] {
            XCTAssertEqual(
                OpencodeRouteGate.resolve(
                    method: method, path: "/v1/chat/completions",
                    model: "opencode/big-pickle", isFreeModel: allFree),
                .rejected, "method \(method)")
        }
    }

    func testWrongPathRejected() {
        for path in ["/v1/embeddings", "/v1/completions", "/v1/messages", "/v1/models"] {
            XCTAssertEqual(
                OpencodeRouteGate.resolve(
                    method: "POST", path: path,
                    model: "opencode/big-pickle", isFreeModel: allFree),
                .rejected, "path \(path)")
        }
    }

    func testNotOpencode() {
        for model in ["qwen/x", "qoder/auto", "gpt-4o", "opencode", "opencode-foo/x"] {
            XCTAssertEqual(
                OpencodeRouteGate.resolve(
                    method: "POST", path: "/v1/chat/completions",
                    model: model, isFreeModel: allFree),
                .notOpencode, "model \(model)")
        }
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/chat/completions",
                model: nil, isFreeModel: allFree),
            .notOpencode
        )
    }

    func testQueryStringStillMatches() {
        XCTAssertEqual(
            OpencodeRouteGate.resolve(
                method: "POST", path: "/v1/chat/completions?timeout=30",
                model: "opencode/big-pickle", isFreeModel: allFree),
            .chat
        )
    }

    /// The gate strips the prefix before consulting the free set — the
    /// catalog stores bare upstream ids.
    func testIsFreeReceivesStrippedID() {
        var seen: String?
        _ = OpencodeRouteGate.resolve(
            method: "POST", path: "/v1/chat/completions",
            model: "opencode/big-pickle",
            isFreeModel: { seen = $0; return true })
        XCTAssertEqual(seen, "big-pickle")
    }
}
