import Foundation

nonisolated struct GrokAuthCandidate: Sendable, Equatable {
    let entryKey: String
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let clientID: String
    let expiresAt: Date?

    var displayName: String {
        MonitorIdentity.jwtString(idToken, claim: "email") ?? "Grok " + String(entryKey.prefix(8))
    }
}

nonisolated enum GrokQuotaMapper {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    static func mapBilling(_ data: Data, plan: String?) -> ProviderQuotaData? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = period["type"] as? String else { return nil }

        var models: [ModelQuota] = []
        if periodType == weeklyPeriodType,
           let endString = period["end"] as? String,
           parseDate(endString) != nil {
            let used = number(config["creditUsagePercent"]) ?? 0
            models.append(ModelQuota(
                name: "grok-weekly",
                percentage: max(0, min(100, 100 - used)),
                resetTime: ISO8601DateFormatter().string(from: parseDate(endString)!)
            ))
        }

        let cap = number((config["onDemandCap"] as? [String: Any])?["val"]) ?? 0
        let status = cap > 0
            ? String(format: "grok.status.cap".localizedStatic(), formatUnits(cap))
            : "grok.status.disabled".localizedStatic()
        models.append(ModelQuota(
            name: "grok-extra-usage",
            percentage: -1,
            resetTime: "",
            presentation: .status(text: status)
        ))
        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: plan)
    }

    static func planName(_ data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return trimmed(body["subscription_tier_display"] as? String)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatUnits(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

actor GrokQuotaFetcher {
    static let authPath = "~/.grok/auth.json"
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"

    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private var session: URLSession

    init() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results = await fetchOwnedQuotas()
        for candidate in Self.loadCandidates() where results[candidate.entryKey] == nil {
            if let quota = await fetchQuota(candidate, vaultAccount: nil) {
                results[candidate.entryKey] = quota
            }
        }
        return results
    }

    /// Fetches the candidate identified by its stable auth-file entry key or vault account key.
    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        if let account = await MonitorCredentialVault.shared.accounts().first(where: {
            $0.provider == .grok && !$0.isDisabled && $0.accountKey == accountKey
        }) {
            return await fetchOwnedQuota(account: account)
        }
        guard let candidate = Self.loadCandidates().first(where: { $0.entryKey == accountKey }) else {
            return nil
        }
        return await fetchQuota(candidate, vaultAccount: nil)
    }

    private func fetchOwnedQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .grok && !$0.isDisabled }) {
            if let quota = await fetchOwnedQuota(account: account) {
                results[account.accountKey] = quota
            }
        }
        return results
    }

    private func fetchOwnedQuota(account: MonitorAccount) async -> ProviderQuotaData? {
        guard let credential = await MonitorCredentialVault.shared.credential(for: account.id) else { return nil }
        let candidate = GrokAuthCandidate(
            entryKey: account.accountKey,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            idToken: credential.idToken,
            clientID: credential.extra["clientId"] ?? Self.defaultClientID,
            expiresAt: credential.expiresAt
        )
        return await fetchQuota(candidate, vaultAccount: account)
    }

    nonisolated static func quotaResult(
        data: Data,
        statusCode: Int,
        plan: String?,
        displayName: String
    ) -> ProviderQuotaData? {
        if statusCode == 401 || statusCode == 403 {
            return ProviderQuotaData(isForbidden: true, accountDisplayName: displayName)
        }
        guard 200...299 ~= statusCode,
              var quota = GrokQuotaMapper.mapBilling(data, plan: plan) else { return nil }
        quota.accountDisplayName = displayName
        return quota
    }

    nonisolated static func loadCandidates(path: String = MonitorIdentity.expand(authPath)) -> [GrokAuthCandidate] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { key, raw in
            guard let entry = raw as? [String: Any],
                  let token = trimmed(entry["key"] as? String) else { return nil }
            let entryClientID = trimmed(entry["oidc_client_id"] as? String)
                ?? clientID(fromEntryKey: key)
                ?? defaultClientID
            return GrokAuthCandidate(
                entryKey: key,
                accessToken: token,
                refreshToken: trimmed((entry["refresh_token"] as? String) ?? (entry["refresh"] as? String)),
                idToken: trimmed(entry["id_token"] as? String),
                clientID: entryClientID,
                expiresAt: expiryDate(entry: entry, token: token)
            )
        }.sorted { $0.entryKey < $1.entryKey }
    }

    private nonisolated static func clientID(fromEntryKey key: String) -> String? {
        guard let separator = key.range(of: "::", options: .backwards) else { return nil }
        return trimmed(String(key[separator.upperBound...]))
    }

    private func fetchQuota(
        _ original: GrokAuthCandidate,
        vaultAccount: MonitorAccount?
    ) async -> ProviderQuotaData? {
        var candidate = original
        let displayName = vaultAccount?.displayName ?? candidate.displayName
        if let expiry = candidate.expiresAt, expiry.timeIntervalSinceNow <= 300,
           let refreshed = await refresh(candidate, vaultAccount: vaultAccount) {
            candidate = refreshed
        }

        var billing = await get(billingURL, token: candidate.accessToken)
        if billing?.1.statusCode == 401 || billing?.1.statusCode == 403,
           let refreshed = await refresh(candidate, vaultAccount: vaultAccount) {
            candidate = refreshed
            billing = await get(billingURL, token: candidate.accessToken)
        }
        guard let (billingData, billingResponse) = billing else { return nil }
        if billingResponse.statusCode == 401 || billingResponse.statusCode == 403 {
            return Self.quotaResult(
                data: billingData,
                statusCode: billingResponse.statusCode,
                plan: nil,
                displayName: displayName
            )
        }
        guard 200...299 ~= billingResponse.statusCode else { return nil }

        let plan: String?
        if let (settingsData, settingsResponse) = await get(settingsURL, token: candidate.accessToken),
           200...299 ~= settingsResponse.statusCode {
            plan = GrokQuotaMapper.planName(settingsData)
        } else {
            plan = nil
        }
        return Self.quotaResult(
            data: billingData,
            statusCode: billingResponse.statusCode,
            plan: plan,
            displayName: displayName
        )
    }

    private func get(_ url: URL, token: String) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quotio", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    private func refresh(
        _ candidate: GrokAuthCandidate,
        vaultAccount: MonitorAccount?
    ) async -> GrokAuthCandidate? {
        guard let refreshToken = candidate.refreshToken else { return nil }
        let body = "grant_type=refresh_token&client_id=\(Self.formEncoded(candidate.clientID))&refresh_token=\(Self.formEncoded(refreshToken))"
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = Self.trimmed(json["access_token"] as? String) else { return nil }

        let rotatedRefresh = Self.trimmed(json["refresh_token"] as? String) ?? refreshToken
        let idToken = Self.trimmed(json["id_token"] as? String) ?? candidate.idToken
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        if let vaultAccount {
            var credential = await MonitorCredentialVault.shared.credential(for: vaultAccount.id)
                ?? MonitorOAuthCredential(
                    accessToken: accessToken,
                    refreshToken: rotatedRefresh,
                    idToken: idToken,
                    accountID: vaultAccount.accountKey,
                    expiresAt: expiresAt,
                    extra: ["clientId": candidate.clientID]
                )
            credential.accessToken = accessToken
            credential.refreshToken = rotatedRefresh
            credential.idToken = idToken
            credential.expiresAt = expiresAt
            credential.extra["clientId"] = candidate.clientID
            do {
                try await MonitorCredentialVault.shared.save(credential, metadata: vaultAccount)
            } catch {
                Log.quota("Failed to persist refreshed Grok vault credential: \(error.localizedDescription)")
            }
        } else {
            do {
                try Self.persistRotatedCredential(
                    entryKey: candidate.entryKey,
                    accessToken: accessToken,
                    refreshToken: rotatedRefresh,
                    idToken: idToken,
                    expiresAt: expiresAt
                )
            } catch {
                Log.quota("Failed to persist refreshed Grok credential: \(error.localizedDescription)")
            }
        }
        return GrokAuthCandidate(
            entryKey: candidate.entryKey,
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            idToken: idToken,
            clientID: candidate.clientID,
            expiresAt: expiresAt
        )
    }

    nonisolated static func persistRotatedCredential(
        path: String = MonitorIdentity.expand(authPath),
        entryKey: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresAt: Date
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[entryKey] as? [String: Any] else {
            throw MonitorRuntimeError.invalidCredential
        }
        entry["key"] = accessToken
        if let refreshToken { entry["refresh_token"] = refreshToken }
        if let idToken { entry["id_token"] = idToken }
        entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        root[entryKey] = entry
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try SecureAtomicFileWriter.write(updated, to: url)
    }

    private nonisolated static func expiryDate(entry: [String: Any], token: String) -> Date? {
        for key in ["expires_at", "expires"] {
            guard let value = entry[key] as? String else { continue }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private nonisolated static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private nonisolated static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}
