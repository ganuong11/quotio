import Foundation
import XCTest
@testable import QuotioDomain

final class QuotaModelsTests: XCTestCase {
    func testProviderIDsPreserveUnknownHostProvidersAndStringEncoding() throws {
        for id in ["codex", "github-copilot", "future-provider"] {
            let provider = try JSONDecoder().decode(QuotaProvider.self, from: Data("\"\(id)\"".utf8))
            XCTAssertEqual(provider.rawValue, id)
            XCTAssertEqual(try JSONEncoder().encode(provider), Data("\"\(id)\"".utf8))
        }
        for id in ["", "../provider", "provider\n", String(repeating: "x", count: 129)] {
            XCTAssertNil(QuotaProvider(rawValue: id))
        }
    }

    func testLegacyQuotaMetricDecodesWithoutTypedPresentation() throws {
        let data = Data(
            #"{"name":"legacy","percentage":42,"resetTime":"","used":3,"limit":10}"#.utf8
        )

        let metric = try JSONDecoder().decode(QuotaMetric.self, from: data)

        XCTAssertNil(metric.presentation)
        XCTAssertEqual(metric.percentage, 42)
        XCTAssertEqual(metric.used, 3)
        XCTAssertEqual(metric.limit, 10)
    }

    func testMetricPresentationsRoundTripThroughCodableSchema() throws {
        let values: [QuotaMetricPresentation] = [
            .progress(used: 1.25, limit: 10.5, unit: .usd),
            .amount(value: 4.75, unit: .credits, semantics: .balance),
            .status(text: "Enabled"),
        ]

        for value in values {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(QuotaMetricPresentation.self, from: encoded), value)
        }
    }

    func testImportedIDEPolicyUpdatesOnlyExistingAccounts() {
        let old = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: ["kept": fresh, "deleted": fresh],
            into: ["kept": old]
        )

        XCTAssertEqual(result, ["kept": fresh])
    }

    func testImportedIDEPolicyDoesNotImportWithoutConsent() {
        let fresh = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 80, resetTime: "")])

        XCTAssertTrue(QuotaPolicy.mergeImportedIDEQuotas(fetched: ["new": fresh], into: [:]).isEmpty)
    }

    func testImportedIDEPolicyKeepsAccountMissingFromFetch() {
        let existing = ProviderQuota(models: [QuotaMetric(name: "usage", percentage: 10, resetTime: "")])

        let result = QuotaPolicy.mergeImportedIDEQuotas(
            fetched: [:],
            into: ["kept": existing]
        )

        XCTAssertEqual(result, ["kept": existing])
    }

    func testCanonicalizedAccountsPromotesNewestAliasValue() {
        let stale = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let fresh = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 2_000))

        let result = QuotaPolicy.canonicalizedAccounts(
            ["github-copilot-user.json": fresh, "user": stale],
            aliases: ["github-copilot-user.json": "user"]
        )

        XCTAssertEqual(result, ["user": fresh])
    }

    func testLastUpdatedDoesNotBorrowSiblingTimestamp() {
        let sibling = ProviderQuota(lastUpdated: Date(timeIntervalSince1970: 1_000))
        let account = QuotaAccountID(provider: .claude, accountKey: "failed@example.com")

        let updated = QuotaPolicy.lastUpdated(
            for: account,
            in: [.claude: ["successful@example.com": sibling]]
        )

        XCTAssertNil(updated)
    }

    func testLowestAvailablePercentageIgnoresUnknownMetrics() {
        let quota = ProviderQuota(models: [
            QuotaMetric(name: "unknown", percentage: -1, resetTime: ""),
            QuotaMetric(name: "monthly", percentage: 70, resetTime: ""),
            QuotaMetric(name: "weekly", percentage: 40, resetTime: ""),
        ])

        XCTAssertEqual(QuotaPolicy.lowestAvailablePercentage(in: quota), 40)
    }

    func testProviderTraitsKeepIDEImportAndRoutingRulesSeparate() {
        XCTAssertTrue(QuotaProvider.cursor.isImportedFromLocalIDE)
        XCTAssertTrue(QuotaProvider.trae.isImportedFromLocalIDE)
        XCTAssertFalse(QuotaProvider.cursor.supportsManualAuth)
        XCTAssertFalse(QuotaProvider.trae.supportsQuotaOnlyMode)
        XCTAssertTrue(QuotaProvider.vertex.supportsQuotaOnlyMode)
        XCTAssertTrue(QuotaProvider.warp.isQuotaTrackingOnly)
        for provider in [
            QuotaProvider.factoryDroid, .devin, .grok, .openRouter, .amp, .warp,
        ] {
            XCTAssertFalse(provider.supportsLocalProxySetup)
        }
        XCTAssertTrue(QuotaProvider.codex.supportsLocalProxySetup)
        XCTAssertEqual(
            Set(QuotaProvider.allCases.filter(\.isImportedFromLocalIDE)),
            [.cursor, .trae]
        )
    }
}

extension QuotaModelsTests {
    func testFarFutureResetReadsAsNeverExpiresInsteadOfACountdown() {
        // Qoder reports a year-9999-style sentinel for packages that do not
        // expire; that must not surface as a multi-million-day countdown.
        let sentinel = QuotaMetric(name: "qoder-user-quota", percentage: 80,
                                 resetTime: "9999-12-31T23:59:59Z")
        XCTAssertNil(sentinel.resetDate)
        XCTAssertTrue(sentinel.resetNeverExpires)
        XCTAssertNil(sentinel.pace())

        let real = QuotaMetric(name: "qoder-user-quota", percentage: 80,
                               resetTime: "2027-08-12T00:00:00Z")
        XCTAssertNotNil(real.resetDate)
        XCTAssertFalse(real.resetNeverExpires)

        let empty = QuotaMetric(name: "qoder-user-quota", percentage: 80, resetTime: "")
        XCTAssertNil(empty.resetDate)
        XCTAssertFalse(empty.resetNeverExpires)
    }
}
