//
//  GatewayQuotaService.swift
//  QuotioCore
//
//  Port of QoderQuotaFetcher (qoder branch: Quotio/Services/QuotaFetchers/)
//  onto the gateway ports. Per enabled Qoder account:
//    GET https://openapi.qoder.sh/api/v2/quota/usage   Bearer <jobToken>
//  — no COSY signature, no WAF encoding (the quota endpoint needs neither).
//
//  Job tokens inside their refresh window are re-exchanged via
//  `QoderPATRefreshing` (preserving machineID) and persisted back through the
//  vault. A 429 records a per-account backoff (`rateLimitedUntil`) so the next
//  cycle skips the account — without it the fetcher feeds the very rate limit
//  it tripped.
//
//  Results are keyed by `accountKey`. `ProviderQuota` has no rate-limit
//  envelope fields, so the backoff marker stays internal — rate-limited
//  accounts simply produce no fresh quota until the backoff elapses.
//

import Foundation
import QuotioApplication
import QuotioDomain

// MARK: - Response shapes

/// Mirrors `QoderUsageInfo` in pi's `usage.ts`. `expiresAt` is a JS-style
/// millisecond epoch — decoded as Double and divided.
private struct QoderUsageResponse: Decodable, Sendable {
    let userQuota: QoderQuotaBucket?
    let orgResourcePackage: QoderQuotaBucket?
    let totalUsagePercentage: Double?
    let isQuotaExceeded: Bool?
    let expiresAt: Double?
}

private struct QoderQuotaBucket: Decodable, Sendable {
    let total: Double
    let used: Double
    let remaining: Double
    let percentage: Double
    let unit: String
}

// MARK: - Mapping

/// Pure mapping so it can sit in a nonisolated enum: one `QuotaMetric` per
/// non-empty bucket. `userQuota` is always emitted when present;
/// `orgResourcePackage` only when `total > 0` (pi guards the same way so an
/// empty org package doesn't render a meaningless row).
private enum QoderQuotaMapper {
    static func map(_ response: QoderUsageResponse, now: Date = Date()) -> ProviderQuota? {
        let resetTime = resetTimeString(for: response.expiresAt)

        var models: [QuotaMetric] = []
        if let bucket = response.userQuota {
            models.append(makeRow(name: "qoder-user-quota", bucket: bucket, resetTime: resetTime))
        }
        if let bucket = response.orgResourcePackage, bucket.total > 0 {
            models.append(makeRow(name: "qoder-org-resource-package", bucket: bucket, resetTime: resetTime))
        }

        guard !models.isEmpty else { return nil }
        return ProviderQuota(models: models, lastUpdated: now)
    }

    private static func makeRow(name: String, bucket: QoderQuotaBucket, resetTime: String) -> QuotaMetric {
        let used = max(0, bucket.used)
        let total = max(0, bucket.total)
        let remainingPercentage = total > 0
            ? max(0, min(100, (total - used) / total * 100))
            : 0
        return QuotaMetric(
            name: name,
            percentage: remainingPercentage,
            resetTime: resetTime,
            presentation: .progress(used: used, limit: total, unit: unit(for: bucket.unit))
        )
    }

    /// Qoder's free-form `unit` string onto the typed enum; unknown strings
    /// fall back to `.credits`.
    private static func unit(for raw: String) -> QuotaMetricUnit {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
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

    private static func resetTimeString(for expiresAt: Double?) -> String {
        guard let millis = expiresAt, millis.isFinite else { return "" }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: millis / 1000.0))
    }
}

// MARK: - Service

public actor GatewayQuotaService {
    /// Global OpenAPI base — never `openapi.qoder.com.cn`.
    private static let usageURL = URL(string: "https://openapi.qoder.sh/api/v2/quota/usage")!

    private let vault: any GatewayCredentialStoring
    private let metadata: any GatewayAccountStoring
    private let patService: any QoderPATRefreshing
    private let session: URLSession

    /// Per-account rate-limit backoff keyed by accountKey.
    private var rateLimitedUntil: [String: Date] = [:]

    /// Last successful quota per accountKey. Served when a cycle's fetch
    /// fails or the account is in backoff — an empty result would remove the
    /// provider from quota surfaces entirely, so stale beats missing.
    private var lastQuotas: [String: ProviderQuota] = [:]

    public init(
        vault: any GatewayCredentialStoring,
        metadata: any GatewayAccountStoring,
        patService: any QoderPATRefreshing,
        session: URLSession = URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15))
    ) {
        self.vault = vault
        self.metadata = metadata
        self.patService = patService
        self.session = session
    }

    /// Refresh every enabled Qoder account in the vault. Result is keyed by
    /// `GatewayAccount.accountKey`.
    public func fetchAllQuotas() async -> [String: ProviderQuota] {
        var results: [String: ProviderQuota] = [:]
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        let now = Date()
        rateLimitedUntil = rateLimitedUntil.filter { _, until in until > now }
        for account in await vault.accounts()
        where account.provider == .qoder
            && !disabledAccountIDs.contains(account.id)
            && !account.isDisabled {
            if let until = rateLimitedUntil[account.accountKey], until > now {
                if let stale = lastQuotas[account.accountKey] {
                    results[account.accountKey] = stale
                }
                continue
            }
            if let quota = await fetchOwnedQuota(account: account, now: now) {
                lastQuotas[account.accountKey] = quota
                results[account.accountKey] = quota
            } else if let stale = lastQuotas[account.accountKey] {
                results[account.accountKey] = stale
            }
        }
        return results
    }

    public func fetchQuota(accountKey: String) async -> ProviderQuota? {
        let disabledAccountIDs = await metadata.disabledAccountIDs()
        guard let account = await vault.accounts().first(where: {
            $0.provider == .qoder
                && $0.accountKey == accountKey
                && !disabledAccountIDs.contains($0.id)
                && !$0.isDisabled
        }) else { return nil }
        if let quota = await fetchOwnedQuota(account: account, now: Date()) {
            lastQuotas[accountKey] = quota
            return quota
        }
        return lastQuotas[accountKey]
    }

    private func fetchOwnedQuota(account: GatewayAccount, now: Date) async -> ProviderQuota? {
        guard let credential = await vault.credential(for: account.id) else { return nil }

        let jobToken = await rotateIfNeeded(credential: credential, account: account)
            ?? credential.accessToken

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(jobToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quotio", forHTTPHeaderField: "User-Agent")

        let data: Data
        let statusCode: Int
        let retryAfterHeader: String?
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            data = responseData
            statusCode = http.statusCode
            retryAfterHeader = http.value(forHTTPHeaderField: "Retry-After")
        } catch {
            return nil
        }

        if statusCode == 401 || statusCode == 403 {
            return ProviderQuota(isForbidden: true, accountDisplayName: account.displayName)
        }
        if statusCode == 429 {
            let backoff = TimeInterval(retryAfterHeader?.trimmingCharacters(in: .whitespaces) ?? "") ?? 60
            let clamped = min(max(backoff, 60), 15 * 60)
            rateLimitedUntil[account.accountKey] = now.addingTimeInterval(clamped)
            return nil
        }
        guard 200...299 ~= statusCode else { return nil }

        guard
            let response = try? JSONDecoder().decode(QoderUsageResponse.self, from: data),
            var quota = QoderQuotaMapper.map(response)
        else { return nil }
        quota.accountDisplayName = account.displayName
        return quota
    }

    /// Re-exchange the PAT when the job token is within its refresh window.
    /// Returns the rotated job token, or nil on skip/failure — the caller falls
    /// back to the stored token (best-effort, matches the upstream fetcher).
    private func rotateIfNeeded(
        credential: GatewayCredential,
        account: GatewayAccount
    ) async -> String? {
        let needsRotation = credential.expiresAt.map { $0 <= Date() } ?? true
        guard needsRotation else { return nil }

        guard let pat = credential.extra["pat"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              pat.hasPrefix("pt-") else {
            return nil
        }

        do {
            let rotated = try await patService.refreshCredential(credential, account: account)
            try await vault.store(rotated, account: account)
            return rotated.accessToken
        } catch {
            return nil
        }
    }
}

extension GatewayQuotaService: QoderQuotaFetching {}
