import Foundation

nonisolated enum MonitorToCLIProxyAuthExporter {
    struct BuiltAuthFile: Sendable, Equatable {
        let filename: String
        let data: Data
    }

    struct ExportResult: Sendable, Equatable {
        var exported: Int = 0
        var skippedExisting: Int = 0
        var skippedMissingCredential: Int = 0
        var skippedUnsupported: Int = 0
    }

    struct ExistingAuthIdentity: Hashable, Sendable {
        let provider: AIProvider
        let identity: String
    }

    /// Build CLIProxyAPI-compatible auth file bytes. Returns nil if provider unsupported.
    static func buildAuthFile(
        account: MonitorAccount,
        credential: MonitorOAuthCredential
    ) -> BuiltAuthFile? {
        guard let type = cliProxyType(for: account.provider),
              let prefix = filenamePrefix(for: account.provider) else {
            return nil
        }
        let key = sanitizeFilenameComponent(account.accountKey)
        guard !key.isEmpty else { return nil }

        var json: [String: Any] = [
            "type": type,
            "access_token": credential.accessToken,
            "disabled": false,
        ]
        if let refresh = credential.refreshToken, !refresh.isEmpty {
            json["refresh_token"] = refresh
        }

        switch account.provider {
        case .copilot:
            json["login"] = account.accountKey
            json["username"] = account.accountKey
            json["token_type"] = "bearer"
        case .kiro:
            json["email"] = account.accountKey
            json["auth_method"] = credential.extra["authMethod"] ?? "IdC"
            if let clientID = credential.extra["clientId"] { json["client_id"] = clientID }
            if let clientSecret = credential.extra["clientSecret"] { json["client_secret"] = clientSecret }
            json["region"] = credential.extra["region"] ?? "us-east-1"
            json["start_url"] = credential.extra["startUrl"] ?? "https://view.awsapps.com/start"
            if let expiresAt = credential.expiresAt {
                json["expires_at"] = iso8601String(expiresAt)
            }
        case .codex:
            if account.accountKey.contains("@") { json["email"] = account.accountKey }
            if let idToken = credential.idToken { json["id_token"] = idToken }
            if let accountID = credential.accountID { json["account_id"] = accountID }
            if let expiresAt = credential.expiresAt {
                json["expired"] = iso8601String(expiresAt)
            }
        case .grok:
            if account.accountKey.contains("@") { json["email"] = account.accountKey }
            if let idToken = credential.idToken { json["id_token"] = idToken }
            if let expiresAt = credential.expiresAt {
                json["expired"] = iso8601String(expiresAt)
            }
        default:
            json["email"] = account.accountKey
            if let expiresAt = credential.expiresAt {
                json["expired"] = iso8601String(expiresAt)
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return BuiltAuthFile(filename: "\(prefix)\(key).json", data: data)
    }

    static func exportMissingAccounts(
        authDir: String = NSString(string: "~/.cli-proxy-api").expandingTildeInPath,
        store: any MonitorCredentialStore = MonitorCredentialVault.shared,
        accounts: [MonitorAccount]? = nil,
        fileManager: FileManager = .default
    ) async throws -> ExportResult {
        var result = ExportResult()
        try fileManager.createDirectory(
            atPath: authDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var existing = loadExistingIdentities(authDir: authDir, fileManager: fileManager)
        // Default: discovery (keychain + native). Tests inject an explicit list.
        let accountList = if let accounts {
            accounts
        } else {
            await MonitorAccountDiscovery(vault: store).discover()
        }

        for account in accountList {
            guard !account.isDisabled else { continue }
            guard account.source == .quotioKeychain || account.source == .nativeCredential else { continue }
            guard cliProxyType(for: account.provider) != nil else {
                result.skippedUnsupported += 1
                continue
            }

            let identity = normalizeIdentity(account.accountKey)
            if existing.contains(ExistingAuthIdentity(provider: account.provider, identity: identity)) {
                result.skippedExisting += 1
                continue
            }

            guard let credential = await resolveCredential(account: account, store: store) else {
                result.skippedMissingCredential += 1
                continue
            }
            guard let built = buildAuthFile(account: account, credential: credential) else {
                result.skippedUnsupported += 1
                continue
            }

            let url = URL(fileURLWithPath: authDir).appendingPathComponent(built.filename)
            // Defense: never overwrite even if identity match missed
            if fileManager.fileExists(atPath: url.path) {
                result.skippedExisting += 1
                continue
            }

            try SecureAtomicFileWriter.write(built.data, to: url)
            result.exported += 1
            existing.insert(ExistingAuthIdentity(provider: account.provider, identity: identity))
        }

        if result.exported > 0 || result.skippedExisting > 0 {
            Log.proxy(
                "Monitor→CLIProxy export: exported=\(result.exported) skippedExisting=\(result.skippedExisting) missingCred=\(result.skippedMissingCredential) unsupported=\(result.skippedUnsupported)"
            )
        }
        return result
    }

    static func writeAuthFile(
        account: MonitorAccount,
        credential: MonitorOAuthCredential,
        authDir: String = NSString(string: "~/.cli-proxy-api").expandingTildeInPath,
        overwrite: Bool = false,
        fileManager: FileManager = .default
    ) throws {
        guard let built = buildAuthFile(account: account, credential: credential) else { return }
        let url = URL(fileURLWithPath: authDir).appendingPathComponent(built.filename)
        try fileManager.createDirectory(
            atPath: authDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !overwrite, fileManager.fileExists(atPath: url.path) { return }
        try SecureAtomicFileWriter.write(built.data, to: url)
    }

    static func resolveCredential(
        account: MonitorAccount,
        store: any MonitorCredentialStore
    ) async -> MonitorOAuthCredential? {
        switch account.source {
        case .quotioKeychain:
            return await store.credential(for: account.id)
        case .nativeCredential:
            return loadNativeOAuthCredential(account)
        default:
            return nil
        }
    }

    /// Read tokens from a native CLI/IDE credential path or keychain reference.
    static func loadNativeOAuthCredential(_ account: MonitorAccount) -> MonitorOAuthCredential? {
        guard let ref = account.credentialReference, !ref.isEmpty else { return nil }

        if ref.hasPrefix("keychain:") {
            return loadNativeKeychainCredential(ref: String(ref.dropFirst("keychain:".count)), account: account)
        }

        if account.provider == .grok, let hash = ref.firstIndex(of: "#") {
            let path = String(ref[..<hash])
            let entryKey = String(ref[ref.index(after: hash)...])
            guard let candidate = GrokQuotaFetcher.loadCandidates(path: path).first(where: { $0.entryKey == entryKey }) else {
                return nil
            }
            return MonitorOAuthCredential(
                accessToken: candidate.accessToken,
                refreshToken: candidate.refreshToken,
                idToken: candidate.idToken,
                accountID: nil,
                expiresAt: candidate.expiresAt,
                extra: [:]
            )
        }

        return loadNativeFileCredential(path: ref, account: account)
    }

    private static func loadNativeKeychainCredential(ref: String, account: MonitorAccount) -> MonitorOAuthCredential? {
        if ref == "Codex Auth" {
            guard let data = KeychainHelper.readExternalCredential(service: "Codex Auth"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return credentialFromCodexJSON(json)
        }
        if ref == "Claude Code-credentials" {
            guard let data = KeychainHelper.readExternalCredential(service: "Claude Code-credentials"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return credentialFromClaudeJSON(json)
        }
        if ref == "gemini:antigravity" {
            return credentialFromAntigravityKeychain()
        }
        if ref == "gh:github.com" {
            guard let data = KeychainHelper.readExternalCredential(service: "gh:github.com"),
                  let token = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else { return nil }
            return MonitorOAuthCredential(
                accessToken: token,
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: nil,
                extra: [:]
            )
        }
        return nil
    }

    private static func loadNativeFileCredential(path: String, account: MonitorAccount) -> MonitorOAuthCredential? {
        switch account.provider {
        case .codex:
            guard let json = MonitorIdentity.json(at: path) else { return nil }
            return credentialFromCodexJSON(json)
        case .claude:
            guard let json = MonitorIdentity.json(at: path) else { return nil }
            return credentialFromClaudeJSON(json)
        case .gemini:
            guard let json = MonitorIdentity.json(at: path),
                  let access = nonEmpty(json["access_token"] as? String) else { return nil }
            let expiry: Date?
            if let ms = json["expiry_date"] as? Double {
                expiry = Date(timeIntervalSince1970: ms / 1000)
            } else {
                expiry = nil
            }
            return MonitorOAuthCredential(
                accessToken: access,
                refreshToken: json["refresh_token"] as? String,
                idToken: json["id_token"] as? String,
                accountID: nil,
                expiresAt: expiry,
                extra: [:]
            )
        case .kiro:
            guard let json = MonitorIdentity.json(at: path),
                  let access = nonEmpty(json["accessToken"] as? String ?? json["access_token"] as? String)
            else { return nil }
            var extra: [String: String] = [:]
            if let v = json["authMethod"] as? String ?? json["auth_method"] as? String { extra["authMethod"] = v }
            if let v = json["clientId"] as? String ?? json["client_id"] as? String { extra["clientId"] = v }
            if let v = json["clientSecret"] as? String ?? json["client_secret"] as? String { extra["clientSecret"] = v }
            if let v = json["region"] as? String { extra["region"] = v }
            if let v = json["startUrl"] as? String ?? json["start_url"] as? String { extra["startUrl"] = v }
            if let v = json["profileArn"] as? String { extra["profileArn"] = v }
            let expiresAt = parseFlexibleDate(
                json["expiresAt"] as? String ?? json["expires_at"] as? String
            )
            return MonitorOAuthCredential(
                accessToken: access,
                refreshToken: json["refreshToken"] as? String ?? json["refresh_token"] as? String,
                idToken: nil,
                accountID: nil,
                expiresAt: expiresAt,
                extra: extra
            )
        case .copilot:
            guard let token = firstCopilotToken(in: path) else { return nil }
            return MonitorOAuthCredential(
                accessToken: token,
                refreshToken: nil,
                idToken: nil,
                accountID: nil,
                expiresAt: nil,
                extra: [:]
            )
        case .grok:
            // Whole-file path without #entry — first candidate
            guard let candidate = GrokQuotaFetcher.loadCandidates(path: path).first else { return nil }
            return MonitorOAuthCredential(
                accessToken: candidate.accessToken,
                refreshToken: candidate.refreshToken,
                idToken: candidate.idToken,
                accountID: nil,
                expiresAt: candidate.expiresAt,
                extra: [:]
            )
        default:
            return nil
        }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func credentialFromCodexJSON(_ json: [String: Any]) -> MonitorOAuthCredential? {
        let tokens = (json["tokens"] as? [String: Any]) ?? json
        guard let access = nonEmpty(tokens["access_token"] as? String) else { return nil }
        let idToken = tokens["id_token"] as? String
        let accountID = (tokens["account_id"] as? String)
            ?? MonitorIdentity.jwtNestedString(idToken, namespace: "https://api.openai.com/auth", claim: "chatgpt_account_id")
        return MonitorOAuthCredential(
            accessToken: access,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: idToken,
            accountID: accountID,
            expiresAt: nil,
            extra: [:]
        )
    }

    private static func credentialFromClaudeJSON(_ json: [String: Any]) -> MonitorOAuthCredential? {
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let access = nonEmpty(oauth["accessToken"] as? String ?? oauth["access_token"] as? String) else {
            return nil
        }
        let expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double ?? oauth["expires_at"] as? Double {
            // Claude stores ms epoch when numeric
            expiresAt = Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        } else if let text = oauth["expiresAt"] as? String ?? oauth["expires_at"] as? String {
            expiresAt = parseFlexibleDate(text)
        } else {
            expiresAt = nil
        }
        return MonitorOAuthCredential(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String ?? oauth["refresh_token"] as? String,
            idToken: nil,
            accountID: nil,
            expiresAt: expiresAt,
            extra: [:]
        )
    }

    private static func credentialFromAntigravityKeychain() -> MonitorOAuthCredential? {
        guard let data = KeychainHelper.readExternalCredential(service: "gemini", account: "antigravity"),
              var raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            let encoded = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let decoded = Data(base64Encoded: encoded),
                  let text = String(data: decoded, encoding: .utf8) else { return nil }
            raw = text
        }
        if let data = raw.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let token = (root["token"] as? [String: Any]) ?? root
            guard let access = nonEmpty(token["access_token"] as? String ?? token["accessToken"] as? String) else {
                return nil
            }
            let expiryText = token["expiry"] as? String ?? token["expires_at"] as? String ?? token["expiresAt"] as? String
            return MonitorOAuthCredential(
                accessToken: access,
                refreshToken: token["refresh_token"] as? String ?? token["refreshToken"] as? String,
                idToken: nil,
                accountID: nil,
                expiresAt: parseFlexibleDate(expiryText),
                extra: [:]
            )
        }
        return MonitorOAuthCredential(
            accessToken: raw,
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
    }

    private static func firstCopilotToken(in path: String) -> String? {
        if path.hasSuffix(".yml") || path.hasSuffix(".yaml"),
           let yaml = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in yaml.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "oauth_token" else { continue }
                let token = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }
            return nil
        }
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var tokens: [String] = []
        collectCopilotTokens(from: object, into: &tokens)
        return tokens.first
    }

    private static func collectCopilotTokens(from value: Any, into tokens: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if ["oauth_token", "oauthToken", "access_token"].contains(key),
                   let token = child as? String,
                   !token.isEmpty {
                    tokens.append(token)
                } else {
                    collectCopilotTokens(from: child, into: &tokens)
                }
            }
        } else if let array = value as? [Any] {
            for child in array { collectCopilotTokens(from: child, into: &tokens) }
        }
    }

    private static func parseFlexibleDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        if let ms = Double(raw) {
            return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
        }
        return nil
    }

    static func cliProxyType(for provider: AIProvider) -> String? {
        switch provider {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini-cli"
        case .antigravity: return "antigravity"
        case .copilot: return "github-copilot"
        case .kiro: return "kiro"
        case .grok: return "xai"
        default: return nil
        }
    }

    static func filenamePrefix(for provider: AIProvider) -> String? {
        switch provider {
        case .claude: return "claude-"
        case .codex: return "codex-"
        case .gemini: return "gemini-cli-"
        case .antigravity: return "antigravity-"
        case .copilot: return "github-copilot-"
        case .kiro: return "kiro-"
        case .grok: return "xai-"
        default: return nil
        }
    }

    static func sanitizeFilenameComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let banned = CharacterSet(charactersIn: "/\\:\0")
        return trimmed.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) }.map(String.init).joined()
    }

    static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func normalizeIdentity(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func loadExistingIdentities(authDir: String, fileManager: FileManager) -> Set<ExistingAuthIdentity> {
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else {
            return []
        }
        var result: Set<ExistingAuthIdentity> = []
        for file in files where file.hasSuffix(".json") {
            let path = (authDir as NSString).appendingPathComponent(file)
            guard let data = fileManager.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  let provider = mapTypeToProvider(type) else {
                continue
            }
            let identity: String
            if let email = json["email"] as? String, !email.isEmpty {
                identity = normalizeIdentity(email)
            } else if let login = json["login"] as? String, !login.isEmpty {
                identity = normalizeIdentity(login)
            } else if let username = json["username"] as? String, !username.isEmpty {
                identity = normalizeIdentity(username)
            } else if let stem = filenameIdentity(file, provider: provider) {
                identity = normalizeIdentity(stem)
            } else {
                continue
            }
            result.insert(ExistingAuthIdentity(provider: provider, identity: identity))
        }
        return result
    }

    static func mapTypeToProvider(_ type: String) -> AIProvider? {
        switch type.lowercased() {
        case "antigravity": return .antigravity
        case "claude": return .claude
        case "codex": return .codex
        case "copilot", "github-copilot": return .copilot
        case "gemini", "gemini-cli": return .gemini
        case "kiro": return .kiro
        case "xai", "grok": return .grok
        default: return nil
        }
    }

    static func filenameIdentity(_ filename: String, provider: AIProvider) -> String? {
        guard let prefix = filenamePrefix(for: provider),
              filename.hasPrefix(prefix),
              filename.hasSuffix(".json") else {
            return nil
        }
        let start = prefix.endIndex
        let end = filename.index(filename.endIndex, offsetBy: -5) // .json
        guard start < end else { return nil }
        return String(filename[start..<end])
    }
}
