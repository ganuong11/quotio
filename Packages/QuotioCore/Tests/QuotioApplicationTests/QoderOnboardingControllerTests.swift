import QuotioApplication
import QuotioDomain
import XCTest

/// `QoderOnboardingController` — PAT exchange → identity confirm → vault+store
/// write, with duplicate-account rejection.
final class QoderOnboardingControllerTests: XCTestCase {

    private final class StubPAT: QoderPATOnboarding, @unchecked Sendable {
        var result: Result<QoderPATResult, Error> = .failure(QoderPATError.invalidPAT)
        private(set) var seenPATs: [String] = []
        func credentials(fromPat pat: String) async throws -> QoderPATResult {
            seenPATs.append(pat)
            return try result.get()
        }
    }

    private final class StubStore: GatewayCredentialStoring, @unchecked Sendable {
        private(set) var stored: [(GatewayCredential, GatewayAccount)] = []
        private var accountsList: [GatewayAccount] = []
        private var credentials: [String: GatewayCredential] = [:]

        func accounts() async -> [GatewayAccount] { accountsList }
        func credential(for accountID: String) async -> GatewayCredential? { credentials[accountID] }
        func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
            stored.append((credential, account))
            credentials[account.id] = credential
            accountsList.append(account)
        }
    }

    private func makeResult(
        userID: String = "user-1",
        email: String = "a@b.c",
        name: String = "Account One"
    ) -> QoderPATResult {
        QoderPATResult(
            credential: GatewayCredential(
                accessToken: "job-token",
                expiresAt: Date().addingTimeInterval(3600),
                extra: ["pat": "pt-x", "machineID": "m-1"]
            ),
            identity: QoderUserIdentity(userID: userID, email: email, name: name)
        )
    }

    func testExchangeDelegatesToPATService() async throws {
        let pat = StubPAT()
        pat.result = .success(makeResult())
        let controller = QoderOnboardingController(onboarding: pat, credentials: StubStore())

        let result = try await controller.exchange(pat: "pt-abc")
        XCTAssertEqual(result.identity.userID, "user-1")
        XCTAssertEqual(pat.seenPATs, ["pt-abc"])
    }

    func testSaveStoresQoderAccountKeyedByUserID() async throws {
        let pat = StubPAT()
        let store = StubStore()
        let controller = QoderOnboardingController(onboarding: pat, credentials: store)

        try await controller.save(result: makeResult())

        XCTAssertEqual(store.stored.count, 1)
        let (credential, account) = try XCTUnwrap(store.stored.first)
        XCTAssertEqual(account.provider, .qoder)
        XCTAssertEqual(account.accountKey, "user-1")
        XCTAssertEqual(account.displayName, "Account One")
        XCTAssertEqual(account.source, .onboarded)
        XCTAssertEqual(account.email, "a@b.c")
        XCTAssertEqual(credential.accessToken, "job-token")
    }

    func testSaveFallsBackToEmailAccountKey() async throws {
        let store = StubStore()
        let controller = QoderOnboardingController(
            onboarding: StubPAT(), credentials: store
        )
        try await controller.save(result: makeResult(userID: "", email: "x@y.z", name: ""))
        XCTAssertEqual(store.stored.first?.1.accountKey, "x@y.z")
        XCTAssertEqual(store.stored.first?.1.displayName, "x@y.z")
    }

    func testSaveRejectsMissingIdentity() async throws {
        let controller = QoderOnboardingController(
            onboarding: StubPAT(), credentials: StubStore()
        )
        await XCTAssertAsyncThrowsError(
            try await controller.save(result: makeResult(userID: "", email: "", name: ""))
        ) { error in
            guard case .identityMissing? = (error as? QoderPATError) else {
                return XCTFail("expected .identityMissing, got \(error)")
            }
        }
    }

    func testSaveRejectsDuplicateAccount() async throws {
        let store = StubStore()
        let controller = QoderOnboardingController(onboarding: StubPAT(), credentials: store)

        try await controller.save(result: makeResult())

        // Re-saving the same account key (case-insensitive) must not silently
        // overwrite the existing credential.
        await XCTAssertAsyncThrowsError(
            try await controller.save(result: makeResult(userID: "USER-1"))
        ) { error in
            XCTAssertEqual(error as? QoderOnboardingError, .duplicateAccount)
        }
        XCTAssertEqual(store.stored.count, 1)
    }

    func testSaveToleratesStoredAccountWithSameIDButDifferentKey() async throws {
        let store = StubStore()
        let controller = QoderOnboardingController(onboarding: StubPAT(), credentials: store)

        try await controller.save(result: makeResult())
        try await controller.save(result: makeResult(userID: "user-2", email: "c@d.e"))
        XCTAssertEqual(store.stored.count, 2)
    }
}

/// Async-assert helper: XCTest's autoclosure variants don't take async bodies.
private func XCTAssertAsyncThrowsError(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected error to be thrown " + message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
