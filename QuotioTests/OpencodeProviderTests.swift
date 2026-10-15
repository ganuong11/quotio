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
}
