import Foundation
import QuotioApplication
import QuotioDomain
@testable import QuotioInfrastructure
import XCTest

/// `GatewayQuotaService` — per-account Qoder quota fetch, PAT re-exchange on
/// expiry, and per-account rate-limit backoff.
final class GatewayQuotaServiceTests: XCTestCase {

    private actor QuotaStubVault: GatewayCredentialStoring {
        private var accountsList: [GatewayAccount] = []
        private var credentials: [String: GatewayCredential] = [:]
        private(set) var storeCalls = 0

        func seed(_ account: GatewayAccount, _ credential: GatewayCredential) {
            accountsList.append(account)
            credentials[account.id] = credential
        }

        func accounts() async -> [GatewayAccount] { accountsList }
        func credential(for accountID: String) async -> GatewayCredential? { credentials[accountID] }
        func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
            storeCalls += 1
            credentials[account.id] = credential
        }
    }

    private actor QuotaStubAccounts: GatewayAccountStoring {
        private var disabled: Set<String> = []
        func disabledAccountIDs() async -> Set<String> { disabled }
        func setDisabled(_ disabled: Bool, accountID: String) async throws {
            if disabled { self.disabled.insert(accountID) } else { self.disabled.remove(accountID) }
        }
        func disable(_ id: String) { disabled.insert(id) }
    }

    private actor QuotaStubPAT: QoderPATRefreshing {
        var next: Result<GatewayCredential, Error> = .failure(QoderPATError.invalidPAT)
        private(set) var callCount = 0
        func setNext(_ result: Result<GatewayCredential, Error>) {
            next = result
        }
        func refreshCredential(
            _ credential: GatewayCredential,
            account: GatewayAccount
        ) async throws -> GatewayCredential {
            callCount += 1
            return try next.get()
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeService(
        vault: QuotaStubVault,
        accounts: QuotaStubAccounts = QuotaStubAccounts(),
        pat: QuotaStubPAT = QuotaStubPAT()
    ) -> GatewayQuotaService {
        GatewayQuotaService(
            vault: vault,
            metadata: accounts,
            patService: pat,
            session: StubURLProtocol.makeSession()
        )
    }

    private func makeAccount(key: String = "user-1") -> GatewayAccount {
        GatewayAccount.make(
            provider: .qoder,
            accountKey: key,
            displayName: "Account \(key)",
            source: .onboarded
        )
    }

    private func makeCredential(
        accountID: String,
        expired: Bool = false,
        pat: String? = nil
    ) -> GatewayCredential {
        var extra: [String: String] = ["machineID": "m-1"]
        if let pat { extra["pat"] = pat }
        return GatewayCredential(
            accessToken: "job-\(accountID)",
            accountID: accountID,
            expiresAt: expired ? Date().addingTimeInterval(-60) : Date().addingTimeInterval(3600),
            extra: extra
        )
    }

    private static var usageJSON: [String: Any] { [
        "userQuota": ["total": 100.0, "used": 25.0, "remaining": 75.0, "percentage": 75.0, "unit": "credits"],
        "orgResourcePackage": ["total": 50.0, "used": 10.0, "remaining": 40.0, "percentage": 80.0, "unit": "usd"],
        "totalUsagePercentage": 25.0,
        "isQuotaExceeded": false,
        "expiresAt": 1_800_000_000_000.0,
    ]
    }

    // MARK: - Mapping

    func testMapsUserAndOrgBuckets() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer job-u1")
            return StubURLProtocol.json(Self.usageJSON)
        }

        let service = makeService(vault: vault)
        let results = await service.fetchAllQuotas()

        let quota = try XCTUnwrap(results[account.accountKey])
        XCTAssertEqual(quota.models.count, 2)
        XCTAssertEqual(quota.models[0].name, "qoder-user-quota")
        XCTAssertEqual(quota.models[0].percentage, 75.0, accuracy: 0.001)
        XCTAssertEqual(quota.models[1].name, "qoder-org-resource-package")
        XCTAssertEqual(quota.models[1].percentage, 80.0, accuracy: 0.001)
        XCTAssertEqual(quota.accountDisplayName, account.displayName)
        if case .progress(_, _, let unit)? = quota.models[1].presentation {
            XCTAssertEqual(unit, .usd)
        } else {
            XCTFail("expected .progress presentation")
        }
    }

    func testSkipsOrgBucketWhenTotalZero() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))
        StubURLProtocol.handler = { _ in
            StubURLProtocol.json([
                "userQuota": ["total": 10.0, "used": 1.0, "remaining": 9.0, "percentage": 90.0, "unit": "credits"],
                "orgResourcePackage": ["total": 0.0, "used": 0.0, "remaining": 0.0, "percentage": 0.0, "unit": "credits"],
            ])
        }
        let service = makeService(vault: vault)
        let results = await service.fetchAllQuotas()
        let quota = try XCTUnwrap(results[account.accountKey])
        XCTAssertEqual(quota.models.count, 1)
    }

    // MARK: - Account selection

    func testSkipsDisabledAndNonQoderAccounts() async throws {
        let vault = QuotaStubVault()
        let accounts = QuotaStubAccounts()
        let enabled = makeAccount(key: "enabled")
        let disabled = makeAccount(key: "disabled")
        let other = GatewayAccount.make(provider: .opencode, accountKey: "oc", source: .detected)
        await vault.seed(enabled, makeCredential(accountID: "e"))
        await vault.seed(disabled, makeCredential(accountID: "d"))
        await vault.seed(other, makeCredential(accountID: "o"))
        await accounts.disable(disabled.id)

        StubURLProtocol.handler = { _ in StubURLProtocol.json(Self.usageJSON) }
        let service = makeService(vault: vault, accounts: accounts)
        let results = await service.fetchAllQuotas()

        XCTAssertEqual(Set(results.keys), [enabled.accountKey])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - Rotation

    func testExpiredTokenRotatesViaPATRefresh() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1", expired: true, pat: "pt-abc"))
        let pat = QuotaStubPAT()
        await pat.setNext(.success(makeCredential(accountID: "u1-rotated")))

        StubURLProtocol.handler = { _ in StubURLProtocol.json(Self.usageJSON) }
        let service = makeService(vault: vault, pat: pat)
        _ = await service.fetchAllQuotas()

        let calls = await pat.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(StubURLProtocol.requests.last?.headers["Authorization"], "Bearer job-u1-rotated")
        let persisted = await vault.credential(for: account.id)
        XCTAssertEqual(persisted?.accessToken, "job-u1-rotated")
    }

    func testRotationFailureFallsBackToStoredToken() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1", expired: true, pat: "pt-abc"))
        let pat = QuotaStubPAT()
        await pat.setNext(.failure(QoderPATError.network("boom")))

        StubURLProtocol.handler = { _ in StubURLProtocol.json(Self.usageJSON) }
        let service = makeService(vault: vault, pat: pat)
        _ = await service.fetchAllQuotas()

        XCTAssertEqual(StubURLProtocol.requests.last?.headers["Authorization"], "Bearer job-u1")
    }

    func testExpiredTokenWithoutPATUsesStoredToken() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1", expired: true))
        let pat = QuotaStubPAT()

        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer job-u1")
            return StubURLProtocol.json(Self.usageJSON)
        }
        let service = makeService(vault: vault, pat: pat)
        _ = await service.fetchAllQuotas()
        let calls = await pat.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Rate limiting + errors

    func testRateLimitedAccountBackedOffNextCycle() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))

        StubURLProtocol.handler = { _ in
            (429, ["Retry-After": "120"], Data())
        }
        let service = makeService(vault: vault)

        _ = await service.fetchAllQuotas()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        // Second cycle: account is in backoff — no request issued.
        _ = await service.fetchAllQuotas()
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testUnauthorizedReturnsForbidden() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))
        StubURLProtocol.handler = { _ in (401, [:], Data()) }

        let service = makeService(vault: vault)
        let results = await service.fetchAllQuotas()
        let quota = try XCTUnwrap(results[account.accountKey])
        XCTAssertTrue(quota.isForbidden)
    }

    func testRateLimitedAccountKeepsLastGoodQuota() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))

        // First request succeeds; any later one would be rate limited.
        StubURLProtocol.handler = { _ in
            StubURLProtocol.requests.count <= 1
                ? StubURLProtocol.json(Self.usageJSON)
                : (429, ["Retry-After": "120"], Data())
        }
        let service = makeService(vault: vault)

        let first = await service.fetchAllQuotas()
        XCTAssertNotNil(first[account.accountKey])

        // Backoff cycle: no request, but the provider must keep its last
        // quota — an empty result would drop Qoder from the menu entirely.
        _ = await service.fetchAllQuotas()  // lands the 429 → backoff armed
        let third = await service.fetchAllQuotas()  // backoff: no request issued
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(third[account.accountKey]?.models.count, 2)
    }

    func testServerErrorKeepsLastGoodQuota() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))

        StubURLProtocol.handler = { _ in
            StubURLProtocol.requests.count == 1
                ? StubURLProtocol.json(Self.usageJSON)
                : (500, [:], Data())
        }
        let service = makeService(vault: vault)
        _ = await service.fetchAllQuotas()

        let results = await service.fetchAllQuotas()
        XCTAssertEqual(results[account.accountKey]?.models.count, 2)
    }

    func testServerErrorReturnsNoEntry() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))
        StubURLProtocol.handler = { _ in (500, [:], Data()) }

        let service = makeService(vault: vault)
        let results = await service.fetchAllQuotas()
        XCTAssertNil(results[account.accountKey])
    }

    func testFetchQuotaByAccountKey() async throws {
        let vault = QuotaStubVault()
        let account = makeAccount()
        await vault.seed(account, makeCredential(accountID: "u1"))
        StubURLProtocol.handler = { _ in StubURLProtocol.json(Self.usageJSON) }

        let service = makeService(vault: vault)
        let fetched = await service.fetchQuota(accountKey: account.accountKey)
        let quota = try XCTUnwrap(fetched)
        XCTAssertEqual(quota.models.count, 2)
        let missing = await service.fetchQuota(accountKey: "nobody")
        XCTAssertNil(missing)
    }
}
