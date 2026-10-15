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

    private static func modelsDev(_ models: [String: Any]) -> Any {
        ["opencode": ["models": models]]
    }

    private static func mdevEntry(
        input: Double? = 0, output: Double? = 0,
        status: String = "active", name: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = ["status": status]
        if let name { entry["name"] = name }
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
        XCTAssertEqual(catalog.models, [OpencodeFreeModel(id: "a", displayName: "Model A")])
        XCTAssertTrue(catalog.isFree("a"))
        XCTAssertFalse(catalog.isFree("b"))
        XCTAssertFalse(catalog.isEmpty)
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
}
