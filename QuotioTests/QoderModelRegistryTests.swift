//
//  QoderModelRegistryTests.swift
//  QuotioTests
//
//  Phase 2a tests for the hardcoded Qoder model catalog (ticket #7). The
//  catalog is a display hint, not a routing gate (ADR 0003 §2), so these tests
//  pin: (a) the known ID set matches ADR 0003 verbatim, and (b) unknown IDs
//  fall back to `defaultUnknown` rather than failing — the gateway rejects
//  invalid IDs upstream.
//

import XCTest
@testable import Quotio

final class QoderModelRegistryTests: XCTestCase {

    func testKnownIDsMatchADR0003() {
        // The 12 known global IDs from ADR 0003 §2. Drift here is silent
        // (the gateway adds/removes models under these keys), so this test
        // documents the Phase 2a snapshot.
        let expected: Set<String> = [
            "auto", "ultimate", "performance", "efficient", "lite",
            "qmodel", "qmodel_latest", "dmodel", "dfmodel",
            "gm51model", "kmodel", "mmodel",
        ]
        XCTAssertEqual(QoderModelRegistry.knownIDs, expected)
    }

    func testIsKnownReturnsTrueForKnownIDs() {
        for id in QoderModelRegistry.knownIDs {
            XCTAssertTrue(QoderModelRegistry.isKnown(id), "expected known: \(id)")
        }
    }

    func testIsKnownReturnsFalseForUnknownIDs() {
        XCTAssertFalse(QoderModelRegistry.isKnown("totally-fabricated-model"))
        XCTAssertFalse(QoderModelRegistry.isKnown(""))
        XCTAssertFalse(QoderModelRegistry.isKnown("qoder/auto"))  // prefix not stripped here
    }

    func testResolveKnownIDReturnsPopulatedConfig() {
        let config = QoderModelRegistry.resolve("auto")
        XCTAssertEqual(config.key, "auto")
        // Phase 2a gates reasoning — every catalog entry is non-reasoning.
        // Ticket #8 (Phase 2b) lifts the gate and may flag models here.
        XCTAssertFalse(config.isReasoning)
        XCTAssertEqual(config.maxOutputTokens, QoderChatTranslator.defaultMaxTokens)
        XCTAssertEqual(config.source, "system")
    }

    func testResolveUnknownIDFallsBackToDefault() {
        let config = QoderModelRegistry.resolve("some-future-model-qoder-ships")
        // defaultUnknown carries an empty key — the translator falls back to
        // the request model in that case (see QoderChatTranslator.translate).
        XCTAssertEqual(config.key, "")
        XCTAssertEqual(config, .defaultUnknown)
    }

    func testResolveIsDeterministic() {
        XCTAssertEqual(QoderModelRegistry.resolve("dmodel"), QoderModelRegistry.resolve("dmodel"))
    }
}
