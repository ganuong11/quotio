//
//  OpencodeDeviceAuthorizerTests.swift
//  QuotioCore
//
//  Device-code onboarding path: requestDeviceCode → prompt + auto-open →
//  poll until authorized → identity → vault write.
//

import Foundation
import XCTest
@testable import QuotioInfrastructure
import QuotioApplication
import QuotioDomain

@MainActor private final class RecordingOpener: URLOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) -> Bool {
        opened.append(url)
        return true
    }
}

private actor StubCredentialStore: GatewayCredentialStoring {
    private(set) var stored: [GatewayCredential] = []
    private(set) var storedAccounts: [GatewayAccount] = []
    func accounts() async -> [GatewayAccount] { storedAccounts }
    func credential(for accountID: String) async -> GatewayCredential? { nil }
    func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
        stored.append(credential)
        storedAccounts.append(account)
    }
}

private final class PollCounter: @unchecked Sendable {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private final class PromptBox: @unchecked Sendable {
    var prompts: [OAuthPrompt] = []
}

@MainActor final class OpencodeDeviceAuthorizerTests: XCTestCase {

    private var console: OpencodeConsoleClient!
    private var opener: RecordingOpener!
    private var credentials: StubCredentialStore!
    private var authorizer: OpencodeDeviceAuthorizer!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        console = OpencodeConsoleClient(session: StubURLProtocol.makeSession())
        opener = RecordingOpener()
        credentials = StubCredentialStore()
        authorizer = OpencodeDeviceAuthorizer(
            console: console, urlOpener: opener, credentials: credentials)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try super.tearDownWithError()
    }

    private func request() -> OAuthAuthorizationRequest {
        OAuthAuthorizationRequest(
            providerID: AccountProviderID(rawValue: "opencode"),
            automaticallyOpensBrowser: true
        )
    }

    /// Happy path: code request → prompt carries URI+userCode, browser opened,
    /// first poll pending, second authorized → identity fetched → credential
    /// lands in the vault keyed by the console userID.
    func testDeviceFlowOnboardsIntoGatewayVault() async throws {
        let polls = PollCounter()
        StubURLProtocol.handler = { request in
            if request.url.path.hasSuffix("/auth/device/code") {
                return StubURLProtocol.json([
                    "device_code": "dc-1", "user_code": "ABCD-EFGH",
                    "verification_uri_complete": "/console/device?user_code=ABCD-EFGH",
                    "expires_in": 900, "interval": 5,
                ])
            }
            if request.url.path.hasSuffix("/auth/device/token") {
                if polls.next() == 1 {
                    return StubURLProtocol.json(["error": "authorization_pending"])
                }
                return StubURLProtocol.json([
                    "access_token": "at-x", "refresh_token": "rt-x",
                    "expires_in": 3600, "org_id": "org-7",
                ])
            }
            if request.url.path.hasSuffix("/api/user") {
                return StubURLProtocol.json(["id": "usr_42", "email": "dev@example.com"])
            }
            if request.url.path.hasSuffix("/api/orgs") {
                return StubURLProtocol.json([["id": "org-7", "name": "Seven"]])
            }
            return (500, [:], Data())
        }

        let promptBox = PromptBox()
        let outcome = try await authorizer.begin(
            request: request(), attemptID: OAuthAttemptID()) { prompt in
                promptBox.prompts.append(prompt)
            }
        let prompts = promptBox.prompts

        guard case .completed(let account) = outcome else {
            return XCTFail("expected .completed, got \(outcome)")
        }
        XCTAssertEqual(account.providerID.rawValue, "opencode")
        XCTAssertEqual(account.accountKey, "usr_42")
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.userCode, "ABCD-EFGH")
        XCTAssertEqual(
            prompts.first?.authorizationURL?.absoluteString,
            "https://opencode.ai/console/device?user_code=ABCD-EFGH")
        XCTAssertEqual(opener.opened.count, 1)

        let stored = await credentials.stored
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.accessToken, "at-x")
        XCTAssertEqual(stored.first?.refreshToken, "rt-x")
        XCTAssertEqual(stored.first?.extra["orgID"], "org-7")
        XCTAssertEqual(stored.first?.extra["server"], OpencodeConsoleClient.defaultServer)
        let storedAccounts = await credentials.storedAccounts
        XCTAssertEqual(storedAccounts.first?.accountKey, "usr_42")
        XCTAssertEqual(storedAccounts.first?.displayName, "dev@example.com")
        XCTAssertEqual(storedAccounts.first?.source, .onboarded)
    }

    /// A denied grant surfaces as `.expired` — the flow failed for good.
    func testDeniedGrantFailsExpired() async throws {
        StubURLProtocol.handler = { request in
            if request.url.path.hasSuffix("/auth/device/code") {
                return StubURLProtocol.json([
                    "device_code": "dc-1", "user_code": "ABCD-EFGH",
                    "verification_uri_complete": "https://opencode.ai/console/device?user_code=X",
                    "expires_in": 900, "interval": 5,
                ])
            }
            if request.url.path.hasSuffix("/auth/device/token") {
                return StubURLProtocol.json(["error": "access_denied"])
            }
            return (500, [:], Data())
        }

        do {
            _ = try await authorizer.begin(
                request: request(), attemptID: OAuthAttemptID()) { _ in }
            XCTFail("expected failure")
        } catch let failure as OAuthFlowFailure {
            XCTAssertEqual(failure, .expired)
        }
    }

    /// Non-opencode provider IDs are rejected without touching the console.
    func testOtherProvidersUnsupported() async throws {
        StubURLProtocol.handler = { _ in (500, [:], Data()) }
        do {
            _ = try await authorizer.begin(
                request: OAuthAuthorizationRequest(
                    providerID: AccountProviderID(rawValue: "claude")),
                attemptID: OAuthAttemptID()) { _ in }
            XCTFail("expected failure")
        } catch let failure as OAuthFlowFailure {
            XCTAssertEqual(failure, .unsupportedProvider)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// The dispatching authorizer routes opencode to the device flow and
    /// everything else to the CPA fallback.
    func testGatewayAuthorizerDispatch() async throws {
        StubURLProtocol.handler = { _ in (500, [:], Data()) }
        let fallback = FallbackAuthorizer()
        let composite = GatewayOAuthAuthorizer(opencode: authorizer, fallback: fallback)
        do {
            _ = try await composite.begin(
                request: OAuthAuthorizationRequest(
                    providerID: AccountProviderID(rawValue: "claude")),
                attemptID: OAuthAttemptID()) { _ in }
            XCTFail("expected failure")
        } catch {}
        let began = await fallback.began
        XCTAssertTrue(began)
    }
}

private actor FallbackAuthorizer: OAuthAuthorizing {
    private(set) var began = false
    func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        began = true
        throw OAuthFlowFailure.provider("fallback")
    }
    func completeManualCode(
        _ code: String, providerID: AccountProviderID, attemptID: OAuthAttemptID
    ) async throws -> Account { throw OAuthFlowFailure.unsupportedProvider }
    func cancel(attemptID: OAuthAttemptID) async {}
}
