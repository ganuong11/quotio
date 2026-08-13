import XCTest
@testable import Quotio

@MainActor
final class AccountRowDataTests: XCTestCase {
    func testMonitorRowExposesQoderEmailSubtitle() {
        let account = MonitorAccount.make(
            provider: .qoder,
            accountKey: "12345",
            displayName: "John Doe",
            source: .quotioKeychain,
            email: "john@corp.com"
        )
        let row = AccountRowData.from(monitorAccount: account, status: nil, statusMessage: nil)
        XCTAssertEqual(row.displayName, "John Doe")
        XCTAssertEqual(row.subtitle, "john@corp.com")
    }

    func testMonitorRowSubtitleNilWithoutEmail() {
        let account = MonitorAccount.make(
            provider: .qoder,
            accountKey: "12345",
            displayName: "John Doe",
            source: .quotioKeychain
        )
        let row = AccountRowData.from(monitorAccount: account, status: nil, statusMessage: nil)
        XCTAssertNil(row.subtitle)
    }

    func testMonitorRowSubtitleNilWhenEmailDuplicatesDisplayName() {
        // No human name → displayName already fell back to the email; showing
        // it again as a subtitle would be redundant.
        let account = MonitorAccount.make(
            provider: .qoder,
            accountKey: "12345",
            displayName: "john@corp.com",
            source: .quotioKeychain,
            email: "john@corp.com"
        )
        let row = AccountRowData.from(monitorAccount: account, status: nil, statusMessage: nil)
        XCTAssertNil(row.subtitle)
    }
}
