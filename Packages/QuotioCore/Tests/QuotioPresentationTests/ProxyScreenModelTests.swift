import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class ProxyScreenModelTests: XCTestCase {
    func testMapsSnapshotToDisplayPropertiesAndFailureMessage() {
        var snapshot = makeSnapshot()
        snapshot.managementKey = "management-key"
        snapshot.activeVersion = "1.2.3"
        snapshot.isBinaryInstalled = true
        snapshot.lastError = .binaryNotFound
        snapshot.installedVersions = [
            InstalledProxyVersion(
                version: "1.2.3",
                path: "/tmp/proxy/v1.2.3/CLIProxyAPI",
                installedAt: Date(timeIntervalSince1970: 1),
                isCurrent: true
            ),
        ]
        let model = ProxyScreenModel(
            controller: StubProxyController(snapshot: snapshot),
            initialState: snapshot
        )

        XCTAssertEqual(model.baseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(model.managementURL, "http://127.0.0.1:18317/v0/management")
        XCTAssertEqual(
            model.managementPageURL,
            URL(string: "http://127.0.0.1:18317/management.html")
        )
        XCTAssertEqual(model.effectiveBinaryPath, "/tmp/proxy/v1.2.3/CLIProxyAPI")
        XCTAssertEqual(model.currentVersion, "1.2.3")
        XCTAssertEqual(model.managementKey, "management-key")
        XCTAssertTrue(model.isBinaryInstalled)
        XCTAssertEqual(
            model.lastError,
            "CLIProxyAPI upstream binary is not installed. Open Settings and install a release."
        )
        XCTAssertEqual(
            model.errorMessage(for: ProxyFailure.cannotDeleteCurrentVersion),
            "Cannot delete the currently active version"
        )
    }

    func testStartForwardsIntentAndRefreshesPublishedState() async throws {
        let controller = StubProxyController(snapshot: makeSnapshot())
        let model = ProxyScreenModel(controller: controller, initialState: makeSnapshot())

        try await model.start()

        let actions = await controller.actions()
        XCTAssertTrue(model.proxyStatus.running)
        XCTAssertEqual(model.state.lifecycle, .active)
        XCTAssertEqual(actions, ["start"])
    }

    func testInitializeAndPortChangeForwardToController() async {
        let controller = StubProxyController(snapshot: makeSnapshot())
        let model = ProxyScreenModel(controller: controller, initialState: makeSnapshot())

        await model.initialize()
        model.setPort(9000)
        let updated = await waitUntil { model.port == 9000 }
        let actions = await controller.actions()

        XCTAssertTrue(updated)
        XCTAssertEqual(model.port, 9000)
        XCTAssertEqual(actions, ["initialize", "setPort:9000"])
    }

    func testInitializationStartsOnlyWhenEnabledAndInstalled() async {
        for (enabled, installed, running, shouldStart) in [
            (true, true, false, true),
            (false, true, false, false),
            (true, false, false, false),
            (true, true, true, false)
        ] {
            var snapshot = makeSnapshot()
            snapshot.isBinaryInstalled = installed
            snapshot.status.running = running
            let controller = StubProxyController(snapshot: snapshot)
            let model = ProxyScreenModel(controller: controller, initialState: snapshot)

            await model.initialize(autoStart: enabled)

            let actions = await controller.actions()
            XCTAssertEqual(actions, shouldStart ? ["initialize", "start"] : ["initialize"])
        }
    }

    func testAutoStartFailureRemainsVisible() async {
        var snapshot = makeSnapshot()
        snapshot.isBinaryInstalled = true
        let controller = StubProxyController(snapshot: snapshot, startFailure: .startupFailed)
        let model = ProxyScreenModel(controller: controller, initialState: snapshot)

        await model.initialize(autoStart: true)

        XCTAssertEqual(model.state.lastError, .startupFailed)
        XCTAssertFalse(model.proxyStatus.running)
    }

    private func makeSnapshot() -> ProxySnapshot {
        ProxySnapshot(
            paths: ProxyPaths(
                legacyBinaryPath: "/tmp/legacy/CLIProxyAPI",
                configPath: "/tmp/config.yaml",
                authDirectoryPath: "/tmp/auth",
                expectedBinaryPath: "/tmp/proxy/current/CLIProxyAPI"
            )
        )
    }

    private func waitUntil(
        attempts: Int = 500,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private actor StubProxyController: ProxyControlling {
    private var value: ProxySnapshot
    private var recordedActions: [String] = []

    private let startFailure: ProxyFailure?
    private let catalogResult: Result<[ModelCatalogEntry], Error>

    init(
        snapshot: ProxySnapshot,
        startFailure: ProxyFailure? = nil,
        catalogResult: Result<[ModelCatalogEntry], Error> = .success([])
    ) {
        self.value = snapshot
        self.startFailure = startFailure
        self.catalogResult = catalogResult
    }

    func snapshots() -> AsyncStream<ProxySnapshot> {
        let value = value
        return AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }

    func snapshot() -> ProxySnapshot { value }

    func initialize() {
        recordedActions.append("initialize")
    }

    func start() throws {
        recordedActions.append("start")
        if let startFailure { throw startFailure }
        value.status.running = true
        value.lifecycle = .active
    }

    func stop() {
        recordedActions.append("stop")
        value.status.running = false
        value.lifecycle = .idle
    }

    func stopAndWait() { stop() }
    func restart() throws { recordedActions.append("restart") }
    func shutdown() { recordedActions.append("shutdown") }
    func installLatest() throws { recordedActions.append("installLatest") }
    func checkForUpgrade() { recordedActions.append("checkForUpgrade") }

    func availableVersions(limit: Int) throws -> [ProxyVersionInfo] {
        recordedActions.append("availableVersions:\(limit)")
        return []
    }

    func install(_ version: ProxyVersionInfo) throws {
        recordedActions.append("install:\(version.version)")
    }

    func activate(version: String) throws {
        recordedActions.append("activate:\(version)")
    }

    func delete(version: String) throws {
        recordedActions.append("delete:\(version)")
    }

    func rollback() throws { recordedActions.append("rollback") }

    func versionsToDeleteAfterInstalling(keeping count: Int) -> [String] {
        recordedActions.append("versionsToDelete:\(count)")
        return []
    }

    func setPort(_ port: UInt16) {
        recordedActions.append("setPort:\(port)")
        value.status.port = port
    }

    func setNetworkAccess(_ enabled: Bool) {
        recordedActions.append("setNetworkAccess:\(enabled)")
    }

    func setRemoteAccess(_ enabled: Bool) {
        recordedActions.append("setRemoteAccess:\(enabled)")
    }

    func setLogging(_ enabled: Bool) {
        recordedActions.append("setLogging:\(enabled)")
    }

    func setRoutingStrategy(_ strategy: String) {
        recordedActions.append("setRoutingStrategy:\(strategy)")
    }

    func setProxyURL(_ url: String?) {
        recordedActions.append("setProxyURL:\(url ?? "nil")")
    }

    func regenerateManagementKey() throws {
        recordedActions.append("regenerateManagementKey")
    }

    func clientAPIKeys() -> [String] { [] }

    func availableModels() throws -> [ModelCatalogEntry] {
        recordedActions.append("availableModels")
        return try catalogResult.get()
    }

    func actions() -> [String] { recordedActions }
    func currentPort() -> UInt16 { value.status.port }
}
