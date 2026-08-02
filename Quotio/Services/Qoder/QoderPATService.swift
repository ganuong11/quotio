//
//  QoderPATService.swift
//  Quotio
//
//  Exchanges a Qoder Personal Access Token (PAT, `pt-...`) for a short-lived
//  Job Token (`jt-...`), resolves the user's identity, and produces a
//  MonitorOAuthCredential ready for MonitorCredentialVault.
//
//  Global endpoints only (openapi.qoder.sh). A CN-region PAT fails exchange
//  against the global endpoint — this is the intentional CN rejection per
//  ADR 0006 and the locked Q2 of the wave-1 grilling. No COSY *signature*
//  and no WAF body encoding are required for these endpoints (ADR 0002);
//  the `Cosy-Version` / `Cosy-ClientType` headers sent here are client
//  identification headers (matching pi), not the COSY signature envelope
//  that ticket #5 adds for the chat gateway.
//
//  Reference: pi-provider-qoder/src/pat.ts — port the exchange/userinfo
//  sequence, not the pi-specific machine-ID persistence or fallbacks.
//

import Foundation

/// Identity resolved from `/api/v1/userinfo`. Best-effort fields may be empty.
nonisolated struct QoderUserIdentity: Sendable, Equatable {
    let userID: String
    let email: String
    let name: String
}

/// Output of a successful PAT exchange. Caller (onboarding sheet, ticket #4)
/// stores the credential in MonitorCredentialVault and shows the identity for
/// user confirmation per ADR 0006 §3.
nonisolated struct QoderPATResult: Sendable {
    /// Vault-ready credential shaped per ADR 0002:
    /// accessToken = job token, expiresAt = job-token expiry − 5min buffer,
    /// extra carries the long-lived PAT, the per-account machine ID, and the
    /// job refresh token if one was issued.
    let credential: MonitorOAuthCredential

    /// Resolved identity for the confirmation step. userID == credential.accountID.
    let identity: QoderUserIdentity
}

/// Errors surfaced to the caller. PATs and tokens are never embedded in
/// messages — only HTTP status and a short, redacted upstream body snippet,
/// per the AGENTS.md rule against logging secrets.
nonisolated enum QoderPATError: LocalizedError {
    /// PAT missing or obviously malformed (`pt-...` prefix expected).
    case invalidPAT
    /// Transport failure (DNS, timeout, cancelled).
    case network(String)
    /// Non-2xx from exchange. Includes status and a ≤200-char body snippet.
    case exchangeFailed(status: Int, snippet: String)
    /// Exchange returned 2xx but the response shape was wrong (missing token).
    case exchangeMalformed
    /// `/userinfo` returned non-2xx. Treated as non-fatal by pi; surfaced here
    /// so the caller can decide. Snippet is ≤200 chars.
    case userInfoFailed(status: Int, snippet: String)
    /// `/userinfo` returned 2xx but no `id` field. userID is load-bearing for
    /// ADR 0006 §3 onboarding confirmation and as the stored `accountID`, so a
    /// credential without it must not be persisted.
    case identityMissing

    var errorDescription: String? {
        switch self {
        case .invalidPAT:
            return "Qoder PAT is missing or malformed."
        case .network(let detail):
            return "Qoder PAT exchange failed: network error (\(detail))."
        case .exchangeFailed(let status, let snippet):
            return trimmedMessage("Qoder PAT exchange failed: HTTP \(status).", snippet: snippet)
        case .exchangeMalformed:
            return "Qoder PAT exchange returned no job token."
        case .userInfoFailed(let status, let snippet):
            return trimmedMessage("Qoder user-info fetch failed: HTTP \(status).", snippet: snippet)
        case .identityMissing:
            return "Qoder user-info returned no user ID."
        }
    }

    private func trimmedMessage(_ base: String, snippet: String) -> String {
        let capped = String(snippet.prefix(200))
        return capped.isEmpty ? base : "\(base) \(capped)"
    }
}

/// Performs the Qoder PAT-exchange → userinfo sequence against the global
/// `openapi.qoder.sh` endpoints. No CN endpoint is reachable from this service.
actor QoderPATService {
    static let shared = QoderPATService()

    /// Global OpenAPI base. Hardcoded — never `openapi.qoder.com.cn`.
    /// Per ADR 0006, a CN-region PAT must fail exchange here.
    private static let openAPIBase = "https://openapi.qoder.sh"

    private static let exchangeURL = URL(string: "\(openAPIBase)/api/v1/jobToken/exchange")!
    private static let userInfoURL = URL(string: "\(openAPIBase)/api/v1/userinfo")!

    /// Refresh buffer applied to job-token expiry before storing, matching Grok
    /// (GrokQuotaFetcher) and pi's `expires - 5 * 60 * 1000`. The failover
    /// router (ADR 0006 §2) and quota fetcher (ticket #3) reuse the same
    /// threshold to decide when to re-exchange.
    private static let expiryBuffer: TimeInterval = 5 * 60

    private let userAgent = "Quotio"
    private let cosyVersion = "1.0.1"
    private let cosyClientType = "5"

    private var session: URLSession

    init() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 20))
    }

    /// Rebuild the URLSession after the user changes their upstream proxy.
    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 20))
    }

    /// Exchange a PAT for a job token, fetch the user's identity, and return a
    /// Vault-ready credential plus the resolved identity.
    ///
    /// On any failure (network, non-2xx, malformed response, identity fetch
    /// error) this throws — the caller must not persist a credential.
    func credentials(fromPat rawPAT: String) async throws -> QoderPATResult {
        let pat = rawPAT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pat.hasPrefix("pt-"), pat.count > "pt-".count else {
            throw QoderPATError.invalidPAT
        }

        let exchange = try await exchangeJobToken(pat: pat)
        let identity = try await fetchUserInfo(jobToken: exchange.jobToken)
        // userID is the stored `accountID` and the onboarding confirmation key
        // (ADR 0006 §3). A 2xx userinfo with no `id` is unusable — refuse to
        // persist rather than storing a credential with an empty accountID.
        guard !identity.userID.isEmpty else {
            throw QoderPATError.identityMissing
        }

        // Per-account machine ID, fresh per ADR 0006 §1. Quotio does NOT reuse
        // ~/.qoder/.auth/machine_id — its identity is independent of the
        // official CLI / pi provider.
        let machineID = UUID().uuidString

        // Apply the 5-min refresh buffer so a stored credential reads as
        // "needs rotation" slightly before true expiry, matching Grok.
        let bufferedExpiry = exchange.expiresAt.addingTimeInterval(-Self.expiryBuffer)

        var extra: [String: String] = [
            "pat": pat,
            "machineID": machineID,
        ]
        if !exchange.jobRefreshToken.isEmpty {
            extra["jobRefreshToken"] = exchange.jobRefreshToken
        }

        let credential = MonitorOAuthCredential(
            accessToken: exchange.jobToken,
            refreshToken: nil,
            idToken: nil,
            accountID: identity.userID,
            expiresAt: bufferedExpiry,
            extra: extra
        )
        return QoderPATResult(credential: credential, identity: identity)
    }

    // MARK: - Exchange

    private struct PatExchangeResult: Sendable {
        let jobToken: String
        let jobRefreshToken: String
        let expiresAt: Date
    }

    /// `POST /api/v1/jobToken/exchange { personal_token }`.
    /// No COSY signature required for this endpoint (CONTEXT.md).
    private func exchangeJobToken(pat: String) async throws -> PatExchangeResult {
        var request = URLRequest(url: Self.exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyClientHeaders(to: &request)

        // personal_token only; no other fields. Matches pi's exchangeJobToken.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["personal_token": pat])

        let (data, http) = try await perform(request)
        guard 200...299 ~= http.statusCode else {
            throw QoderPATError.exchangeFailed(status: http.statusCode, snippet: bodySnippet(data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw QoderPATError.exchangeMalformed
        }

        let refreshToken = (json["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let expiresAt = resolveExpiry(json: json, fallback: .now + 24 * 60 * 60)
        return PatExchangeResult(jobToken: token, jobRefreshToken: refreshToken, expiresAt: expiresAt)
    }

    // MARK: - User info

    /// `GET /api/v1/userinfo` with `Bearer <job token>`.
    ///
    /// Pi swallows userinfo errors as best-effort and returns empty strings;
    /// we surface them as `userInfoFailed` so the onboarding sheet (ticket #4)
    /// can show the upstream error rather than silently persisting a
    /// half-formed identity. ADR 0006 §3 makes userID load-bearing for the
    /// confirmation step, so an unresolvable identity should not produce a
    /// stored credential — `credentials(fromPat:)` enforces that below.
    private func fetchUserInfo(jobToken: String) async throws -> QoderUserIdentity {
        var request = URLRequest(url: Self.userInfoURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jobToken)", forHTTPHeaderField: "Authorization")
        applyClientHeaders(to: &request)

        let (data, http) = try await perform(request)
        guard 200...299 ~= http.statusCode else {
            throw QoderPATError.userInfoFailed(status: http.statusCode, snippet: bodySnippet(data))
        }

        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let userID = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = ((json["name"] as? String) ?? (json["username"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return QoderUserIdentity(userID: userID, email: email, name: name)
    }

    // MARK: - HTTP helpers

    /// Stamp the shared client-identification headers on a request. These are
    /// `Cosy-*` client headers (matching pi), not the COSY signature envelope
    /// that ticket #5 adds for the chat gateway; the exchange and userinfo
    /// endpoints require no signature (CONTEXT.md).
    private func applyClientHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cosyVersion, forHTTPHeaderField: "Cosy-Version")
        request.setValue(cosyClientType, forHTTPHeaderField: "Cosy-ClientType")
    }

    /// Send a request and map transport failures to `QoderPATError.network`.
    /// Callers guard the status code themselves so the error case keeps its
    /// specific `.exchangeFailed` / `.userInfoFailed` shape with a body snippet.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QoderPATError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QoderPATError.network("non-HTTP response")
        }
        return (data, http)
    }

    // MARK: - Expiry parsing

    /// Choose the earliest reliable expiry signal. The Qoder API has been
    /// observed to return `expires_at` (ISO8601 string) or `expires_in`
    /// (milliseconds — not seconds — per pi's reverse-engineering). Falls back
    /// to 24h if neither is present, matching pi.
    private func resolveExpiry(json: [String: Any], fallback: Date) -> Date {
        if let expiresAtString = json["expires_at"] as? String,
           let parsed = Self.parseISO8601(expiresAtString) {
            return parsed
        }
        if let expiresIn = json["expires_in"] as? NSNumber {
            // milliseconds, per pi note.
            return Date().addingTimeInterval(expiresIn.doubleValue / 1000.0)
        }
        if let expiresInNumber = json["expires_in"] as? Double {
            return Date().addingTimeInterval(expiresInNumber / 1000.0)
        }
        return fallback
    }

    /// Surfaces a short, redacted body snippet for error messages. The PAT and
    /// job token never legitimately appear in these response bodies, but we
    /// defensively redact any `pt-`/`jt-`-prefixed runs before truncating so a
    /// surprising upstream echo cannot leak a secret into a caller's log line
    /// or UI — hardening the AGENTS.md "no secrets logged" rule.
    private nonisolated func bodySnippet(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        return String(Self.redactTokens(in: text).prefix(200))
    }

    private nonisolated static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value) // without fractional seconds
    }

    /// Replace `pt-…` / `jt-…` runs with a placeholder. Token characters are
    /// alphanumeric plus `-`/`_`; we stop at whitespace, quotes, or JSON
    /// punctuation so the substitution stays local to the token run.
    ///
    /// Internal so other Qoder services reuse it (the SSE reparser scrubs
    /// upstream error snippets the same way). Hardens the AGENTS.md
    /// "no secrets logged" rule against surprising upstream echoes.
    nonisolated static func redactTokens(in text: String) -> String {
        let pattern = #"(pt|jt)-[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1-REDACTED")
    }
}
