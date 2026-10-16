import Foundation
import XCTest
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class ProxyConfigurationTests: XCTestCase {
    private let fileManager = FileManager.default

    func testInternalProxyPortMirrorsFrontDoorOffsets() {
        XCTAssertEqual(RuntimeIdentity.production.defaultProxyPort, 8317)
        XCTAssertEqual(RuntimeIdentity.production.internalProxyPort, 18317)
        let beta = RuntimeIdentity(bundleIdentifier: RuntimeIdentity.betaBundleIdentifier)
        XCTAssertEqual(beta.defaultProxyPort, 8318)
        XCTAssertEqual(beta.internalProxyPort, 18318)
    }

    func testFreshConfigurationPinsInternalLoopbackPortAndHost() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.directory) }

        await fixture.repository.ensureExists(managementKey: "key-1")

        let config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains(#"host: "127.0.0.1""#))
        XCTAssertTrue(config.contains("\nport: 18317") || config.hasPrefix("port: 18317"))
        XCTAssertFalse(config.contains("0.0.0.0"))
    }

    func testExistingConfigurationMigratesPortToInternalPort() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.directory) }
        let original = """
        host: "127.0.0.1"
        port: 8317
        user-owned-setting: keep-me
        remote-management:
          secret-key: "old-key"
        """
        try original.write(to: fixture.configURL, atomically: true, encoding: .utf8)

        await fixture.repository.ensureExists(managementKey: "ignored")

        let config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("\nport: 18317") || config.hasPrefix("port: 18317"))
        XCTAssertFalse(config.contains("port: 8317"))
        XCTAssertTrue(config.contains("user-owned-setting: keep-me"))
        XCTAssertTrue(config.contains(#"secret-key: "old-key""#))
    }

    func testExistingConfigurationPinsLANHostToLoopback() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.directory) }
        let original = """
        host: "0.0.0.0"
        port: 9000
        user-owned-setting: keep-me
        """
        try original.write(to: fixture.configURL, atomically: true, encoding: .utf8)

        await fixture.repository.ensureExists(managementKey: "ignored")

        let config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains(#"host: "127.0.0.1""#))
        XCTAssertFalse(config.contains("0.0.0.0"))
        XCTAssertTrue(config.contains("port: 18317"))
        XCTAssertTrue(config.contains("user-owned-setting: keep-me"))
    }

    func testExistingConfigurationGainsManagedKeysWhenMissing() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.directory) }
        try "user-owned-setting: keep-me\n".write(
            to: fixture.configURL,
            atomically: true,
            encoding: .utf8
        )

        await fixture.repository.ensureExists(managementKey: "ignored")

        let config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("port: 18317"))
        XCTAssertTrue(config.contains(#"host: "127.0.0.1""#))
        XCTAssertTrue(config.contains("user-owned-setting: keep-me"))
    }

    func testEnsureAPIKeyLeavesManagedPortAndHostUntouched() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.directory) }

        await fixture.repository.ensureExists(managementKey: "key-1")
        await fixture.repository.ensureAPIKey()

        let config = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains(#"host: "127.0.0.1""#))
        XCTAssertTrue(config.contains("port: 18317"))
    }

    func testManagementEndpointDerivesFromInternalPort() throws {
        let paths = FileProxyConfigurationRepository.defaultPaths(identity: .production)
        let endpoint = try ProxyEndpoint(port: paths.internalProxyPort)
        XCTAssertEqual(endpoint.managementURL, "http://127.0.0.1:18317/v0/management")
        XCTAssertEqual(endpoint.baseURL, "http://127.0.0.1:18317")
    }

    func testNonproductionIdentityPinsShiftedInternalPort() {
        let beta = RuntimeIdentity(bundleIdentifier: RuntimeIdentity.betaBundleIdentifier)
        let paths = FileProxyConfigurationRepository.defaultPaths(identity: beta)
        XCTAssertEqual(paths.internalProxyPort, 18318)
    }

    private struct Fixture {
        let directory: URL
        let configURL: URL
        let repository: FileProxyConfigurationRepository
    }

    private func makeFixture(
        identity: RuntimeIdentity = .production
    ) throws -> Fixture {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = ProxyPaths(
            legacyBinaryPath: directory.appendingPathComponent("legacy").path,
            configPath: directory.appendingPathComponent("config.yaml").path,
            authDirectoryPath: directory.appendingPathComponent("auth").path,
            expectedBinaryPath: directory.appendingPathComponent("current/CLIProxyAPI").path,
            internalProxyPort: identity.internalProxyPort
        )
        return Fixture(
            directory: directory,
            configURL: URL(fileURLWithPath: paths.configPath),
            repository: FileProxyConfigurationRepository(paths: paths)
        )
    }
}
