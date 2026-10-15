//
//  OpencodeModelCatalogTests.swift
//  QuotioTests
//

import Foundation
import XCTest
@testable import Quotio

final class OpencodeModelCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeCatalog() -> OpencodeModelCatalog {
        OpencodeModelCatalog(session: StubURLProtocol.makeSession(), storageDirectory: tempDir)
    }

    private static func liveModels(_ ids: [String]) -> Any {
        ["object": "list", "data": ids.map { ["id": $0, "object": "model", "owned_by": "opencode"] }]
    }

    private static func modelsDev(_ models: [String: Any], providerNpm: String? = nil) -> Any {
        var provider: [String: Any] = ["models": models]
        if let providerNpm { provider["npm"] = providerNpm }
        return ["opencode": provider]
    }

    private static func mdevEntry(
        input: Double? = 0, output: Double? = 0,
        status: String = "active", name: String? = nil, npm: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = ["status": status]
        if let name { entry["name"] = name }
        if let npm { entry["provider"] = ["npm": npm] }
        if let input, let output {
            entry["cost"] = ["input": input, "output": output]
        }
        return entry
    }

    private func stub(live: Any?, mdev: Any?, status: Int = 200) {
        let liveBody = live.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let mdevBody = mdev.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        StubURLProtocol.handler = { request in
            let body = request.url.absoluteString.contains("models.dev") ? mdevBody : liveBody
            guard let body else { throw URLError(.badServerResponse) }
            return (status, ["Content-Type": "application/json"], body)
        }
    }

    // MARK: - tests

    func testFreeSetIntersection() async {
        stub(
            live: Self.liveModels(["a", "b", "c"]),
            mdev: Self.modelsDev([
                "a": Self.mdevEntry(name: "Model A"),
                "b": Self.mdevEntry(input: 1, output: 5),
                "c": Self.mdevEntry(status: "deprecated"),
            ])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.models, [OpencodeFreeModel(id: "a", displayName: "Model A", surface: .chat)])
        XCTAssertTrue(catalog.isFree("a"))
        XCTAssertFalse(catalog.isFree("b"))
        XCTAssertFalse(catalog.isEmpty)
    }

    // MARK: - Surface capture (ADR 0021)

    /// Precedence: per-model `provider.npm` beats the provider-level `npm`;
    /// no override → provider level; neither → chat.
    func testSurfacePrecedence() async {
        stub(
            live: Self.liveModels(["plain", "sparkie", "anthro", "goog"]),
            mdev: Self.modelsDev([
                "plain": Self.mdevEntry(),                                        // no npm anywhere → chat
                "sparkie": Self.mdevEntry(npm: "@ai-sdk/openai"),                 // per-model → responses
                "anthro": Self.mdevEntry(npm: "@ai-sdk/anthropic"),               // per-model → messages
                "goog": Self.mdevEntry(npm: "@ai-sdk/google"),                    // per-model → gemini
            ], providerNpm: "@ai-sdk/openai-compatible")
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.surface(for: "plain"), .chat)
        XCTAssertEqual(catalog.surface(for: "sparkie"), .responses)
        XCTAssertEqual(catalog.surface(for: "anthro"), .messages)
        XCTAssertEqual(catalog.surface(for: "goog"), .gemini)
    }

    /// The provider-level npm feeds models without their own override —
    /// `@ai-sdk/openai` at provider level would make every plain model
    /// responses-native.
    func testProviderLevelNpmFallback() async {
        stub(
            live: Self.liveModels(["a"]),
            mdev: Self.modelsDev(["a": Self.mdevEntry()], providerNpm: "@ai-sdk/openai")
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.surface(for: "a"), .responses)
    }

    /// Unknown npm values resolve to chat (upstream default behind
    /// openai-compatible).
    func testUnknownNpmResolvesToChat() async {
        stub(
            live: Self.liveModels(["a"]),
            mdev: Self.modelsDev(["a": Self.mdevEntry(npm: "@ai-sdk/some-new-package")])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.surface(for: "a"), .chat)
    }

    /// `/v1/models` advertises only models servable on a client-facing
    /// surface (ADR 0021: never advertise what a request would 422 on).
    func testAdvertisedModelsFiltersUnservableSurfaces() async {
        stub(
            live: Self.liveModels(["chat-m", "resp-m", "msg-m", "gem-m"]),
            mdev: Self.modelsDev([
                "chat-m": Self.mdevEntry(),
                "resp-m": Self.mdevEntry(npm: "@ai-sdk/openai"),
                "msg-m": Self.mdevEntry(npm: "@ai-sdk/anthropic"),
                "gem-m": Self.mdevEntry(npm: "@ai-sdk/google"),
            ])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.advertisedModels.map(\.id), ["chat-m", "resp-m"])
        // The full free set still contains them (the gate stays free-set
        // based; the 422 happens at dispatch).
        XCTAssertEqual(catalog.models.map(\.id), ["chat-m", "gem-m", "msg-m", "resp-m"])
    }

    /// A pre-surface persisted snapshot (v1 file, surface nil) resolves to
    /// `.chat` at lookup — the legacy-default window the startup refresh
    /// closes (ADR 0021).
    func testLegacySnapshotDefaultsToChatSurface() async throws {
        let v1 = Data(#"{"fetchedAt":756000000,"models":[{"id":"legacy","displayName":"Legacy"}]}"#.utf8)
        try v1.write(to: tempDir.appendingPathComponent("catalog-v1.json"))
        let catalog = makeCatalog()
        await catalog.loadPersisted()
        XCTAssertEqual(catalog.models.map(\.id), ["legacy"])
        XCTAssertEqual(catalog.surface(for: "legacy"), .chat)
        // Servable (chat default) → advertised.
        XCTAssertEqual(catalog.advertisedModels.map(\.id), ["legacy"])
    }

    /// The resolved snapshot persists WITH surfaces and reloads with them.
    func testSurfacesPersistAcrossReload() async {
        stub(
            live: Self.liveModels(["sparkie"]),
            mdev: Self.modelsDev(["sparkie": Self.mdevEntry(npm: "@ai-sdk/openai")])
        )
        let first = makeCatalog()
        await first.refresh()
        XCTAssertEqual(first.surface(for: "sparkie"), .responses)

        let second = makeCatalog()   // same storage dir, offline
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await second.loadPersisted()
        XCTAssertEqual(second.surface(for: "sparkie"), .responses)
    }

    func testMissingCostExcluded() async {
        stub(
            live: Self.liveModels(["a", "d"]),
            mdev: Self.modelsDev([
                "a": Self.mdevEntry(),
                "d": Self.mdevEntry(input: nil, output: nil),   // no cost field
            ])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])
    }

    func testAbsentFromModelsDevExcluded() async {
        stub(
            live: Self.liveModels(["a", "e"]),
            mdev: Self.modelsDev(["a": Self.mdevEntry()])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])
        XCTAssertFalse(catalog.isFree("e"))
    }

    /// Task 0 spike: `jev-1.13`/`jev-1.13-free` appear in the live list; these
    /// are internal models that must never pass the gate even if marked free.
    func testJevAndSystemoneExcluded() async {
        stub(
            live: Self.liveModels(["a", "jev-1.13-free", "systemone-alpha"]),
            mdev: Self.modelsDev([
                "a": Self.mdevEntry(),
                "jev-1.13-free": Self.mdevEntry(),
                "systemone-alpha": Self.mdevEntry(),
            ])
        )
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])
    }

    func testRefreshFailureKeepsList() async {
        stub(live: Self.liveModels(["a"]), mdev: Self.modelsDev(["a": Self.mdevEntry()]))
        let catalog = makeCatalog()
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])

        stub(live: nil, mdev: nil)   // both endpoints now fail
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])

        StubURLProtocol.handler = { _ in (500, [:], Data()) }
        await catalog.refresh()
        XCTAssertEqual(catalog.models.map(\.id), ["a"])
    }

    func testPersistedSnapshotLoadsOffline() async {
        stub(live: Self.liveModels(["a", "b"]), mdev: Self.modelsDev([
            "a": Self.mdevEntry(),
            "b": Self.mdevEntry(),
        ]))
        let first = makeCatalog()
        await first.refresh()
        XCTAssertEqual(first.models.map(\.id), ["a", "b"])

        let second = makeCatalog()          // same storage dir, no network stubs left
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await second.loadPersisted()
        XCTAssertEqual(second.models.map(\.id), ["a", "b"])
        XCTAssertTrue(second.isFree("b"))
    }

    /// A catalog that has never resolved anything reports empty — the route
    /// gate turns this into 503 catalog-unavailable.
    func testColdStartEmpty() {
        let catalog = makeCatalog()
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertFalse(catalog.isFree("a"))
    }

    /// Review fix: `loadPersisted` and `refresh` used to run as two
    /// independent tasks at startup, so a slow persisted load could land on
    /// top of a faster network refresh. `prime()` serializes them inside
    /// the actor — after it returns, the freshest data wins.
    func testPrimeLoadsPersistedThenRefreshes() async {
        // Persist a stale snapshot via a first catalog instance. Both ids
        // must be in models.dev (loadPersisted restores that cache too,
        // within its TTL); only the live list differs between runs.
        let mdev = Self.modelsDev([
            "stale": Self.mdevEntry(),
            "fresh": Self.mdevEntry(),
        ])
        stub(live: Self.liveModels(["stale"]), mdev: mdev)
        let first = makeCatalog()
        await first.refresh()
        XCTAssertEqual(first.models.map(\.id), ["stale"])

        // Fresh catalog, same storage dir: prime() must end at the
        // network result, not the persisted one.
        stub(live: Self.liveModels(["fresh"]), mdev: mdev)
        let second = makeCatalog()
        await second.prime()
        XCTAssertEqual(second.models.map(\.id), ["fresh"])
    }
}
