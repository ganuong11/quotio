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
}
