//
//  OpencodeProviderTests.swift
//  QuotioTests
//

import XCTest
@testable import Quotio

final class OpencodeProviderTests: XCTestCase {

    func testOpencodeProviderBasics() {
        XCTAssertEqual(AIProvider.opencode.rawValue, "opencode")
        XCTAssertEqual(AIProvider.opencode.displayName, "OpenCode")
        XCTAssertEqual(AIProvider.opencode.oauthEndpoint, "")
        XCTAssertTrue(AIProvider.opencode.supportsManualAuth)
        XCTAssertFalse(AIProvider.opencode.isQuotaTrackingOnly)
    }

    /// Device-login result mapping: canonical accountKey = console userID,
    /// displayName = email, org/server carried in credential extras.
    func testMakeOpencodeAccountDedupAndExtras() {
        let identity = OpencodeIdentity(
            userID: "Usr_ABC123", email: "dev@example.com",
            orgID: "org-9", orgName: "Nine"
        )
        let (account, credential) = MonitorOAuthCoordinator.makeOpencodeAccount(
            identity: identity,
            accessToken: "at-1",
            refreshToken: "rt-1",
            expiresIn: 3600
        )
        XCTAssertEqual(account.provider, .opencode)
        XCTAssertEqual(account.accountKey, "Usr_ABC123")
        XCTAssertEqual(account.deduplicationKey, "opencode:usr_abc123")
        XCTAssertEqual(account.displayName, "dev@example.com")
        XCTAssertEqual(account.source, .quotioKeychain)
        XCTAssertTrue(account.canDelete)
        XCTAssertEqual(credential.accessToken, "at-1")
        XCTAssertEqual(credential.refreshToken, "rt-1")
        XCTAssertEqual(credential.accountID, "Usr_ABC123")
        XCTAssertNotNil(credential.expiresAt)
        XCTAssertEqual(credential.extra["orgID"], "org-9")
        XCTAssertEqual(credential.extra["orgName"], "Nine")
        XCTAssertEqual(credential.extra["server"], "https://opencode.ai/console")
    }

    // MARK: - Task 8: ProxyBridge wiring helpers

    private func cpaModelsBody(_ ids: [String]) -> Data {
        let entries = ids.map {
            ["id": $0, "object": "model", "created": 1, "owned_by": "t"] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["object": "list", "data": entries])
    }

    private func modelIDs(_ body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }
    }

    /// The /v1/models merge chains Qoder → opencode; both namespaces land.
    func testMergeModelsBodyChainsBothNamespaces() {
        let merged = ProxyBridge.mergeModelsBody(
            into: cpaModelsBody(["gpt-4o"]),
            mergeQoder: true,
            opencodeModels: [OpencodeFreeModel(id: "big-pickle", displayName: nil)]
        )
        let ids = modelIDs(merged!)
        XCTAssertTrue(ids.contains("opencode/big-pickle"))
        XCTAssertTrue(ids.contains { $0.hasPrefix("qoder/") })
    }

    /// Opencode merge happens even when the Qoder router isn't wired —
    /// opencodeRouter-non-nil is sufficient.
    func testMergeModelsBodyOpencodeOnly() {
        let merged = ProxyBridge.mergeModelsBody(
            into: cpaModelsBody(["gpt-4o"]),
            mergeQoder: false,
            opencodeModels: [OpencodeFreeModel(id: "cat-jam-free", displayName: nil)]
        )
        XCTAssertEqual(modelIDs(merged!), ["gpt-4o", "opencode/cat-jam-free"])
    }

    /// Neither router wired → nil (raw passthrough, models discovery unbroken).
    func testMergeModelsBodyNeitherReturnsNil() {
        XCTAssertNil(ProxyBridge.mergeModelsBody(
            into: cpaModelsBody(["gpt-4o"]),
            mergeQoder: false, opencodeModels: []))
        // malformed CPA body still degrades to nil even with models to merge
        XCTAssertNil(ProxyBridge.mergeModelsBody(
            into: Data("nope".utf8),
            mergeQoder: true,
            opencodeModels: [OpencodeFreeModel(id: "a", displayName: nil)]))
    }

    /// Route → rejection mapping: rejected/notInFreeSet → 404, cold-start
    /// empty catalog → 503 catalog-unavailable, servable routes → nil.
    func testOpencodeRejectionMapping() {
        let rejected = ProxyBridge.opencodeRejection(for: .rejected, catalogIsEmpty: false)
        XCTAssertEqual(rejected?.status, 404)
        let paid = ProxyBridge.opencodeRejection(for: .notInFreeSet, catalogIsEmpty: false)
        XCTAssertEqual(paid?.status, 404)
        let cold = ProxyBridge.opencodeRejection(for: .notInFreeSet, catalogIsEmpty: true)
        XCTAssertEqual(cold?.status, 503)
        XCTAssertNil(ProxyBridge.opencodeRejection(for: .chat, catalogIsEmpty: false))
        XCTAssertNil(ProxyBridge.opencodeRejection(for: .responses, catalogIsEmpty: false))
    }

    // MARK: - Task 8: stale-account issue observer

    /// The stale payload sets a MonitorRefreshIssue on the matching monitor
    /// account; the recovered payload clears it. Exercises the static core —
    /// a live QuotaViewModel can't be constructed inside the test host
    /// (deinit aborts under the bundled test runtime).
    func testOpencodeStaleIssueSetAndCleared() {
        let account = MonitorAccount.make(
            provider: .opencode, accountKey: "Usr_Det",
            source: .nativeCredential, credentialReference: "/tmp/x#y")
        var issues: [QuotaAccountID: MonitorRefreshIssue] = [:]
        let id = QuotaAccountID(provider: .opencode, accountKey: "Usr_Det")

        QuotaViewModel.applyOpencodeIssue(
            accountKey: "usr_det", stale: true, to: [account], issues: &issues)
        XCTAssertNotNil(issues[id])
        XCTAssertFalse(issues[id]!.message.isEmpty)

        QuotaViewModel.applyOpencodeIssue(
            accountKey: "USR_DET", stale: false, to: [account], issues: &issues)
        XCTAssertNil(issues[id])
    }

    /// An account key that isn't in monitorAccounts is a no-op.
    func testOpencodeStaleIssueUnknownAccount() {
        var issues: [QuotaAccountID: MonitorRefreshIssue] = [:]
        QuotaViewModel.applyOpencodeIssue(
            accountKey: "nobody", stale: true, to: [], issues: &issues)
        XCTAssertTrue(issues.isEmpty)
    }
}
