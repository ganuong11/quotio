//
//  OpencodeProviderTests.swift
//  QuotioTests
//

import XCTest
@testable import QuotioInfrastructure
import QuotioApplication
import QuotioDomain

final class OpencodeProviderTests: XCTestCase {

    func testOpencodeProviderBasics() {
        XCTAssertEqual(QuotaProvider.opencode.rawValue, "opencode")
        XCTAssertTrue(QuotaProvider.gatewayNativeProviders.contains(.opencode))
    }

    /// Device-login result mapping: canonical accountKey = console userID,
    /// displayName = email, org/server carried in credential extras.
    func testMakeOpencodeAccountDedupAndExtras() {
        let identity = OpencodeIdentity(
            userID: "Usr_ABC123", email: "dev@example.com",
            orgID: "org-9", orgName: "Nine"
        )
        let (account, credential) = OpencodeAccountFactory.makeAccount(
            identity: identity,
            accessToken: "at-1",
            refreshToken: "rt-1",
            expiresIn: 3600
        )
        XCTAssertEqual(account.provider, .opencode)
        XCTAssertEqual(account.accountKey, "Usr_ABC123")
        XCTAssertTrue(account.id.hasPrefix("gateway-"))
        XCTAssertEqual(account.displayName, "dev@example.com")
        XCTAssertEqual(account.source, .onboarded)
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
        let merged = GatewayListener.mergeModelsBody(
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
        let merged = GatewayListener.mergeModelsBody(
            into: cpaModelsBody(["gpt-4o"]),
            mergeQoder: false,
            opencodeModels: [OpencodeFreeModel(id: "cat-jam-free", displayName: nil)]
        )
        XCTAssertEqual(modelIDs(merged!), ["gpt-4o", "opencode/cat-jam-free"])
    }

    /// Neither router wired → nil (raw passthrough, models discovery unbroken).
    func testMergeModelsBodyNeitherReturnsNil() {
        XCTAssertNil(GatewayListener.mergeModelsBody(
            into: cpaModelsBody(["gpt-4o"]),
            mergeQoder: false, opencodeModels: []))
        // malformed CPA body still degrades to nil even with models to merge
        XCTAssertNil(GatewayListener.mergeModelsBody(
            into: Data("nope".utf8),
            mergeQoder: true,
            opencodeModels: [OpencodeFreeModel(id: "a", displayName: nil)]))
    }

    /// Route → rejection mapping: rejected/notInFreeSet → 404, cold-start
    /// empty catalog → 503 catalog-unavailable, servable routes → nil.
    func testOpencodeRejectionMapping() {
        let rejected = GatewayListener.opencodeRejection(for: .rejected, catalogIsEmpty: false)
        XCTAssertEqual(rejected?.status, 404)
        let paid = GatewayListener.opencodeRejection(for: .notInFreeSet, catalogIsEmpty: false)
        XCTAssertEqual(paid?.status, 404)
        let cold = GatewayListener.opencodeRejection(for: .notInFreeSet, catalogIsEmpty: true)
        XCTAssertEqual(cold?.status, 503)
        XCTAssertNil(GatewayListener.opencodeRejection(for: .chat, catalogIsEmpty: false))
        XCTAssertNil(GatewayListener.opencodeRejection(for: .responses, catalogIsEmpty: false))
    }

    // MARK: - Task 8: stale-account issue observer

    /// The stale payload sets a QuotaRefreshIssue on the matching monitor
    /// account; the recovered payload clears it. Exercises the static core —
    /// a live QuotaViewModel can't be constructed inside the test host
    /// (deinit aborts under the bundled test runtime).
    func testOpencodeStaleIssueSetAndCleared() {
        let account = GatewayAccount.make(
            provider: .opencode, accountKey: "Usr_Det",
            source: .detected)
        var issues: [QuotaAccountID: QuotaRefreshIssue] = [:]
        let id = QuotaAccountID(provider: .opencode, accountKey: "Usr_Det")

        GatewayQuotaOverlay.applyOpencodeIssue(
            accountKey: "usr_det", stale: true, to: [account], issues: &issues)
        XCTAssertNotNil(issues[id])
        XCTAssertEqual(issues[id]?.reason, .authentication)

        GatewayQuotaOverlay.applyOpencodeIssue(
            accountKey: "USR_DET", stale: false, to: [account], issues: &issues)
        XCTAssertNil(issues[id])
    }

    /// An account key that isn't in monitorAccounts is a no-op.
    func testOpencodeStaleIssueUnknownAccount() {
        var issues: [QuotaAccountID: QuotaRefreshIssue] = [:]
        GatewayQuotaOverlay.applyOpencodeIssue(
            accountKey: "nobody", stale: true, to: [], issues: &issues)
        XCTAssertTrue(issues.isEmpty)
    }

    // MARK: - Rate-limit map (Quota tab status)

    /// The rate-limit map is keyed case-insensitively by accountKey and
    /// self-expires: a past `until` reads as "not blocked".
    func testOpencodeRateLimitMapCaseAndExpiry() {
        var limits: [String: Date] = [:]
        let now = Date()
        GatewayQuotaOverlay.applyOpencodeRateLimit(
            accountKey: "Usr_ABC", retryAfter: 60, to: &limits, now: now)
        XCTAssertEqual(
            GatewayQuotaOverlay.opencodeRateLimitUntil(
                accountKey: "usr_abc", in: limits, now: now),
            now.addingTimeInterval(60))
        // expired entry → nil
        XCTAssertNil(
            GatewayQuotaOverlay.opencodeRateLimitUntil(
                accountKey: "usr_abc", in: limits, now: now.addingTimeInterval(61)))
        // unknown account → nil
        XCTAssertNil(
            GatewayQuotaOverlay.opencodeRateLimitUntil(
                accountKey: "nobody", in: limits, now: now))
    }
}
