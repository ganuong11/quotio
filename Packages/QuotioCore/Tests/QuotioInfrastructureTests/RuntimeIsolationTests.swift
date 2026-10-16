import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class RuntimeIsolationTests: XCTestCase {
    func testBetaConfigurationAndVersionOperationsLeaveProductionFilesUntouched() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = IsolatedHomeFileManager(home: home)
        let stablePaths = FileProxyConfigurationRepository.defaultPaths(fileManager: files)
        let beta = RuntimeIdentity(bundleIdentifier: "app.bytrong.quotio.beta")
        let betaPaths = FileProxyConfigurationRepository.defaultPaths(identity: beta, fileManager: files)
        let stable = FileProxyConfigurationRepository(paths: stablePaths)
        let prerelease = FileProxyConfigurationRepository(paths: betaPaths)
        await stable.ensureExists(managementKey: "stable-key")
        let original = try Data(contentsOf: URL(fileURLWithPath: stablePaths.configPath))
        let auth = URL(fileURLWithPath: stablePaths.authDirectoryPath).appendingPathComponent("codex.json")
        try Data("production-account".utf8).write(to: auth)
        await prerelease.ensureExists(managementKey: "beta-key")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stablePaths.configPath)), original)
        XCTAssertEqual(try String(contentsOf: auth, encoding: .utf8), "production-account")
        let config = try String(contentsOf: URL(fileURLWithPath: betaPaths.configPath), encoding: .utf8)
        XCTAssertTrue(config.contains("port: 18318"))
        XCTAssertTrue(config.contains(#"host: "127.0.0.1""#))
        XCTAssertTrue(config.contains("auth-dir: \"\(betaPaths.authDirectoryPath)\""))
        XCTAssertNotEqual(stablePaths.authDirectoryPath, betaPaths.authDirectoryPath)
        XCTAssertEqual(betaPaths.authDirectoryPath, home.appendingPathComponent("Library/Application Support/app.bytrong.quotio.beta/auth").path)

        let stableVersions = FileProxyVersionRepository(fileManager: IsolatedHomeFileManager(home: home))
        let betaVersions = FileProxyVersionRepository(fileManager: IsolatedHomeFileManager(home: home), identity: beta)
        for (paths, version) in [(stablePaths, "1.0.0"), (betaPaths, "2.0.0")] {
            let directory = URL(fileURLWithPath: paths.expectedBinaryPath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("v\(version)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: directory.appendingPathComponent("CLIProxyAPI"))
        }
        try await stableVersions.activate(version: "1.0.0")
        try await betaVersions.activate(version: "2.0.0")
        let stableSnapshot = await stableVersions.snapshot()
        let betaSnapshot = await betaVersions.snapshot()
        XCTAssertEqual(stableSnapshot.currentVersion, "1.0.0")
        XCTAssertEqual(betaSnapshot.currentVersion, "2.0.0")
        XCTAssertEqual(betaSnapshot.expectedBinaryPath, betaPaths.expectedBinaryPath)
        XCTAssertEqual(stableSnapshot.expectedBinaryPath, stablePaths.expectedBinaryPath)
        let stableBinaryPath = try XCTUnwrap(stableSnapshot.currentBinaryPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stableBinaryPath)), Data("1.0.0".utf8))
    }

    func testNonproductionPortDefaultsPreserveExplicitUserPort() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for identifier in ["app.bytrong.quotio.beta", "app.bytrong.quotio.dev"] {
            defaults.removeObject(forKey: "proxyPort")
            let metadata = UserDefaultsProxyRuntimeMetadataRepository(
                defaults: defaults, identity: RuntimeIdentity(bundleIdentifier: identifier)
            )
            XCTAssertEqual(metadata.loadPort(), 8318)
            defaults.set(65_536, forKey: "proxyPort")
            XCTAssertEqual(metadata.loadPort(), 8318)
            metadata.savePort(9321)
            XCTAssertEqual(metadata.loadPort(), 9321)
        }
    }

    @MainActor
    func testManualDownloadPolicyNeverInitializesSparkleOrChecksOtherChannels() {
        let updater = SparkleApplicationUpdateAdapter(policy: .manualDownload)
        updater.automaticallyChecksForUpdates = true
        updater.setAllowsPrereleaseUpdates(true)
        updater.initializeIfNeeded()
        updater.checkForUpdates()
        updater.checkForUpdatesInBackground()
        updater.resetUpdateCycle()
        XCTAssertFalse(updater.isInitialized)
        XCTAssertFalse(updater.isChecking)
        XCTAssertFalse(updater.canCheck)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertNil(updater.lastCheckDate)
    }

    func testOwnedOnlyProxyStopAndCleanupLeaveUnownedListenerRunning() async throws {
        let controller = ProxyProcessController(allowsPortCleanup: false)
        let port = try await controller.firstAvailablePort(in: 20_000...21_000, excluding: [])
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "127.0.0.1", String(port)]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer {
            if listener.isRunning { listener.terminate() }
            listener.waitUntilExit()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(listener.isRunning)
        await controller.cleanupProcesses(on: port)
        await controller.stop(nil, on: port)
        XCTAssertTrue(listener.isRunning)

        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("CLIProxyAPI")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let request = ProxyProcessRequest(executablePath: executable.path, configurationPath: directory.appendingPathComponent("config.yaml").path)
        try await controller.start(request) { _ in }
        let started = await controller.isRunning(request.runID)
        XCTAssertTrue(started)
        await controller.stop(request.runID, on: port)
        let stopped = await controller.isRunning(request.runID)
        XCTAssertFalse(stopped)
        XCTAssertTrue(listener.isRunning)
    }

    func testAntigravityOwnedProfilesAndBackupsDoNotOverwriteProduction() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let beta = RuntimeIdentity(bundleIdentifier: "app.bytrong.quotio.beta")
        let stable = AntigravityDeviceStore(home: home)
        let prerelease = AntigravityDeviceStore(identity: beta, home: home)
        let stableProfile = await stable.loadOrCreate(email: "person@example.com")
        let betaProfile = await prerelease.loadOrCreate(email: "person@example.com")
        let stableReloaded = await stable.loadOrCreate(email: "person@example.com")
        let betaReloaded = await prerelease.loadOrCreate(email: "person@example.com")
        XCTAssertEqual(stableProfile, stableReloaded)
        XCTAssertEqual(betaProfile, betaReloaded)
        XCTAssertNotEqual(stableProfile.deviceID, betaProfile.deviceID)

        let database = home.appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("global-ide-database".utf8).write(to: database)
        let stableBackup = database.appendingPathExtension("quotio.backup")
        try Data("production-backup".utf8).write(to: stableBackup)
        let betaDatabase = AntigravitySwitchDatabase(identity: beta, home: home)
        try await betaDatabase.createBackup()
        XCTAssertEqual(try String(contentsOf: stableBackup, encoding: .utf8), "production-backup")
        let betaBackup = home.appendingPathComponent("Library/Application Support/app.bytrong.quotio.beta/Antigravity/state.vscdb.backup")
        XCTAssertEqual(try Data(contentsOf: betaBackup), try Data(contentsOf: database))
        await betaDatabase.removeBackup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableBackup.path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class IsolatedHomeFileManager: FileManager, @unchecked Sendable {
    private let home: URL
    init(home: URL) { self.home = home; super.init() }
    override var homeDirectoryForCurrentUser: URL { home }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [home.appendingPathComponent("Library/Application Support")]
    }
}
