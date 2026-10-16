import QuotioApplication
import QuotioDomain

extension AccountRowData {
    @MainActor var sourceLabel: String {
        if let sourceKind {
            switch sourceKind {
            case "amp_native": return "connections.source.amp".localized()
            case "claude_native": return "connections.source.claude".localized()
            case "kiro_native": return "connections.source.kiro".localized()
            case "codex_native": return "connections.source.codex".localized()
            case "cursor_native", "devin_desktop_native", "grok_native":
                return "monitor.source.localIDE".localized()
            case "factory_native": return "connections.source.factory".localized()
            case "antigravity_native": return "connections.source.antigravity".localized()
            case "quotio_custom_provider": return "connections.source.custom".localized()
            case "cli_proxy_auth_file": return "monitor.source.cliProxyFile".localized()
            default: break
            }
        }
        return source.displayName
    }
}

extension QuotaRefreshIssue {
    @MainActor var explanation: String {
        let key: String
        switch reason {
        case .authentication: key = "connections.failure.authentication"
        case .ownerRefreshRequired: key = "connections.failure.owner"
        case .sourceDisabled: key = "connections.failure.disabled"
        case .timeout, .transient: key = "connections.failure.network"
        case .rateLimited: key = "connections.failure.rateLimited"
        case .credentialStorage, .localCredentialStorage: key = "connections.failure.storage"
        case .unavailable: key = "connections.failure.unavailable"
        case .quotaUnavailable: key = "connections.failure.quota"
        case .invalidData: key = "connections.failure.invalidData"
        case .stale: key = "monitor.opencode.stale"
        case nil: key = "connections.failure.unknown"
        }
        return key.localized()
    }
}

extension NativeSourcePermission {
    var explanationLocalizationKey: String {
        switch (kind, location) {
        case ("antigravity_native", "gemini_keychain"):
            "providers.nativePermission.antigravity"
        case ("factory_native", _):
            "providers.nativePermission.factory"
        case ("claude_native", "code_keychain"):
            "providers.nativePermission.claude"
        default:
            "providers.nativePermission.message"
        }
    }
}
