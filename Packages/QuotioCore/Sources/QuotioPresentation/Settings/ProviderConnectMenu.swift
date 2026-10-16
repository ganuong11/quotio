import QuotioApplication
import QuotioDomain
import SwiftUI

/// Connection methods offered by a provider, rendered as menu items.
struct ProviderConnectMenu: View {
    let provider: MonitoringProvider
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(AccountsSettingsScreenModel.self) private var model

    static func isConnectable(_ provider: MonitoringProvider) -> Bool {
        !provider.actions.isDisjoint(with: ["start_oauth", "add_api_key", "discover_native"])
            || provider.configDirectorySource != nil
            || provider.id == .qoder
    }

    var body: some View {
        if provider.actions.contains("start_oauth") {
            Button("settings.browserLogin".localized() + "…") {
                connect { model.sheet = .oauth(provider.id) }
            }
        }
        if provider.actions.contains("add_api_key") {
            Button("settings.addAPIKey".localized()) {
                connect { model.sheet = .apiKey(provider.id, nil) }
            }
        }
        if provider.id == .qoder {
            // PAT-paste onboarding, not OAuth or API key.
            Button("qoder.onboarding.title".localized() + "…") {
                connect { model.sheet = .qoderPAT }
            }
        }
        if provider.configDirectorySource != nil {
            Button("settings.localAccount.menu".localized()) {
                connect { model.sheet = .localAccount(provider.id) }
            }
        }
        if provider.actions.contains("discover_native") {
            Button("settings.rescan".localized()) {
                connect {
                    await accounts.rescanNativeAccounts(for: provider.id)
                    await controller.refresh(provider: provider.id)
                }
            }
            .disabled(accounts.discoveringProvider != nil)
            if accounts.failedDiscoveryProviders.contains(provider.id) {
                Text("settings.discoveryFailed".localized())
            }
            if let scanned = accounts.lastScannedAt[provider.id] {
                Text(String(format: "settings.lastScan".localized(), scanned.formatted(date: .abbreviated, time: .shortened)))
            }
        }
    }

    /// Choosing a connection method is an explicit request to monitor the provider.
    private func connect(_ action: @escaping @MainActor () async -> Void) {
        Task {
            if !controller.trackingPreferences.isEnabled(provider.id) {
                await controller.setProviderEnabled(true, provider: provider.id)
            }
            await action()
        }
    }
}
