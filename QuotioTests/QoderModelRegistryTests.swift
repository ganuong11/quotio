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
        // The known global IDs. ADR 0003 §2 seeded this with 12 IDs at Phase 2a;
        // the gateway adds/removes models under these keys (drift is silent), so
        // `QoderModelRegistry.entries` is the live source of truth and this test
        // documents the current snapshot. Updated when the registry is refreshed.
        let expected: Set<String> = [
            "auto", "ultimate", "performance", "efficient", "lite",
            "qmodel", "qmodel_latest", "qmodel_38max",
            "dmodel", "dfmodel",
            "gm51model",
            "kmodel", "kmodel_latest",
            "mmodel",
            "cmodel",
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
