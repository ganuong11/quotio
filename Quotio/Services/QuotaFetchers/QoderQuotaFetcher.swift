//
//  QoderQuotaFetcher.swift
//  Quotio
//
//  Phase 1 quota monitor for the Qoder provider (ADR 0007 §3). Reads a stored
//  job-token credential from MonitorCredentialVault, calls
//  `GET openapi.qoder.sh/api/v2/quota/usage` with the job token as Bearer (no
//  COSY signature, no WAF encoding — the quota endpoint needs neither, per
//  CONTEXT.md / ADR 0002), and maps the response to `ModelQuota` rows.
//
//  When the job token is within its refresh window, the PAT is re-exchanged via
//  `QoderPATService` (ticket #2) and the rotated credential is persisted back to
//  the Vault before the quota fetch proceeds.
//
//  Reference mapping: pi-provider-qoder/src/usage.ts (ported verbatim:
//  userQuota + orgResourcePackage buckets).
//

import Foundation

// MARK: - Response shapes

/// Mirrors `QoderUsageInfo` in pi's `usage.ts`. `expiresAt` is a JavaScript-style
/// millisecond epoch (the TS code wraps it in `new Date(...)`), so we decode it
/// as a Double and divide.
nonisolated private struct QoderUsageResponse: Decodable, Sendable {
    let userQuota: QoderQuotaBucket?
    let orgResourcePackage: QoderQuotaBucket?
    let totalUsagePercentage: Double?
    let isQuotaExceeded: Bool?
    let expiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case userQuota
        case orgResourcePackage
        case totalUsagePercentage
        case isQuotaExceeded
        case expiresAt
    }
}

nonisolated private struct QoderQuotaBucket: Decodable, Sendable {
    let total: Double
    let used: Double
    let remaining: Double
    let percentage: Double
    let unit: String
}

// MARK: - Mapping

fileprivate nonisolated enum QoderQuotaMapper {
    /// Port of `fetchQoderUsageForMode` in `usage.ts`. Produces one `ModelQuota`
    /// per non-empty bucket, matching pi's field selection:
    /// - `userQuota` is always emitted (when present)
    /// - `orgResourcePackage` is emitted only when `total > 0` (pi guards the
    ///   same way so an empty org package doesn't render a meaningless row)
    ///
    /// `ModelQuota.percentage` is derived from `used`/`total` so it stays
    /// consistent with the `.progress` presentation; the typed presentation is
    /// the primary render path.
    static func map(_ response: QoderUsageResponse, now: Date = Date()) -> ProviderQuotaData? {
        let resetTime = resetTimeString(for: response.expiresAt)

        var models: [ModelQuota] = []
        if let bucket = response.userQuota {
            models.append(makeRow(
                name: "qoder-user-quota",
                bucket: bucket,
                resetTime: resetTime
            ))
        }
        if let bucket = response.orgResourcePackage, bucket.total > 0 {
            models.append(makeRow(
                name: "qoder-org-resource-package",
                bucket: bucket,
                resetTime: resetTime
            ))
        }

        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: now)
    }

    private static func makeRow(
        name: String,
        bucket: QoderQuotaBucket,
        resetTime: String
    ) -> ModelQuota {
        let used = max(0, bucket.used)
        let total = max(0, bucket.total)
        let remainingPercentage = total > 0
            ? max(0, min(100, (total - used) / total * 100))
            : 0
        return ModelQuota(
            name: name,
            percentage: remainingPercentage,
            resetTime: resetTime,
            presentation: .progress(used: used, limit: total, unit: Self.unit(for: bucket.unit)),
            used: nil,
            limit: nil,
            remaining: nil
        )
    }

    /// Map Qoder's free-form `unit` string onto Quotio's typed enum. Qoder
    /// quotas are credits-style by default; we recognise the obvious currency
    /// spellings and fall back to `.credits`. This is a Phase 1 tracer-bullet
    /// assumption — revisit once real response samples confirm the unit string.
    private static func unit(for raw: String) -> QuotaMetricUnit {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "usd", "$", "usd$", "dollar", "dollars":
            return .usd
        case "requests", "request":
            return .requests
        case "searches", "search":
            return .searches
        default:
            return .credits
        }
    }

    /// `expiresAt` is a ms epoch (pi: `new Date(raw.expiresAt).toISOString()`).
    /// Nil/invalid → empty reset string, matching pi's `undefined` fallthrough.
    private static func resetTimeString(for expiresAt: Double?) -> String {
        guard let millis = expiresAt, millis.isFinite else { return "" }
        let date = Date(timeIntervalSince1970: millis / 1000.0)
        return ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Fetcher

/// Phase 1 Qoder quota monitor. Mirrors the `OpenRouterQuotaFetcher` shape
/// (Vault-backed, `fetchAllQuotas` + `fetchQuota(accountKey:)`) and adds the
/// PAT re-exchange-on-expiry path from `GrokQuotaFetcher`.
actor QoderQuotaFetcher {
    /// Global OpenAPI base. Hardcoded — never `openapi.qoder.com.cn`. A CN-region
    /// PAT fails exchange upstream (ADR 0006) so it never reaches this fetcher.
    private static let usageURL = URL(string: "https://openapi.qoder.sh/api/v2/quota/usage")!

    private let vault: MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private var session: URLSession

    init(
        vault: MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared
    ) {
        self.vault = vault
        self.metadata = metadata
        self.session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    /// Refresh every enabled Qoder account known to the Vault.
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        for account in await vault.accounts()
        where account.provider == .qoder && !disabledAccountIDs.contains(account.id) && !account.isDisabled {
            if let quota = await fetchOwnedQuota(account: account) {
                results[account.accountKey] = quota
            }
        }
        return results
    }

    /// Per-account refresh entry point used by `refreshQuota(for: QuotaAccountID)`.
    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        guard let account = await vault.accounts().first(where: {
            $0.provider == .qoder
                && $0.accountKey == accountKey
                && !disabledAccountIDs.contains($0.id)
                && !$0.isDisabled
        }) else { return nil }
        return await fetchOwnedQuota(account: account)
    }

    private func fetchOwnedQuota(account: MonitorAccount) async -> ProviderQuotaData? {
        guard let credential = await vault.credential(for: account.id) else { return nil }

        // Re-exchange-on-expiry path. The stored `expiresAt` already encodes the
        // 5-min refresh buffer (QoderPATService subtracts it at store time, per
        // ADR 0002), so `now >= expiresAt` means we are inside the refresh
        // window. A missing expiry is treated as needing rotation.
        let jobToken = await rotateIfNeeded(credential: credential, account: account)
            ?? credential.accessToken

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jobToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quotio", forHTTPHeaderField: "User-Agent")

        let data: Data
        let statusCode: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            data = responseData
            statusCode = http.statusCode
        } catch {
            Log.quota("Qoder quota fetch failed for \(account.accountKey): \(error.localizedDescription)")
            return nil
        }

        // Auth failures surface as forbidden — Phase 2 routing owns failover.
        if statusCode == 401 || statusCode == 403 {
            return ProviderQuotaData(isForbidden: true, accountDisplayName: account.displayName)
        }
        guard 200...299 ~= statusCode else {
            Log.quota("Qoder quota fetch for \(account.accountKey) returned HTTP \(statusCode)")
            return nil
        }

        do {
            let response = try JSONDecoder().decode(QoderUsageResponse.self, from: data)
            guard var quota = QoderQuotaMapper.map(response) else { return nil }
            quota.accountDisplayName = account.displayName
            return quota
        } catch {
            Log.quota("Qoder quota response parse failed for \(account.accountKey): \(error.localizedDescription)")
            return nil
        }
    }

    /// Re-exchange the PAT when the job token is within its refresh window.
    /// Returns the rotated job token on success, or nil if rotation was skipped
    /// or failed (caller falls back to the existing token — best-effort, matches
    /// Grok's behavior). Never attempts failover rotation (Phase 2 concern).
    private func rotateIfNeeded(
        credential: MonitorOAuthCredential,
        account: MonitorAccount
    ) async -> String? {
        let needsRotation: Bool
        if let expiresAt = credential.expiresAt {
            needsRotation = expiresAt <= Date()
        } else {
            needsRotation = true
        }
        guard needsRotation else { return nil }

        guard let pat = credential.extra["pat"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              pat.hasPrefix("pt-") else {
            Log.quota("Qoder job token needs rotation but no PAT is stored for \(account.accountKey)")
            return nil
        }

        do {
            // QoderPATService.credentials(fromPat:) re-runs the full exchange →
            // userinfo sequence and returns a fresh Vault-ready credential. We
            // persist it back through the Vault's CAS path so concurrent refreshes
            // don't clobber each other.
            //
            // Note: this also rotates the per-account machineID (QoderPATService
            // mints a fresh UUID on every exchange). Phase 1 accepts that — the
            // machine ID is a client-identification header, not session state —
            // rather than adding an exchange-only entry point to the PAT service.
            // Revisit if Qoder ever ties machine ID to session continuity.
            let result = try await QoderPATService.shared.credentials(fromPat: pat)
            try await vault.save(result.credential, metadata: account)
            return result.credential.accessToken
        } catch {
            Log.quota("Qoder PAT re-exchange failed for \(account.accountKey): \(error.localizedDescription)")
            return nil
        }
    }
}
