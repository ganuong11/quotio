import Foundation
import QuotioApplication
import QuotioDomain

public actor FileProxyConfigurationRepository: ProxyConfigurationRepository {
    private let fileManager: FileManager
    private let resolvedPaths: ProxyPaths

    public init(
        paths: ProxyPaths = FileProxyConfigurationRepository.defaultPaths(),
        fileManager: FileManager = .default
    ) {
        self.resolvedPaths = paths
        self.fileManager = fileManager
    }

    public static func defaultPaths(
        identity: RuntimeIdentity = .production,
        fileManager: FileManager = .default
    ) -> ProxyPaths {
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let quotioDirectory = identity.applicationSupportDirectory(in: appSupport)
        let proxyDirectory = quotioDirectory.appendingPathComponent("proxy/upstream/current")
        return ProxyPaths(
            legacyBinaryPath: quotioDirectory.appendingPathComponent("CLIProxyAPI").path,
            configPath: quotioDirectory.appendingPathComponent("config.yaml").path,
            authDirectoryPath: identity.proxyAuthDirectory(
                home: fileManager.homeDirectoryForCurrentUser, applicationSupport: appSupport
            ).path,
            expectedBinaryPath: proxyDirectory.appendingPathComponent("CLIProxyAPI").path,
            internalProxyPort: identity.internalProxyPort
        )
    }

    public func paths() -> ProxyPaths {
        resolvedPaths
    }

    public func ensureExists(managementKey: String) {
        let configURL = URL(fileURLWithPath: resolvedPaths.configPath)
        try? fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            atPath: resolvedPaths.authDirectoryPath,
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: resolvedPaths.configPath) {
            migrateManagedKeys()
            return
        }

        let configuration = """
        host: "127.0.0.1"
        port: \(resolvedPaths.internalProxyPort)
        auth-dir: "\(resolvedPaths.authDirectoryPath)"
        proxy-url: ""

        api-keys:
          - "quotio-local-\(UUID().uuidString)"

        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"

        debug: false
        logging-to-file: false
        usage-statistics-enabled: true

        routing:
          strategy: "round-robin"

        quota-exceeded:
          switch-project: true
          switch-preview-model: true

        request-retry: 3
        max-retry-interval: 30
        """
        try? configuration.write(
            toFile: resolvedPaths.configPath,
            atomically: true,
            encoding: .utf8
        )
    }

    private func migrateManagedKeys() {
        guard var content = try? String(
            contentsOfFile: resolvedPaths.configPath,
            encoding: .utf8
        ) else {
            return
        }
        let managedHost = #"host: "127.0.0.1""#
        let managedPort = "port: \(resolvedPaths.internalProxyPort)"
        var sawHost = false
        var sawPort = false
        var lines = content.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            if line.range(of: #"^host:\s*"#, options: .regularExpression) != nil {
                lines[index] = managedHost
                sawHost = true
            } else if line.range(of: #"^port:\s*\d+"#, options: .regularExpression) != nil {
                lines[index] = managedPort
                sawPort = true
            }
        }
        var missing: [String] = []
        if !sawHost { missing.append(managedHost) }
        if !sawPort { missing.append(managedPort) }
        if !missing.isEmpty {
            lines.insert(contentsOf: missing, at: 0)
        }
        let migrated = lines.joined(separator: "\n")
        guard migrated != content else { return }
        content = migrated
        write(content)
    }

    public func ensureAPIKey() {
        guard let content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        var lines = content.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "api-keys:"
        }) {
            var scanIndex = index + 1
            while scanIndex < lines.count {
                let line = lines[scanIndex]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                if trimmed.hasPrefix("-") {
                    if !trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return
                    }
                    scanIndex += 1
                    continue
                }
                if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
                scanIndex += 1
            }
            lines.insert("  - \"quotio-local-\(UUID().uuidString)\"", at: index + 1)
        } else {
            lines.append(contentsOf: [
                "",
                "api-keys:",
                "  - \"quotio-local-\(UUID().uuidString)\"",
                "",
            ])
        }
        write(lines.joined(separator: "\n"))
    }

    /// Read the configured `api-keys` list for gateway-side request
    /// authentication. Returns an empty list when the file or section is
    /// absent — callers treat that as "keys unconfigured" (open access),
    /// matching upstream semantics.
    public func loadAPIKeys() -> [String] {
        guard let content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return []
        }
        let lines = content.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "api-keys:"
        }) else { return [] }
        var keys: [String] = []
        var scanIndex = index + 1
        while scanIndex < lines.count {
            let line = lines[scanIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                scanIndex += 1
                continue
            }
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            if trimmed.hasPrefix("-") {
                let value = trimmed.dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { keys.append(value) }
            }
            scanIndex += 1
        }
        return keys
    }

    public func setAllowRemote(_ enabled: Bool) {
        updateValue(
            pattern: #"allow-remote:\s*(true|false)"#,
            replacement: "allow-remote: \(enabled)"
        )
    }

    public func setLogging(_ enabled: Bool) {
        updateValue(
            pattern: #"logging-to-file:\s*(true|false)"#,
            replacement: "logging-to-file: \(enabled)"
        )
    }

    public func setRoutingStrategy(_ strategy: String) {
        updateValue(
            pattern: #"strategy:\s*"[^"]*""#,
            replacement: "strategy: \"\(strategy)\""
        )
    }

    public func setProxyURL(_ url: String?) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        let value = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let range = content.range(of: #"proxy-url:\s*\"[^\"]*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "proxy-url: \"\(value)\"")
        } else if let range = content.range(of: #"proxy-url:\s*[^\n]*"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "proxy-url: \"\(value)\"")
        } else if let range = content.range(of: #"port:\s*\d+\n"#, options: .regularExpression) {
            content.insert(contentsOf: "proxy-url: \"\(value)\"\n", at: range.upperBound)
        } else {
            return
        }
        write(content)
    }

    public func setManagementKey(_ key: String) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8) else {
            return
        }
        if let range = content.range(of: #"secret-key:\s*\".*\""#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(key)\"")
        } else if let range = content.range(of: #"secret-key:\s*[^\n]+"#, options: .regularExpression) {
            content.replaceSubrange(range, with: "secret-key: \"\(key)\"")
        } else {
            return
        }
        write(content)
    }

    public func makeTestConfiguration(port: UInt16, managementKey: String) throws -> String {
        let path = fileManager.temporaryDirectory
            .appendingPathComponent("quotio-test-config-\(port).yaml").path
        let configuration = """
        host: "127.0.0.1"
        port: \(port)
        auth-dir: "\(resolvedPaths.authDirectoryPath)"

        api-keys:
          - "quotio-test-\(UUID().uuidString.prefix(8))"

        remote-management:
          allow-remote: false
          secret-key: "\(managementKey)"

        debug: false
        logging-to-file: false
        usage-statistics-enabled: false

        routing:
          strategy: "round-robin"
        """
        try configuration.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    public func removeTestConfiguration(at path: String) {
        try? fileManager.removeItem(atPath: path)
    }

    private func updateValue(pattern: String, replacement: String) {
        guard var content = try? String(contentsOfFile: resolvedPaths.configPath, encoding: .utf8),
              let range = content.range(of: pattern, options: .regularExpression) else {
            return
        }
        content.replaceSubrange(range, with: replacement)
        write(content)
    }

    private func write(_ content: String) {
        try? content.write(
            toFile: resolvedPaths.configPath,
            atomically: true,
            encoding: .utf8
        )
    }
}
