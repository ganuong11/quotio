//
//  OpencodeRouterTests.swift
//  QuotioTests
//

import Foundation
import XCTest
@testable import Quotio

// MARK: - test helpers

private actor InMemoryCredentialStore: MonitorCredentialStore {
    private var credentials: [String: MonitorOAuthCredential] = [:]
    private var accountsList: [MonitorAccount] = []

    func seed(_ account: MonitorAccount, _ credential: MonitorOAuthCredential) {
        accountsList.append(account)
        credentials[account.id] = credential
    }

    func stored(_ accountID: String) -> MonitorOAuthCredential? { credentials[accountID] }
    func accounts() async -> [MonitorAccount] { accountsList }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        credentials[account.id] = credential
    }
    func delete(accountID: String) async {
        credentials.removeValue(forKey: accountID)
        accountsList.removeAll { $0.id == accountID }
    }
}

/// Scripted upstream client — records each call, drains a response queue.
private actor MockUpstream: OpencodeUpstreamClientProtocol {
    struct Call: Sendable {
        let url: String
        let headers: [(String, String)]
        let body: Data
    }
    private var queue: [Result<OpencodeUpstreamStream, Error>] = []
    private(set) var calls: [Call] = []

    func seed(_ result: Result<OpencodeUpstreamStream, Error>) { queue.append(result) }

    func post(url: URL, headers: [(String, String)], body: Data) async throws -> OpencodeUpstreamStream {
        calls.append(Call(url: url.absoluteString, headers: headers, body: body))
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try queue.removeFirst().get()
    }
}

private final class PullBox: @unchecked Sendable {
    private var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func next() -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
}

private func cannedStream(status: Int, body: String = "", headers: [(String, String)] = []) -> OpencodeUpstreamStream {
    let box = PullBox(body.isEmpty ? [] : [Data(body.utf8)])
    return OpencodeUpstreamStream(status: status, headers: headers) { box.next() }
}

private final class DataBox: @unchecked Sendable {
    private(set) var data = Data()
    func append(_ d: Data) { data.append(d) }
}

final class OpencodeRouterTests: XCTestCase {

    private var tempDir: URL!
    private var catalog: OpencodeModelCatalog!
    private var store: InMemoryCredentialStore!
    private var upstream: MockUpstream!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        catalog = OpencodeModelCatalog(session: StubURLProtocol.makeSession(), storageDirectory: tempDir)
        // Populate the free set with one model per surface kind so the
        // defensive catalog check passes and dispatch has real surfaces:
        // big-pickle = chat-native (the default/legacy fixture model),
        // muse-spark = responses-native, the rest = unservable-native.
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "fetchedAt": 756_000_000,
            "models": [
                ["id": "big-pickle", "displayName": "Big Pickle", "surface": "chat"],
                ["id": "muse-spark-1.3-contributor-free", "displayName": "Muse Spark", "surface": "responses"],
                ["id": "anthropic-free-x", "displayName": "Anthropic X", "surface": "messages"],
                ["id": "gemini-free-x", "displayName": "Gemini X", "surface": "gemini"],
            ],
        ])
        try snapshot.write(to: tempDir.appendingPathComponent("catalog-v2.json"))
        await catalog.loadPersisted()
        store = InMemoryCredentialStore()
        upstream = MockUpstream()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeRouter(detected: @escaping @Sendable () -> [DetectedOpencodeCredential] = { [] }) -> OpencodeRouter {
        OpencodeRouter(
            catalog: catalog,
            console: OpencodeConsoleClient(session: StubURLProtocol.makeSession()),
            upstream: upstream,
            vault: store,
            metadata: MonitorMetadataStore(url: tempDir.appendingPathComponent("accounts-test.json")),
            detectedSnapshot: detected
        )
    }

    @discardableResult
    private func seedVaultAccount(
        key: String = "usr_1", accessToken: String = "at-1",
        refreshToken: String? = "rt-1",
        expiresAt: Date = Date().addingTimeInterval(3600),
        orgID: String? = nil, server: String? = nil
    ) async -> MonitorAccount {
        var extra: [String: String] = [:]
        if let orgID { extra["orgID"] = orgID }
        if let server { extra["server"] = server }
        let account = MonitorAccount.make(
            provider: .opencode, accountKey: key,
            source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let credential = MonitorOAuthCredential(
            accessToken: accessToken, refreshToken: refreshToken,
            accountID: key, expiresAt: expiresAt, extra: extra)
        await store.seed(account, credential)
        return account
    }

    private let chatBody = Data(#"{"model":"opencode/big-pickle","messages":[{"role":"user","content":"hi"}]}"#.utf8)

    // MARK: - tests

    func testNoAccounts() async {
        let router = makeRouter()
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
    }

    func testForwardsStrippedModelWithHeaders() async throws {
        await seedVaultAccount(accessToken: "at-secret", orgID: "org-9")
                await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url, "https://opencode.ai/inference/v1/chat/completions")
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-secret")
        XCTAssertTrue(headers["user-agent"]?.hasPrefix("opencode/") ?? false)
        XCTAssertEqual(headers["x-opencode-client"], "cli")
        XCTAssertEqual(headers["x-opencode-request"]?.hasPrefix("msg_"), true)
        XCTAssertEqual(headers["x-opencode-session"]?.hasPrefix("ses_"), true)
        XCTAssertEqual(headers["x-org-id"], "org-9")
        XCTAssertEqual(headers["content-type"], "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "big-pickle")
    }

    // MARK: - Surface dispatch (ADR 0021)

    /// A Responses-speaking client on a chat-native model (2a): the request
    /// is translated to Chat Completions, posted to the chat surface, and
    /// the opened stream carries the translation plan for ProxyBridge.
    func testResponsesClientOnChatModelTranslatesToChatSurface() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let responsesBody = Data(#"{"model":"opencode/big-pickle","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}],"stream":true}"#.utf8)
        let opened = try await router.open(requestBody: responsesBody, route: .responses)
        XCTAssertEqual(opened.plan, .responsesToChat)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url, "https://opencode.ai/inference/v1/chat/completions")
        // The upstream body is Chat-shaped: messages (not input), forced
        // stream:true, a chat-shape read tool, and include_usage (Responses
        // clients always expect usage on response.completed).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNotNil(json["messages"] as? [[String: Any]])
        XCTAssertNil(json["input"])
        XCTAssertEqual((json["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains {
            (($0["function"] as? [String: Any])?["name"] as? String) == "read"
        }, "injected read tool must use the chat (nested) shape on the chat surface")
    }

    /// Responses-native passthrough: the URL keeps the responses surface and
    /// the injected read tool uses the flat responses shape. `stream_options`
    /// is NOT injected (that is a chat-surface-only knob).
    func testResponsesNativeModelPassthroughUsesFlatReadTool() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi","stream":true}"#.utf8)
        let opened = try await router.open(requestBody: body, route: .responses)
        XCTAssertEqual(opened.plan, .passthrough(native: .responses))

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url, "https://opencode.ai/inference/v1/responses")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertNil(json["stream_options"])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let read = try XCTUnwrap(tools.first { ($0["name"] as? String) == "read" })
        XCTAssertNotNil(read["parameters"], "responses-shape read tool is flat: name/parameters at top level")
        XCTAssertNil(read["function"])
    }

    /// Chat client × responses-native model (Phase 2b): the request is
    /// translated to the Responses surface, posted there, and the opened
    /// stream carries the reverse-translation plan for ProxyBridge.
    func testChatClientOnResponsesModelTranslatesToResponsesSurface() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
        let opened = try await router.open(requestBody: body, route: .chat)
        XCTAssertEqual(opened.plan, .chatToResponses)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url, "https://opencode.ai/inference/v1/responses")
        // The upstream body is Responses-shaped: input items (not messages),
        // forced stream:true, a flat responses-shape read tool, and NO
        // stream_options (chat-surface-only knob — usage rides the terminal
        // event on the responses surface).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "muse-spark-1.3-contributor-free")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNotNil(json["input"] as? [[String: Any]])
        XCTAssertNil(json["messages"])
        XCTAssertNil(json["stream_options"])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let read = try XCTUnwrap(tools.first { ($0["name"] as? String) == "read" })
        XCTAssertNil(read["function"], "responses-shape read tool is flat")
        XCTAssertNotNil(read["parameters"])
    }

    /// A chat body that cannot be translated (malformed JSON) is the client's
    /// to fix — 400, not an upstream-flavored error.
    func testMalformedChatBodyOnResponsesModelIs400() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","messages":"not-an-array"}"#.utf8)
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: body, route: .chat)) { error in
            XCTAssertEqual((error as? OpencodeRouterError)?.httpStatus, 400)
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// messages/gemini/mistral-native models have no client-facing surface
    /// at all — 422 before any account work.
    func testUnservableNativeSurfacesGet422() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        for (model, surface) in [
            ("anthropic-free-x", OpencodeSurface.messages),
            ("gemini-free-x", OpencodeSurface.gemini),
        ] {
            let body = Data(#"{"model":"opencode/\#(model)","messages":[]}"#.utf8)
            await XCTAssertThrowsErrorAsync(try await router.open(requestBody: body, route: .chat)) { error in
                XCTAssertEqual(
                    error as? OpencodeRouterError,
                    .unsupportedSurface(model: model, surface: surface))
            }
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// Responses server-side conversation state cannot cross to the
    /// stateless chat surface — 400 with a clear message (ADR 0021), never
    /// a silent drop of the whole conversation.
    func testStatefulResponsesRequestIsRejected400() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = Data(#"{"model":"opencode/big-pickle","previous_response_id":"resp_123","input":"hi"}"#.utf8)
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: body, route: .responses)) { error in
            let routerError = error as? OpencodeRouterError
            XCTAssertEqual(routerError?.httpStatus, 400)
            XCTAssertTrue(routerError?.errorDescription?.contains("previous_response_id") ?? false)
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// A malformed Responses body surfaces as 400 (the reused translator's
    /// diagnostics), not an upstream-flavored 502.
    func testMalformedResponsesBodyIs400() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = Data(#"{"model":"opencode/big-pickle","input":42}"#.utf8)
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: body, route: .responses)) { error in
            XCTAssertEqual((error as? OpencodeRouterError)?.httpStatus, 400)
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// The zen/responses upstream enforces `max_output_tokens >= 16` —
    /// ZCode's connectivity probe sends a 1-token cap and upstream 400'd
    /// with "The number must be `>= 16`" (verified live). Sub-minimum caps
    /// are floored at 16 when the TARGET surface is responses, on both the
    /// translated (2b) and passthrough arms.
    func testSubMinimumOutputCapFlooredTo16OnResponsesTarget() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()

        // Translated arm: chat client × responses-native model.
        let chatBody = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":1}"#.utf8)
        _ = try await router.open(requestBody: chatBody, route: .chat)
        var calls = await upstream.calls
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.first).body) as? [String: Any])
        XCTAssertEqual(json["max_output_tokens"] as? Int, 16)

        // Passthrough arm: responses client × responses-native model.
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let responsesBody = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi","max_output_tokens":1}"#.utf8)
        _ = try await router.open(requestBody: responsesBody, route: .responses)
        calls = await upstream.calls
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual(json["max_output_tokens"] as? Int, 16)
    }

    /// The floor only raises: caps at or above 16 pass untouched, and the
    /// chat upstream accepts 1 — no floor when the target is chat.
    func testOutputCapAboveFloorAndChatTargetUntouched() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()

        let capped = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi","max_output_tokens":100}"#.utf8)
        _ = try await router.open(requestBody: capped, route: .responses)
        var calls = await upstream.calls
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual(json["max_output_tokens"] as? Int, 100)

        // Chat target (passthrough): the 1-token cap survives — the chat
        // upstream accepts it (verified live: mimo probe passed with 1).
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let one = Data(#"{"model":"opencode/big-pickle","messages":[{"role":"user","content":"hi"}],"max_completion_tokens":1}"#.utf8)
        _ = try await router.open(requestBody: one, route: .chat)
        calls = await upstream.calls
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 1)
        XCTAssertNil(json["max_output_tokens"])
    }

    /// muse-spark is an always-reasoning model: the zen responses upstream
    /// rejects `reasoning.effort "none"` (supported: minimal…max — verified
    /// live). ZCode's probe sends `none` (thinking disabled); clamp it to
    /// `minimal`, the closest representable intent, on both arms.
    func testReasoningEffortNoneClampedToMinimalOnResponsesTarget() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()

        // Translated arm: chat client's reasoning_effort → reasoning.effort.
        let chatBody = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"none"}"#.utf8)
        _ = try await router.open(requestBody: chatBody, route: .chat)
        var calls = await upstream.calls
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")

        // Passthrough arm: responses client's reasoning.effort verbatim.
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let responsesBody = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi","reasoning":{"effort":"none"}}"#.utf8)
        _ = try await router.open(requestBody: responsesBody, route: .responses)
        calls = await upstream.calls
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "minimal")

        // Only "none" is clamped — representable efforts and absent
        // reasoning pass untouched.
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let high = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi","reasoning":{"effort":"high"}}"#.utf8)
        _ = try await router.open(requestBody: high, route: .responses)
        calls = await upstream.calls
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")

        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let absent = Data(#"{"model":"opencode/muse-spark-1.3-contributor-free","input":"hi"}"#.utf8)
        _ = try await router.open(requestBody: absent, route: .responses)
        calls = await upstream.calls
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(calls.last).body) as? [String: Any])
        XCTAssertNil(json["reasoning"])
    }

    /// Non-streaming chat clients get `stream_options.include_usage`
    /// injected — the aggregator needs the usage chunk (issue #19 rule).
    /// Streaming chat clients are left alone (spec default: no usage chunk).
    func testIncludeUsageInjectedOnlyWhenNeeded() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()

        // stream:false (and missing stream) → inject
        let nonStream = Data(#"{"model":"opencode/big-pickle","messages":[],"stream":false}"#.utf8)
        _ = try await router.open(requestBody: nonStream, route: .chat)
        // stream:true → do not inject
        let stream = Data(#"{"model":"opencode/big-pickle","messages":[],"stream":true}"#.utf8)
        _ = try await router.open(requestBody: stream, route: .chat)

        let calls = await upstream.calls
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[0].body) as? [String: Any])
        XCTAssertEqual((first["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[1].body) as? [String: Any])
        XCTAssertNil(second["stream_options"])
    }

    /// Free-tier gate conformance (ADR 0021 Phase 3): gated tool names with
    /// missing/empty `parameters.properties` get the real opencode schema
    /// substituted; a client tool with real schema and unknown names pass
    /// untouched.
    func testGatedToolSchemasSubstitutedOnlyWhenDegenerate() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "opencode/big-pickle",
            "messages": [],
            "stream": true,
            "tools": [
                // gated, empty properties → substitute
                ["type": "function", "function": ["name": "bash", "parameters": ["type": "object"]]],
                // gated, missing parameters → substitute
                ["type": "function", "function": ["name": "write"]],
                // gated, real schema → untouched
                ["type": "function", "function": [
                    "name": "read",
                    "parameters": ["type": "object", "properties": ["custom": ["type": "string"]]],
                ]],
                // ungated → untouched
                ["type": "function", "function": ["name": "my-tool", "parameters": ["type": "object"]]],
            ],
        ])
        _ = try await router.open(requestBody: body, route: .chat)

        let calls = await upstream.calls
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: calls[0].body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        func tool(_ name: String) -> [String: Any]? {
            tools.first { (($0["function"] as? [String: Any])?["name"] as? String) == name }
        }
        func properties(_ t: [String: Any]) -> [String: Any]? {
            ((t["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any]
        }
        // bash: substituted with the real schema (command required)
        let bash = try XCTUnwrap(tool("bash"))
        let bashProps = try XCTUnwrap(properties(bash))
        XCTAssertNotNil(bashProps["command"])
        XCTAssertEqual(
            (((bash["function"] as? [String: Any])?["parameters"] as? [String: Any])?["required"] as? [String]),
            ["command"])
        // write: substituted (content + filePath required)
        let write = try XCTUnwrap(tool("write"))
        XCTAssertEqual(
            (((write["function"] as? [String: Any])?["parameters"] as? [String: Any])?["required"] as? [String]),
            ["content", "filePath"])
        // read: client's own schema preserved
        let read = try XCTUnwrap(tool("read"))
        XCTAssertEqual(Array((properties(read) ?? [:]).keys), ["custom"])
        // my-tool: untouched (still empty properties — the gate doesn't inspect it)
        let mine = try XCTUnwrap(tool("my-tool"))
        XCTAssertEqual(Array((properties(mine) ?? [:]).keys), [])
        // exactly one read (the client's — no duplicate injection)
        XCTAssertEqual(tools.filter { (($0["function"] as? [String: Any])?["name"] as? String) == "read" }.count, 1)
    }

    /// A pre-surface (v1) persisted snapshot decodes with surface nil and
    /// resolves to `.chat` at lookup — the legacy-default window (ADR 0021).
    func testLegacyV1SnapshotResolvesToChatSurface() async throws {
        // Replace the v2 fixture with a surface-less v1 snapshot.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("catalog-v2.json"))
        let legacy = Data(#"{"fetchedAt":756000000,"models":[{"id":"legacy-model","displayName":"Legacy"}]}"#.utf8)
        try legacy.write(to: tempDir.appendingPathComponent("catalog-v1.json"))
        let catalog2 = OpencodeModelCatalog(
            session: StubURLProtocol.makeSession(), storageDirectory: tempDir)
        await catalog2.loadPersisted()
        XCTAssertEqual(catalog2.surface(for: "legacy-model"), .chat)

        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = OpencodeRouter(
            catalog: catalog2,
            console: OpencodeConsoleClient(session: StubURLProtocol.makeSession()),
            upstream: upstream,
            vault: store,
            metadata: MonitorMetadataStore(url: tempDir.appendingPathComponent("accounts-test.json")),
            detectedSnapshot: { [] })
        let body = Data(#"{"model":"opencode/legacy-model","messages":[],"stream":true}"#.utf8)
        let opened = try await router.open(requestBody: body, route: .chat)
        XCTAssertEqual(opened.plan, .passthrough(native: .chat))
        let calls = await upstream.calls
        XCTAssertEqual(calls.first?.url, "https://opencode.ai/inference/v1/chat/completions")
    }

    func testExpiredVaultCredentialRefreshedBeforeSend() async throws {
        await seedVaultAccount(accessToken: "old-at", refreshToken: "old-rt",
                             expiresAt: Date().addingTimeInterval(-10))
                StubURLProtocol.handler = { _ in
            StubURLProtocol.json(["access_token": "new-at", "refresh_token": "new-rt", "expires_in": 3600])
        }
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer new-at")
        // refresh request hit the console token endpoint with the refresh grant
        let refreshCall = StubURLProtocol.requests.first {
            $0.url.absoluteString.contains("/auth/device/token")
        }
        XCTAssertNotNil(refreshCall)
        let refreshBody = String(data: refreshCall!.body, encoding: .utf8) ?? ""
        XCTAssertTrue(refreshBody.contains("refresh_token"))
        // rotated tokens persisted back to the vault
        let saved = await store.stored((await store.accounts()).first!.id)
        XCTAssertEqual(saved?.accessToken, "new-at")
    }

    func testDetectedExpiredCredentialRereadsStoreAndNeverRefreshes() async throws {
        // auth.json now holds a FRESH credential (user re-authed in opencode)
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"fresh-at","refresh":"fresh-rt","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "stale-at", refreshToken: "stale-rt",
            expiresAt: Date().addingTimeInterval(-10), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter { [expiredDetected] }
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer fresh-at")
        // NEVER a refresh grant for a detected credential
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testDetectedStillExpiredMarksStaleAndRotates() async throws {
        // file still holds the expired credential — nothing new to load
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"still-stale","refresh":"x","expires":1000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await seedVaultAccount(key: "usr_vault", accessToken: "vault-at")
                let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "old", refreshToken: "old",
            expiresAt: Date(timeIntervalSince1970: 1000), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))

        let stale = expectation(description: "stale notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter { [expiredDetected] }
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [stale], timeout: 5)

        // the vault account served the request
        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer vault-at")
    }

    func testUpstreamErrorStatusPassedThrough() async throws {
        await seedVaultAccount()
                await upstream.seed(.success(cannedStream(status: 400, body: #"{"error":"bad"}"#)))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 400)
        let box = DataBox()
        try await opened.pump { @Sendable chunk in box.append(chunk); return true }
        XCTAssertEqual(String(data: box.data, encoding: .utf8), #"{"error":"bad"}"#)
    }

    func test401RotatesToNextAccount() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
                await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)
        let rotatedCalls = await upstream.calls
        XCTAssertEqual(rotatedCalls.count, 2)
        let second = rotatedCalls[1]
        let headers = Dictionary(uniqueKeysWithValues: second.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-b")
    }

    func test429CooldownsAccount() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
                await upstream.seed(.success(cannedStream(status: 429, body: "limited")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)
        // second request: cooled-down account A must be skipped entirely
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        let cooledCalls = await upstream.calls
        XCTAssertEqual(cooledCalls.count, 3)
        let third = cooledCalls[2]
        let headers = Dictionary(uniqueKeysWithValues: third.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-b")
    }

    /// A 429 cooldown notifies the UI so the account can be shown as
    /// rate-limited (Quota tab connection-status card).
    func test429PostsRateLimitedNotification() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
        await upstream.seed(.success(cannedStream(status: 429, body: "limited")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))

        let limited = expectation(description: "rate-limited notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountRateLimited, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_a" { limited.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [limited], timeout: 5)
    }

    func testRecoveredClearsStale() async throws {
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"still-stale","refresh":"x","expires":1000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await seedVaultAccount(key: "usr_vault", accessToken: "vault-at")
                let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "old", refreshToken: "old",
            expiresAt: Date(timeIntervalSince1970: 1000), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)

        let stale = expectation(description: "stale")
        let recovered = expectation(description: "recovered")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        let observer2 = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountRecovered, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { recovered.fulfill() }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer2)
        }

        let router = makeRouter { [expiredDetected] }
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [stale], timeout: 5)

        // user re-authed in opencode: the store now carries a fresh token
        try #"{"opencode":{"type":"oauth","access":"fresh-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [recovered], timeout: 5)
    }

    // MARK: - Final review fixes

    /// Free-tier gate (Task 0 spike): `stream:true` is required and the
    /// tools array must contain a `read` tool — the released client always
    /// sends both. A bare `{"model","messages"}` request must be shaped, not
    /// forwarded verbatim.
    func testInjectsReadToolAndStreamTrue() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(calls.first).body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains {
            (($0["function"] as? [String: Any])?["name"] as? String) == "read"
        }, "expected an injected OpenAI-function-shape `read` tool")
    }

    /// A client that already sends a `read` tool is not touched; sibling
    /// client tools survive alongside.
    func testPreservesExistingReadToolAndClientTools() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let body = Data(#"{"model":"opencode/big-pickle","messages":[],"tools":[{"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"custom":{"type":"string"}},"required":["custom"]}}},{"type":"function","function":{"name":"bash","parameters":{"type":"object"}}}]}"#.utf8)
        let router = makeRouter()
        _ = try await router.open(requestBody: body, route: .chat)

        let calls = await upstream.calls
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(calls.first).body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == "read" }.count, 1, "read tool must not be duplicated")
        XCTAssertTrue(names.contains("bash"))
        // the client's own read def is preserved, not replaced
        let readTool = tools.first {
            (($0["function"] as? [String: Any])?["name"] as? String) == "read"
        }
        let params = (readTool?["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertNotNil((params?["properties"] as? [String: Any])?["custom"])
    }

    /// A detected account the user disabled in the monitor UI must not
    /// serve — the disabled set applies to detected candidates too.
    func testDisabledDetectedAccountIsSkipped() async throws {
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "det-at", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: "/tmp/x#opencode", email: nil)
        let metadata = MonitorMetadataStore(url: tempDir.appendingPathComponent("accounts-test.json"))
        let detectedAccountID = MonitorAccount.make(
            provider: .opencode, accountKey: detected.accountKey,
            source: .nativeCredential, credentialReference: detected.sourcePath).id
        try await metadata.setDisabled(true, accountID: detectedAccountID)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = OpencodeRouter(
            catalog: catalog,
            console: OpencodeConsoleClient(session: StubURLProtocol.makeSession()),
            upstream: upstream,
            vault: store,
            metadata: metadata,
            detectedSnapshot: { [detected] }
        )
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty, "disabled detected account must not reach upstream")
    }

    /// Spec: a detected credential that 401s is re-read from its store —
    /// a rotated token retries once upstream.
    func testDetected401ReloadsStoreAndRetries() async throws {
        // store carries the ROTATED token (user re-authed in opencode)
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"rotated-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        // snapshot still holds the old (revoked-but-unexpired) token
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "revoked-at", refreshToken: "old",
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter { [detected] }
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)

        let calls = await upstream.calls
        XCTAssertEqual(calls.count, 2)
        let second = calls[1]
        let headers = Dictionary(uniqueKeysWithValues: second.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer rotated-at")
    }

    /// A detected credential that 401s AND whose store still holds the
    /// same token is revoked for real — stale-mark it. (Vault candidates
    /// are enumerated before detected, so the vault's own 401 is consumed
    /// first; both failing → exhaustion, not a served stream.)
    func testDetected401SameTokenMarksStale() async throws {
        let authPath = tempDir.appendingPathComponent("auth.json").path
        // store still holds the same revoked token
        try #"{"opencode":{"type":"oauth","access":"revoked-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "revoked-at", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))

        let stale = expectation(description: "stale notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter { [detected] }
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
        await fulfillment(of: [stale], timeout: 5)
        // exactly one upstream attempt — no doomed retry with the same token
        let calls = await upstream.calls
        XCTAssertEqual(calls.count, 1)
    }
}

/// XCTAssertThrowsError doesn't compose with async; small local helper.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
