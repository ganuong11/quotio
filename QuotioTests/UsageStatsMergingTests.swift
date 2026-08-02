//
//  UsageStatsMergingTests.swift
//  QuotioTests
//
//  Tests for the Qoder usage-accounting merge (ticket #7 / ADR 0005 §2).
//
//  Qoder traffic bypasses CPA (ADR 0001), so CPA's `/usage` response never
//  includes it. `UsageStats.merging(_:)` folds the Qoder slice captured by
//  RequestTracker into the CPA-sourced stats for dashboard display. These
//  tests pin: (a) the merge arithmetic, (b) nil/empty safety, and (c) the
//  double-count invariant — only the Qoder slice may be merged, never the
//  whole RequestStats (which also holds CPA traffic).
//

import XCTest
@testable import Quotio

// `@MainActor` so test methods can read ProviderStats/UsageData properties,
// which inherit MainActor isolation from the project's default-isolation
// setting (matching how the production call site in QuotaViewModel — also
// @MainActor — touches them).
@MainActor
final class UsageStatsMergingTests: XCTestCase {

    // MARK: - Fixtures

    private func cpaStats(requests: Int = 100,
                          input: Int = 4000,
                          output: Int = 1000) -> UsageStats {
        UsageStats(
            usage: UsageData(
                totalRequests: requests,
                successCount: requests - 5,
                failureCount: 5,
                totalTokens: input + output,
                inputTokens: input,
                outputTokens: output
            ),
            failedRequests: 5
        )
    }

    private func slice(provider: String = "qoder",
                       requests: Int,
                       input: Int,
                       output: Int) -> ProviderStats {
        ProviderStats(
            provider: provider,
            requestCount: requests,
            inputTokens: input,
            outputTokens: output,
            averageDurationMs: 123
        )
    }

    // MARK: - Arithmetic

    func testMergeAddsQoderRequestsAndTokensToCPA() {
        let cpa = cpaStats(requests: 100, input: 4000, output: 1000)
        let qoder = slice(requests: 12, input: 800, output: 200)

        let merged = cpa.merging(qoder)

        XCTAssertEqual(merged.usage?.totalRequests, 112)
        XCTAssertEqual(merged.usage?.inputTokens, 4800)
        XCTAssertEqual(merged.usage?.outputTokens, 1200)
        XCTAssertEqual(merged.usage?.totalTokens, 6000)
        // Qoder requests are post-200-head completions; count as success.
        XCTAssertEqual(merged.usage?.successCount, 107)   // (100-5) + 12
        XCTAssertEqual(merged.usage?.failureCount, 5)     // unchanged
        XCTAssertEqual(merged.failedRequests, 5)          // unchanged
    }

    func testMergeWhenCPAUsageIsNilSynthesizesFromQoderOnly() {
        // CPA returned a body but with null usage (some versions do). Qoder
        // traffic should still be representable.
        let nilUsage = UsageStats(usage: nil, failedRequests: nil)
        let qoder = slice(requests: 3, input: 90, output: 30)

        let merged = nilUsage.merging(qoder)

        XCTAssertEqual(merged.usage?.totalRequests, 3)
        XCTAssertEqual(merged.usage?.totalTokens, 120)
        XCTAssertEqual(merged.usage?.successCount, 3)
    }

    // MARK: - No-op safety

    func testEmptyQoderSliceIsPassthrough() {
        let cpa = cpaStats()
        let emptySlice = slice(requests: 0, input: 0, output: 0)

        let merged = cpa.merging(emptySlice)

        XCTAssertEqual(merged.usage?.totalRequests, cpa.usage?.totalRequests)
        XCTAssertEqual(merged.usage?.inputTokens, cpa.usage?.inputTokens)
        XCTAssertEqual(merged.usage?.outputTokens, cpa.usage?.outputTokens)
    }

    func testZeroStaticIsIndeedZero() {
        // Guard the guardrail: ProviderStats.zero must be a safe no-op slice.
        XCTAssertEqual(ProviderStats.zero.requestCount, 0)
        XCTAssertEqual(ProviderStats.zero.totalTokens, 0)
    }

    // MARK: - Double-count invariant

    func testDoubleCountGuardCPATrafficIsNotSelfMerged() {
        // This documents the load-bearing rule: RequestStats.byProvider
        // contains BOTH a "claude" (CPA) entry and a "qoder" entry. The
        // caller must select ONLY "qoder" before merging. Merging the CPA
        // slice back in would double-count, since /usage already counted it.
        let cpa = cpaStats(requests: 100, input: 4000, output: 1000)
        let claudeSlice = slice(provider: "claude",
                                requests: 100, input: 4000, output: 1000)
        let qoderSlice = slice(provider: "qoder",
                               requests: 12, input: 800, output: 200)

        // Correct: merge only qoder.
        let correct = cpa.merging(qoderSlice)
        XCTAssertEqual(correct.usage?.totalRequests, 112)

        // WRONG (what callers must NOT do): merge the CPA slice too.
        let wrong = correct.merging(claudeSlice)
        XCTAssertEqual(wrong.usage?.totalRequests, 212, "this is the double-count the filter prevents")

        // The invariant: correct merge adds exactly the qoder slice.
        XCTAssertNotEqual(correct.usage?.totalRequests, wrong.usage?.totalRequests)
    }

    // MARK: - QuotaViewModel wiring contract

    func testRequestTrackerKeysQoderOnProviderString() {
        // Pins the key contract between ProxyBridge (which sets
        // `provider: "qoder"` at ProxyBridge.swift ~:1074) and the merge
        // call site in QuotaViewModel.refreshData, which reads
        // `byProvider["qoder"]`. If either side drifts, the merge silently
        // no-ops.
        let store = RequestHistoryStore(
            version: 1,
            entries: [
                RequestLog(
                    timestamp: Date(),
                    method: "POST",
                    endpoint: "/v1/chat/completions",
                    provider: "qoder",
                    model: "qoder/auto",
                    resolvedModel: "auto",
                    resolvedProvider: "qoder",
                    inputTokens: 500,
                    outputTokens: 150,
                    durationMs: 800,
                    statusCode: 200,
                    requestSize: 1024,
                    responseSize: 2048,
                    errorMessage: nil,
                    fallbackAttempts: nil,
                    fallbackStartedFromCache: false
                )
            ]
        )

        let stats = store.calculateStats()
        XCTAssertNotNil(stats.byProvider["qoder"],
                        "Qoder slice key drifted — merge call site would no-op")
        XCTAssertEqual(stats.byProvider["qoder"]?.inputTokens, 500)
        XCTAssertEqual(stats.byProvider["qoder"]?.requestCount, 1)
    }
}
