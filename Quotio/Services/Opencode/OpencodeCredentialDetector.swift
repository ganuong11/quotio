//
//  OpencodeCredentialDetector.swift
//  Quotio
//
//  Read-only discovery of credentials already present in a system opencode
//  installation. Never writes to the opencode data directory: SQLite stores
//  are copied (db + wal + shm) to a temp directory before being opened.
//

import Foundation
import SQLite3

nonisolated struct DetectedOpencodeCredential: Sendable, Equatable {
    /// canonical dedup key: console userID → email → fingerprint(sourcePath + server)
    let accountKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let orgID: String?
    let server: String
    /// credentialReference, e.g. "~/.local/share/opencode/opencode.db#<row id>"
    let sourcePath: String
    let email: String?
}

nonisolated enum OpencodeCredentialDetector {

    /// opencode honors XDG_DATA_HOME; default is ~/.local/share/opencode.
    static var dataDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]?.nilIfBlank {
            return URL(fileURLWithPath: xdg).appendingPathComponent("opencode", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    static func discover() -> [DetectedOpencodeCredential] {
        discover(in: dataDirectory)
    }

    /// Re-read a single entry from its source store. Used when a detected
    /// credential expires: detected credentials are never refreshed with a
    /// refresh grant; they are re-read from disk (the user re-auths in
    /// opencode itself, which rewrites the store).
    static func reload(sourcePath: String) -> DetectedOpencodeCredential? {
        guard let split = splitSource(sourcePath) else { return nil }
        let directory = URL(fileURLWithPath: split.path).deletingLastPathComponent()
        let file = URL(fileURLWithPath: split.path).lastPathComponent
        if file == "auth.json" {
            return discoverAuthJSON(in: directory).first { entryID(from: $0.sourcePath) == split.entry }
        }
        return discoverSQLite(dbPath: split.path).first { entryID(from: $0.sourcePath) == split.entry }
    }

    // MARK: - discovery

    static func discover(in directory: URL) -> [DetectedOpencodeCredential] {
        var byKey: [String: DetectedOpencodeCredential] = [:]
        // SQLite first: it wins over auth.json for the same accountKey.
        for dbPath in sqlitePaths(in: directory) {
            for credential in discoverSQLite(dbPath: dbPath) {
                byKey[credential.accountKey] = credential
            }
        }
        for credential in discoverAuthJSON(in: directory) where byKey[credential.accountKey] == nil {
            byKey[credential.accountKey] = credential
        }
        return Array(byKey.values).sorted { $0.sourcePath < $1.sourcePath }
    }

    // MARK: - auth.json

    /// auth.json is a JSON object. On live installs it is keyed by provider id
    /// (`"opencode"`, `"xai"`, `"openai"`, …); older builds used the console
    /// URL as the key (`"https://opencode.ai/console"`). Both are accepted;
    /// non-opencode providers are skipped.
    private static func discoverAuthJSON(in directory: URL) -> [DetectedOpencodeCredential] {
        let path = directory.appendingPathComponent("auth.json").path
        guard let json = MonitorIdentity.json(at: path) else { return [] }
        var results: [DetectedOpencodeCredential] = []
        for (key, value) in json {
            guard isOpencodeKey(key), let entry = value as? [String: Any] else { continue }
            let source = path + "#" + key
            let server = isConsoleURL(key) ? key : OpencodeConsoleClient.defaultServer
            let type = entry["type"] as? String
            let accessToken = (entry["access"] as? String) ?? (entry["key"] as? String)
            guard type == "oauth" || type == "api",
                  let accessToken = accessToken?.nilIfBlank else { continue }
            let expiresMs = number(entry["expires"])
            let accountID = (entry["accountId"] as? String)?.nilIfBlank
            results.append(DetectedOpencodeCredential(
                accountKey: canonicalKey(accountID: accountID, email: nil, source: source, server: server),
                accessToken: accessToken,
                refreshToken: (entry["refresh"] as? String)?.nilIfBlank,
                expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                orgID: nil,
                server: server,
                sourcePath: source,
                email: nil
            ))
        }
        return results
    }

    private static func isOpencodeKey(_ key: String) -> Bool {
        key.hasPrefix("opencode") || isConsoleURL(key)
    }

    private static func isConsoleURL(_ key: String) -> Bool {
        key.contains("opencode.ai")
    }

    // MARK: - SQLite

    private static func sqlitePaths(in directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .map { directory.appendingPathComponent($0).path }
            .sorted()
    }

    /// Copy db + wal + shm to a temp dir and open the copy — sees committed
    /// WAL state without ever writing into the real store.
    private static func discoverSQLite(dbPath: String) -> [DetectedOpencodeCredential] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let base = URL(fileURLWithPath: dbPath).lastPathComponent
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let src = dbPath + suffix
                guard FileManager.default.fileExists(atPath: src) else { continue }
                try FileManager.default.copyItem(
                    at: URL(fileURLWithPath: src),
                    to: temp.appendingPathComponent(base + suffix))
            }
        } catch { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(
            temp.appendingPathComponent(base).path, &db,
            SQLITE_OPEN_READONLY, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT id, value FROM credential WHERE integration_id = 'opencode'",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [DetectedOpencodeCredential] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let raw = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let source = dbPath + "#" + rowID
            guard let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credential = parseSQLiteValue(value, source: source) else { continue }
            results.append(credential)
        }
        return results
    }

    /// value column: {"type":"oauth","access","refresh","expires":<ms>,
    ///   "metadata":{"accountID","email","orgID","orgName","server"}}
    /// `{"type":"api","key"}` rows are tolerated as non-expiring credentials.
    private static func parseSQLiteValue(_ value: [String: Any], source: String) -> DetectedOpencodeCredential? {
        let metadata = value["metadata"] as? [String: Any] ?? [:]
        let type = value["type"] as? String
        let accessToken = (value["access"] as? String) ?? (value["key"] as? String)
        guard type == "oauth" || type == "api",
              let accessToken = accessToken?.nilIfBlank else { return nil }
        let accountID = (metadata["accountID"] as? String)?.nilIfBlank
        let email = (metadata["email"] as? String)?.nilIfBlank
        let server = (metadata["server"] as? String)?.nilIfBlank ?? OpencodeConsoleClient.defaultServer
        let expiresMs = number(value["expires"])
        return DetectedOpencodeCredential(
            accountKey: canonicalKey(accountID: accountID, email: email, source: source, server: server),
            accessToken: accessToken,
            refreshToken: (value["refresh"] as? String)?.nilIfBlank,
            expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
            orgID: (metadata["orgID"] as? String)?.nilIfBlank,
            server: server,
            sourcePath: source,
            email: email
        )
    }

    // MARK: - helpers

    private static func canonicalKey(accountID: String?, email: String?, source: String, server: String) -> String {
        if let accountID { return accountID }
        if let email { return email }
        return MonitorIdentity.fingerprint(source + "|" + server)
    }

    private static func splitSource(_ sourcePath: String) -> (path: String, entry: String)? {
        guard let index = sourcePath.lastIndex(of: "#") else { return nil }
        return (String(sourcePath[..<index]), String(sourcePath[sourcePath.index(after: index)...]))
    }

    private static func entryID(from sourcePath: String) -> String {
        splitSource(sourcePath)?.entry ?? sourcePath
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
