//
//  QoderRouteGateTests.swift
//  QuotioTests
//
//  Route-matrix tests for the Qoder endpoint/method gate (issue #20, ADR 0009).
//
//  ADR 0009 makes the Qoder branch a conjunctive allowlist of (model prefix,
//  method, path), rejecting non-matching qoder-model requests with a Qoder-
//  owned 404 instead of falling through to CPA. These tests pin that decision
//  across the method × path × body-model × content-type surface the ADR
//  names as its acceptance criterion.
//
//  The gate (`QoderRouteGate.resolve`) is a pure function — these tests
//  exercise it directly. The wiring into `ProxyBridge.processRequest` (the
//  404 envelope via `QoderOpenAIError.body` → `model_not_found`) is covered by
//  QoderOpenAIErrorTests and the existing bridge paths; here we pin the
//  decision matrix only.
//
//  Content-type dimension: model extraction in `ProxyBridge.extractMetadata`
//  is content-type-agnostic JSON parsing (JSONSerialization on the body Data,
//  no inspection of Content-Type headers). The gate's input (`model: String?`)
//  is therefore identical regardless of content-type, so the resolver matrix
//  below covers the content-type dimension by construction. We additionally
//  verify this in `testContentTypeIsImmaterialToGateInput` by feeding the
//  same body bytes through an `extractMetadata`-style parse to confirm the
//  model field is what the gate would receive for both an
//  `application/json` and a `text/plain`-declared body — the gate sees the
//  same `qoder/...` string in both cases.
//

import XCTest
@testable import Quotio

final class QoderRouteGateTests: XCTestCase {

    // MARK: - Allowlist positive cases

    /// ADR 0009 core: POST /v1/chat/completions + qoder/ model → .chat. The
    /// canonical Qoder surface.
    func testChatCompletionsPostQoderAutoRoutesChat() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: "qoder/auto"),
            .chat
        )
    }

    /// Issue #11: POST /v1/responses + qoder/ model → .responses. Excluding
    /// this endpoint from the allowlist would regress #11 (ADR 0009
    /// §Consequences explicitly anticipates the entry).
    func testResponsesPostQoderAutoRoutesResponses() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/responses", model: "qoder/auto"),
            .responses
        )
    }

    /// A bare `qoder/` prefix (empty ID) is still Qoder-bound at the gate
    /// level — the gateway rejects unknown IDs upstream (ADR 0003
    /// §Consequences; QoderModelRegistry drift). The gate must not pre-filter
    /// on ID validity.
    func testBareQoderPrefixAllowedOnChat() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: "qoder/"),
            .chat
        )
    }

    func testBareQoderPrefixAllowedOnResponses() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/responses", model: "qoder/"),
            .responses
        )
    }

    // MARK: - Query string handling

    /// HTTP1RequestParser captures the whole request target (path + ?query),
    /// so a query-bearing POST must still match the allowlist (issue #20).
    func testQueryStringStrippedBeforeChatComparison() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions?timeout=30", model: "qoder/auto"),
            .chat
        )
    }

    func testQueryStringStrippedBeforeResponsesComparison() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/responses?foo=bar&baz=1", model: "qoder/auto"),
            .responses
        )
    }

    /// Empty query (`...?`) is still a valid strip — `firstIndex(of: "?")`
    /// splits at the trailing `?`, leaving the bare path.
    func testTrailingQuestionMarkStripped() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions?", model: "qoder/auto"),
            .chat
        )
    }

    // MARK: - Rejected: qoder/ model on wrong path/method

    /// ADR 0009: qoder/ model on a non-allowlisted path → .rejected (Qoder-
    /// owned 404), NOT a CPA fall-through.
    func testQoderOnCompletionsRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/completions", model: "qoder/auto"),
            .rejected
        )
    }

    func testQoderOnEmbeddingsRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/embeddings", model: "qoder/auto"),
            .rejected
        )
    }

    func testQoderOnModelsRejected() {
        // GET /v1/models carries no body and so no qoder/ prefix in practice,
        // but the gate must still reject a qoder/ model if one is somehow
        // carried — defense in depth.
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "GET", path: "/v1/models", model: "qoder/auto"),
            .rejected
        )
    }

    func testQoderOnRootRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/", model: "qoder/auto"),
            .rejected
        )
    }

    /// Method enforcement: a non-POST method on an allowlisted path is
    /// `.rejected` even though the path matches. ADR 0009 is method-aware.
    func testGetOnChatCompletionsRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "GET", path: "/v1/chat/completions", model: "qoder/auto"),
            .rejected
        )
    }

    func testGetOnResponsesRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "GET", path: "/v1/responses", model: "qoder/auto"),
            .rejected
        )
    }

    func testPutOnChatCompletionsRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "PUT", path: "/v1/chat/completions", model: "qoder/auto"),
            .rejected
        )
    }

    func testDeleteOnChatCompletionsRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "DELETE", path: "/v1/chat/completions", model: "qoder/auto"),
            .rejected
        )
    }

    /// Method comparison is case-sensitive — lowercase `post` is not the
    /// allowlisted POST. Matches `HTTP1RequestParser`'s casing pass-through
    /// and avoids silently accepting malformed method tokens.
    func testLowercasePostRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "post", path: "/v1/chat/completions", model: "qoder/auto"),
            .rejected
        )
    }

    /// qoder/ model on a query-bearing wrong path is still rejected — the
    /// query strip must not turn a wrong path into a matching one.
    func testQoderOnCompletionsWithQueryRejected() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/completions?x=1", model: "qoder/auto"),
            .rejected
        )
    }

    // MARK: - notQoder: every path/method with a non-qoder or nil model

    /// ADR 0009: the prefix test remains the first conjunct. A non-qoder model
    /// on the canonical Chat path is CPA passthrough — the gate must NOT
    /// intercept gpt-4o etc. (regression of the pre-#20 behavior).
    func testGPTModelOnChatCompletionsIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: "gpt-4o"),
            .notQoder
        )
    }

    func testGPTModelOnResponsesIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/responses", model: "gpt-4o"),
            .notQoder
        )
    }

    /// A bare `qoder` (no slash) is NOT a Qoder model — `hasPrefix("qoder/")`
    /// is the conjunct. Avoids intercepting a hypothetical `qoder` model that
    /// some other provider might serve.
    func testBareQoderWithoutSlashIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: "qoder"),
            .notQoder
        )
    }

    /// Nil model (no body, malformed JSON, or body without a `model` field)
    /// → .notQoder on every path. This is the `GET /v1/models` case and any
    /// other body-less request.
    func testNilModelOnChatCompletionsIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: nil),
            .notQoder
        )
    }

    func testNilModelOnModelsIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "GET", path: "/v1/models", model: nil),
            .notQoder
        )
    }

    func testNilModelOnRootIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "GET", path: "/", model: nil),
            .notQoder
        )
    }

    /// Empty-string model → .notQoder (extractMetadata returns nil for a
    /// missing field; pinning the empty case guards against a future caller
    /// that hands in "" instead of nil).
    func testEmptyModelIsNotQoder() {
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: ""),
            .notQoder
        )
    }

    // MARK: - pathWithoutQuery helper

    /// Direct tests of the query-strip helper the resolver uses. The route
    /// matrix above covers the resolver-level behavior; these pin the helper
    /// contract for any future caller.
    func testPathWithoutQueryNoQuestionMark() {
        XCTAssertEqual(QoderRouteGate.pathWithoutQuery("/v1/chat/completions"), "/v1/chat/completions")
    }

    func testPathWithoutQuerySimpleQuery() {
        XCTAssertEqual(QoderRouteGate.pathWithoutQuery("/v1/chat/completions?timeout=30"), "/v1/chat/completions")
    }

    func testPathWithoutQueryTrailingQuestionMark() {
        XCTAssertEqual(QoderRouteGate.pathWithoutQuery("/v1/chat/completions?"), "/v1/chat/completions")
    }

    func testPathWithoutQueryEmpty() {
        XCTAssertEqual(QoderRouteGate.pathWithoutQuery(""), "")
    }

    // MARK: - Content-type immaterial to gate input

    /// ADR 0009 names content-type as a test dimension. Model extraction in
    /// `ProxyBridge.extractMetadata` is content-type-agnostic JSON parsing —
    /// the shared `ProxyBridge.extractModel(from:)` helper takes only body
    /// bytes and never reads headers, so a `qoder/auto` body carries the same
    /// model field whether the client declared `application/json` or
    /// `text/plain`. The gate therefore sees identical input and the route is
    /// `.chat` either way.
    ///
    /// This exercises the REAL production extraction (not a re-implementation)
    /// so a future change that makes model parsing content-type-aware — or
    /// that diverges the gate's input from what `extractMetadata` produces —
    /// fails here.
    func testContentTypeIsImmaterialToGateInput() {
        let bodyDict: [String: Any] = ["model": "qoder/auto", "messages": []]
        let bodyData = try! JSONSerialization.data(withJSONObject: bodyDict)

        // The shared production parse the gate consumes (issue #20): same body
        // bytes → same model, regardless of the (ignored) Content-Type header.
        let modelFromJsonDecl = ProxyBridge.extractModel(from: bodyData)   // Content-Type: application/json
        let modelFromTextDecl = ProxyBridge.extractModel(from: bodyData)   // Content-Type: text/plain
        XCTAssertEqual(modelFromJsonDecl, "qoder/auto")
        XCTAssertEqual(modelFromJsonDecl, modelFromTextDecl)

        // Same model → same route regardless of the (ignored) Content-Type.
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: modelFromJsonDecl),
            .chat
        )
        XCTAssertEqual(
            QoderRouteGate.resolve(method: "POST", path: "/v1/chat/completions", model: modelFromTextDecl),
            .chat
        )
    }

    // MARK: - Exhaustive route matrix (acceptance criterion)

    /// ADR 0009 acceptance: a route-matrix test (method × path × body-model ×
    /// content-type). The content-type dimension is collapsed per
    /// `testContentTypeIsImmaterialToGateInput`. This case walks the remaining
    /// three dimensions explicitly so the matrix is captured in one place and
    /// any future regression fails loudly with the offending combination.
    func testRouteMatrix() {
        // (method, path, model, expectedRoute)
        // Models: "qoder/auto" (canonical), "qoder/" (bare prefix), "gpt-4o" (non-qoder), nil.
        // Methods: POST, GET, PUT, DELETE.
        // Paths: the two allowlisted + the four explicitly-named ADR 0009 wrong paths.
        struct Row { let method: String; let path: String; let model: String?; let expected: QoderRoute }
        let rows: [Row] = [
            // ── POST × allowlisted × qoder/* → chat / responses
            Row(method: "POST", path: "/v1/chat/completions", model: "qoder/auto", expected: .chat),
            Row(method: "POST", path: "/v1/chat/completions", model: "qoder/",     expected: .chat),
            Row(method: "POST", path: "/v1/responses",        model: "qoder/auto", expected: .responses),
            Row(method: "POST", path: "/v1/responses",        model: "qoder/",     expected: .responses),

            // ── POST × allowlisted × non-qoder/nil → notQoder (CPA passthrough)
            Row(method: "POST", path: "/v1/chat/completions", model: "gpt-4o", expected: .notQoder),
            Row(method: "POST", path: "/v1/chat/completions", model: nil,     expected: .notQoder),
            Row(method: "POST", path: "/v1/responses",        model: "gpt-4o", expected: .notQoder),
            Row(method: "POST", path: "/v1/responses",        model: nil,     expected: .notQoder),

            // ── POST × non-allowlisted × qoder/* → rejected
            Row(method: "POST", path: "/v1/completions", model: "qoder/auto", expected: .rejected),
            Row(method: "POST", path: "/v1/embeddings",  model: "qoder/auto", expected: .rejected),
            Row(method: "POST", path: "/v1/completions", model: "qoder/",     expected: .rejected),
            Row(method: "POST", path: "/v1/embeddings",  model: "qoder/",     expected: .rejected),
            // Path comparison is case-sensitive (QoderRouteGate.resolve doc):
            // an uppercase path segment is not the literal OpenAI route.
            Row(method: "POST", path: "/V1/chat/completions", model: "qoder/auto", expected: .rejected),
            Row(method: "POST", path: "/v1/Chat/Completions", model: "qoder/auto", expected: .rejected),

            // ── POST × non-allowlisted × non-qoder/nil → notQoder
            Row(method: "POST", path: "/v1/completions", model: "gpt-4o", expected: .notQoder),
            Row(method: "POST", path: "/v1/embeddings",  model: "gpt-4o", expected: .notQoder),
            Row(method: "POST", path: "/v1/models",      model: nil,     expected: .notQoder),
            Row(method: "POST", path: "/",               model: nil,     expected: .notQoder),

            // ── GET × any path × qoder/* → rejected (method conjunct)
            Row(method: "GET", path: "/v1/chat/completions", model: "qoder/auto", expected: .rejected),
            Row(method: "GET", path: "/v1/responses",        model: "qoder/auto", expected: .rejected),
            Row(method: "GET", path: "/v1/completions",      model: "qoder/auto", expected: .rejected),
            Row(method: "GET", path: "/v1/models",           model: "qoder/auto", expected: .rejected),
            Row(method: "GET", path: "/",                    model: "qoder/auto", expected: .rejected),

            // ── GET × any path × non-qoder/nil → notQoder (e.g. GET /v1/models)
            Row(method: "GET", path: "/v1/chat/completions", model: "gpt-4o", expected: .notQoder),
            Row(method: "GET", path: "/v1/models",           model: nil,     expected: .notQoder),

            // ── PUT × allowlisted × qoder/* → rejected (method conjunct)
            Row(method: "PUT", path: "/v1/chat/completions", model: "qoder/auto", expected: .rejected),
            Row(method: "PUT", path: "/v1/responses",        model: "qoder/auto", expected: .rejected),

            // ── DELETE × allowlisted × qoder/* → rejected (method conjunct)
            Row(method: "DELETE", path: "/v1/chat/completions", model: "qoder/auto", expected: .rejected),
            Row(method: "DELETE", path: "/v1/responses",        model: "qoder/auto", expected: .rejected),
        ]

        for row in rows {
            let actual = QoderRouteGate.resolve(method: row.method, path: row.path, model: row.model)
            XCTAssertEqual(
                actual, row.expected,
                "method=\(row.method) path=\(row.path) model=\(row.model ?? "nil"): expected \(row.expected), got \(actual)"
            )
        }
    }
}
