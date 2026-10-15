//
//  OpencodeCredentialDetectorTests.swift
//  QuotioTests
//

import SQLite3
import XCTest
@testable import Quotio

final class OpencodeCredentialDetectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: tempDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testMissingStoreReturnsEmpty() {
        XCTAssertEqual(OpencodeCredentialDetector.discover(in: tempDir), [])
    }

    /// auth.json is keyed by provider id on live installs ("opencode"); the
    /// legacy host-URL key is tolerated too. `accountId` is camelCase; there
    /// is no email field.
    func testAuthJSONDiscovery() throws {
        try write("auth.json", """
        {
            "opencode": {"type": "oauth", "access": "at-json", "refresh": "rt-json",
                         "expires": 2000000000000, "accountId": "usr_json"},
            "https://opencode.ai/console": {"type": "oauth", "access": "at-host",
                         "refresh": "rt-host", "expires": 2000000000000, "accountId": "usr_host"},
            "openai": {"type": "oauth", "access": "other", "expires": 2000000000000}
        }
        """)
        let found = OpencodeCredentialDetector.discover(in: tempDir)
        XCTAssertEqual(found.count, 2)
        let byKey = Dictionary(uniqueKeysWithValues: found.map { ($0.accountKey, $0) })
        let json = try XCTUnwrap(byKey["usr_json"])
        XCTAssertEqual(json.kind, .oauth)
        XCTAssertEqual(json.accessToken, "at-json")
        XCTAssertEqual(json.refreshToken, "rt-json")
        XCTAssertEqual(json.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(json.server, OpencodeConsoleClient.defaultServer)
        XCTAssertTrue(json.sourcePath.contains("auth.json#opencode"))
        let host = try XCTUnwrap(byKey["usr_host"])
        XCTAssertEqual(host.server, "https://opencode.ai/console")
        // non-opencode entries are ignored
        XCTAssertNil(byKey.values.first { $0.accessToken == "other" })
    }

    /// API-key entries for the opencode provider are usable Bearer credentials
    /// (verified live in the Task 0 spike): no refresh, no expiry.
    func testAuthJSONAPIKeyEntry() throws {
        try write("auth.json", #"{"opencode": {"type": "api", "key": "sk-test"}}"#)
        let found = OpencodeCredentialDetector.discover(in: tempDir)
        XCTAssertEqual(found.count, 1)
        let cred = try XCTUnwrap(found.first)
        XCTAssertEqual(cred.kind, .api)
        XCTAssertEqual(cred.accessToken, "sk-test")
        XCTAssertNil(cred.refreshToken)
        XCTAssertNil(cred.expiresAt)
        // no identity -> deterministic fingerprint key
        XCTAssertEqual(cred.accountKey.count, 20)
        XCTAssertEqual(cred.accountKey, OpencodeCredentialDetector.discover(in: tempDir).first?.accountKey)
    }

    func testSQLiteDiscoveryWAL() throws {
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, label TEXT,
                value TEXT, connector_id TEXT, method_id TEXT, active INTEGER,
                time_created INTEGER, time_updated INTEGER)
            """, nil, nil, nil), SQLITE_OK)
        let value = #"{"type":"oauth","access":"at-db","refresh":"rt-db","expires":2000000000000,"metadata":{"accountID":"usr_db","email":"db@example.com","orgID":"org-1","orgName":"One","server":"https://opencode.ai/console"}}"#
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential (id, integration_id, value) VALUES ('row-1', 'opencode', '\(value)')", nil, nil, nil), SQLITE_OK)
        // do NOT checkpoint: row lives only in the WAL
        sqlite3_close(db)

        let found = OpencodeCredentialDetector.discover(in: tempDir)
        XCTAssertEqual(found.count, 1)
        let cred = try XCTUnwrap(found.first)
        XCTAssertEqual(cred.accountKey, "usr_db")
        XCTAssertEqual(cred.accessToken, "at-db")
        XCTAssertEqual(cred.refreshToken, "rt-db")
        XCTAssertEqual(cred.orgID, "org-1")
        XCTAssertEqual(cred.email, "db@example.com")
        XCTAssertTrue(cred.sourcePath.contains("opencode.db#row-1"))
    }

    func testDedupIdentityFallbackOrder() throws {
        // accountID wins
        try write("opencode.db", "")
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES ('r1', 'opencode', '\( #"{"type":"oauth","access":"a1","metadata":{"accountID":"usr_1","email":"e1@x.com"}}"# )')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES ('r2', 'opencode', '\( #"{"type":"oauth","access":"a2","metadata":{"email":"e2@x.com"}}"# )')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES ('r3', 'opencode', '\( #"{"type":"oauth","access":"a3","metadata":{}}"# )')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let found = OpencodeCredentialDetector.discover(in: tempDir)
        XCTAssertEqual(found.count, 3)
        let keys = Set(found.map(\.accountKey))
        XCTAssertTrue(keys.contains("usr_1"))
        XCTAssertTrue(keys.contains("e2@x.com"))
        XCTAssertEqual(found.count, Set(found.map(\.sourcePath)).count)
        // fingerprint path is deterministic
        let r3 = found.first { $0.sourcePath.contains("#r3") }!
        XCTAssertEqual(r3.accountKey.count, 20)
        XCTAssertEqual(found.filter { $0.sourcePath.contains("#r3") }.count, 1)
    }

    func testSQLitePreferredOverAuthJSONForSameAccount() throws {
        try write("auth.json", #"{"opencode": {"type": "oauth", "access": "stale-at", "refresh": "stale-rt", "expires": 1000000000000, "accountId": "usr_same"}}"#)
        let dbPath = tempDir.appendingPathComponent("opencode.db").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE credential (id TEXT PRIMARY KEY, integration_id TEXT, value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES ('r1', 'opencode', '\( #"{"type":"oauth","access":"fresh-at","refresh":"fresh-rt","expires":2000000000000,"metadata":{"accountID":"usr_same"}}"# )')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let found = OpencodeCredentialDetector.discover(in: tempDir)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.accessToken, "fresh-at")
        XCTAssertTrue(found.first?.sourcePath.contains("opencode.db") ?? false)
    }

    /// reload() re-reads a single entry — the router's stale-recovery path.
    func testReload() throws {
        try write("auth.json", #"{"opencode": {"type": "oauth", "access": "at-1", "refresh": "rt-1", "expires": 2000000000000, "accountId": "usr_1"}}"#)
        let path = tempDir.appendingPathComponent("auth.json").path + "#opencode"
        let cred = OpencodeCredentialDetector.reload(sourcePath: path)
        XCTAssertEqual(cred?.accessToken, "at-1")
        XCTAssertEqual(cred?.accountKey, "usr_1")
        // unknown entry -> nil
        XCTAssertNil(OpencodeCredentialDetector.reload(sourcePath: tempDir.appendingPathComponent("auth.json").path + "#nope"))
    }

    /// An api-key credential has no email to show — the row label falls back
    /// to a masked-key hint ("API key …Py6v") instead of the fingerprint
    /// accountKey. OAuth creds without email keep the accountKey fallback
    /// (a real console userID), so the helper returns nil for them.
    func testDetectedLabelMasksAPIKeyAndSkipsOAuth() throws {
        try write("auth.json", """
        {
            "opencode": {"type": "api", "key": "sk-AllvSEPy6vQx"},
            "opencode-work": {"type": "oauth", "access": "at-1", "expires": 2000000000000,
                              "accountId": "usr_work"}
        }
        """)
        let found = OpencodeCredentialDetector.discover(in: tempDir)
        let api = try XCTUnwrap(found.first { $0.kind == .api })
        let oauth = try XCTUnwrap(found.first { $0.kind == .oauth })
        XCTAssertEqual(MonitorAccountDiscovery.opencodeDetectedLabel(for: api), "API key …6vQx")
        XCTAssertNil(MonitorAccountDiscovery.opencodeDetectedLabel(for: oauth))
    }
}
