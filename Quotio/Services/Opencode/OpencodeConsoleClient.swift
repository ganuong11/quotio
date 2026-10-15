//
//  OpencodeConsoleClient.swift
//  Quotio
//
//  OpenCode Console auth API client (device-code OAuth, refresh, identity).
//  Mirrors the released client's `post()` shape in
//  `packages/core/src/plugin/provider/opencode.ts` (sst/opencode, v1.18.x):
//  JSON bodies, `client_id: "opencode-cli"`, no `supports_org_scope`
//  (2.0-dev-only — sending it would fingerprint us as non-released).
//

import Foundation

nonisolated struct OpencodeDeviceCode: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURIComplete: String
    let expiresIn: Int
    let interval: Int
}

nonisolated enum OpencodeTokenResult: Sendable, Equatable {
    case authorized(accessToken: String, refreshToken: String, expiresIn: Int, orgID: String?)
    case pending
    case slowDown
    case denied
}

nonisolated struct OpencodeIdentity: Sendable, Equatable {
    let userID: String
    let email: String
    let orgID: String?
    let orgName: String?
}

nonisolated enum OpencodeConsoleError: Error, Equatable {
    case invalidResponse
    case unauthorized
    case httpStatus(Int, String)
    case invalidGrant
}

actor OpencodeConsoleClient {

    static let defaultServer = "https://opencode.ai/console"
    private static let clientID = "opencode-cli"
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    private let server: String
    private let session: URLSession

    init(server: String = OpencodeConsoleClient.defaultServer, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    // MARK: - Device flow

    func requestDeviceCode() async throws -> OpencodeDeviceCode {
        let body: [String: Any] = ["client_id": Self.clientID]
        let (data, status) = try await post(path: "/auth/device/code", body: body)
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri_complete"] as? String,
              let expiresIn = json["expires_in"] as? Int,
              let interval = json["interval"] as? Int
        else {
            throw try mapFailure(status: status, data: data)
        }
        return OpencodeDeviceCode(
            deviceCode: deviceCode, userCode: userCode,
            verificationURIComplete: uri, expiresIn: expiresIn, interval: interval
        )
    }

    /// One poll attempt — the caller owns the loop/sleep/cancel.
    func pollDeviceToken(deviceCode: String) async throws -> OpencodeTokenResult {
        let body: [String: Any] = [
            "grant_type": Self.deviceGrant,
            "device_code": deviceCode,
            "client_id": Self.clientID,
        ]
        let (data, status) = try await post(path: "/auth/device/token", body: body)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let access = json["access_token"] as? String,
               let refresh = json["refresh_token"] as? String {
                return .authorized(
                    accessToken: access,
                    refreshToken: refresh,
                    expiresIn: json["expires_in"] as? Int ?? 3600,
                    orgID: json["org_id"] as? String
                )
            }
            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending": return .pending
                case "slow_down": return .slowDown
                default: return .denied
                }
            }
        }
        throw try mapFailure(status: status, data: data)
    }

    func refresh(refreshToken: String) async throws -> (accessToken: String, refreshToken: String, expiresIn: Int, orgID: String?) {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        let (data, status) = try await post(path: "/auth/device/token", body: body)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? String, error == "invalid_grant" {
                throw OpencodeConsoleError.invalidGrant
            }
            if (200..<300).contains(status),
               let access = json["access_token"] as? String,
               let refresh = json["refresh_token"] as? String {
                return (access, refresh, json["expires_in"] as? Int ?? 3600, json["org_id"] as? String)
            }
        }
        throw try mapFailure(status: status, data: data)
    }

    // MARK: - Identity

    /// `orgID` is the token response's `org_id` (2.0 backends only); when nil
    /// the alphabetically-first org is used, matching released-client behavior.
    func fetchIdentity(accessToken: String, orgID: String? = nil) async throws -> OpencodeIdentity {
        let (userData, userStatus) = try await get(path: "/api/user", accessToken: accessToken)
        guard (200..<300).contains(userStatus),
              let user = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let userID = user["id"] as? String,
              let email = user["email"] as? String
        else {
            throw try mapFailure(status: userStatus, data: userData)
        }

        var resolvedID = orgID
        var resolvedName: String?
        let (orgsData, orgsStatus) = try await get(path: "/api/orgs", accessToken: accessToken)
        if (200..<300).contains(orgsStatus),
           let orgs = try? JSONSerialization.jsonObject(with: orgsData) as? [[String: Any]] {
            let named = orgs.compactMap { org -> (id: String, name: String)? in
                guard let id = org["id"] as? String, let name = org["name"] as? String else { return nil }
                return (id, name)
            }
            if let hint = orgID, let match = named.first(where: { $0.id == hint }) {
                resolvedName = match.name
            } else if resolvedID == nil, let first = named.sorted(by: { $0.name < $1.name }).first {
                resolvedID = first.id
                resolvedName = first.name
            }
        }
        return OpencodeIdentity(userID: userID, email: email, orgID: resolvedID, orgName: resolvedName)
    }

    // MARK: - HTTP plumbing

    private func post(path: String, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: server + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func get(path: String, accessToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: server + path)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Body snippet is capped at 200 chars and is for error propagation only —
    /// never log it (may carry upstream detail we don't control).
    private func mapFailure(status: Int, data: Data) throws -> OpencodeConsoleError {
        if status == 401 || status == 403 { return .unauthorized }
        if !(200..<300).contains(status) {
            return .httpStatus(status, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return .invalidResponse
    }
}
