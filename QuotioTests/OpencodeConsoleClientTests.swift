//
//  OpencodeConsoleClientTests.swift
//  QuotioTests
//

import XCTest
@testable import Quotio

final class OpencodeConsoleClientTests: XCTestCase {

    private let server = "https://opencode.ai/console"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeClient() -> OpencodeConsoleClient {
        OpencodeConsoleClient(server: server, session: StubURLProtocol.makeSession())
    }

    func testDeviceCodeRequestPostsClientID() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.method, "POST")
            XCTAssertEqual(req.url.absoluteString, "https://opencode.ai/console/auth/device/code")
            let body = String(data: req.body, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"client_id\":\"opencode-cli\""))
            XCTAssertFalse(body.contains("supports_org_scope"))
            return StubURLProtocol.json([
                "device_code": "dc-1", "user_code": "UC-1234",
                "verification_uri_complete": "https://opencode.ai/device?user_code=UC-1234",
                "expires_in": 900, "interval": 5
            ])
        }
        let code = try await makeClient().requestDeviceCode()
        XCTAssertEqual(code.deviceCode, "dc-1")
        XCTAssertEqual(code.userCode, "UC-1234")
        XCTAssertEqual(code.verificationURIComplete, "https://opencode.ai/device?user_code=UC-1234")
        XCTAssertEqual(code.expiresIn, 900)
        XCTAssertEqual(code.interval, 5)
    }

    func testPollDeviceTokenPendingAndSlowDown() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { _ in StubURLProtocol.json(["error": "authorization_pending"], status: 400) }
        let pending = try await client.pollDeviceToken(deviceCode: "dc-1")
        XCTAssertEqual(pending, .pending)
        StubURLProtocol.handler = { _ in StubURLProtocol.json(["error": "slow_down"], status: 400) }
        let slow = try await client.pollDeviceToken(deviceCode: "dc-1")
        XCTAssertEqual(slow, .slowDown)
    }

    func testPollDeviceTokenAuthorized() async throws {
        StubURLProtocol.handler = { req in
            let body = String(data: req.body, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\""))
            XCTAssertTrue(body.contains("\"device_code\":\"dc-1\""))
            XCTAssertTrue(body.contains("\"client_id\":\"opencode-cli\""))
            return StubURLProtocol.json([
                "access_token": "at-1", "refresh_token": "rt-1",
                "expires_in": 3600, "org_id": "org-9"
            ])
        }
        let result = try await makeClient().pollDeviceToken(deviceCode: "dc-1")
        XCTAssertEqual(result, .authorized(accessToken: "at-1", refreshToken: "rt-1", expiresIn: 3600, orgID: "org-9"))
    }

    func testPollDeviceTokenDenied() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.json(["error": "access_denied"], status: 400) }
        let result = try await makeClient().pollDeviceToken(deviceCode: "dc-1")
        XCTAssertEqual(result, .denied)
    }

    func testRefreshPostsGrantAndReturnsTokens() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url.absoluteString, "https://opencode.ai/console/auth/device/token")
            let body = String(data: req.body, encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"grant_type\":\"refresh_token\""))
            XCTAssertTrue(body.contains("\"refresh_token\":\"rt-old\""))
            XCTAssertTrue(body.contains("\"client_id\":\"opencode-cli\""))
            return StubURLProtocol.json([
                "access_token": "at-new", "refresh_token": "rt-new", "expires_in": 7200
            ])
        }
        let tokens = try await makeClient().refresh(refreshToken: "rt-old")
        XCTAssertEqual(tokens.accessToken, "at-new")
        XCTAssertEqual(tokens.refreshToken, "rt-new")
        XCTAssertEqual(tokens.expiresIn, 7200)
        XCTAssertNil(tokens.orgID)
    }

    func testRefreshInvalidGrant() async throws {
        StubURLProtocol.handler = { _ in StubURLProtocol.json(["error": "invalid_grant"], status: 400) }
        do {
            _ = try await makeClient().refresh(refreshToken: "rt-old")
            XCTFail("expected invalidGrant")
        } catch OpencodeConsoleError.invalidGrant {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchIdentityPicksOrg() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.headers["Authorization"], "Bearer at-1")
            if req.url.path.hasSuffix("/api/user") {
                return StubURLProtocol.json(["id": "user-1", "email": "dev@example.com"])
            }
            if req.url.path.hasSuffix("/api/orgs") {
                return StubURLProtocol.json([["id": "org-b", "name": "Beta"], ["id": "org-a", "name": "Alpha"]])
            }
            return (404, [:], Data())
        }
        let client = makeClient()
        // With a token org hint, that org wins even though it sorts last.
        let hinted = try await client.fetchIdentity(accessToken: "at-1", orgID: "org-b")
        XCTAssertEqual(hinted, OpencodeIdentity(userID: "user-1", email: "dev@example.com", orgID: "org-b", orgName: "Beta"))
        // Without a hint, the alphabetically-first org is used (released-client behavior).
        let sorted = try await client.fetchIdentity(accessToken: "at-1")
        XCTAssertEqual(sorted, OpencodeIdentity(userID: "user-1", email: "dev@example.com", orgID: "org-a", orgName: "Alpha"))
    }

    func testFetchIdentityNoOrgs() async throws {
        StubURLProtocol.handler = { req in
            if req.url.path.hasSuffix("/api/user") {
                return StubURLProtocol.json(["id": "user-1", "email": "dev@example.com"])
            }
            if req.url.path.hasSuffix("/api/orgs") {
                return StubURLProtocol.json([[String: Any]]())
            }
            return (404, [:], Data())
        }
        let identity = try await makeClient().fetchIdentity(accessToken: "at-1")
        XCTAssertNil(identity.orgID)
        XCTAssertNil(identity.orgName)
    }

    func testNon2xxMapsToHTTPStatus() async throws {
        StubURLProtocol.handler = { _ in (500, [:], Data("oops".utf8)) }
        do {
            _ = try await makeClient().requestDeviceCode()
            XCTFail("expected httpStatus")
        } catch OpencodeConsoleError.httpStatus(let code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
