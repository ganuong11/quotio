import QuotioDomain
import SwiftUI

struct CLIProxySettingsPage: View {
    @Environment(ProxyScreenModel.self) private var proxy
    @Environment(SettingsScreenModel.self) private var settings
    @Environment(PlatformActionScreenModel.self) private var platform
    @Environment(PasteboardScreenModel.self) private var pasteboard
    @State private var portText = ""
    @State private var showVersions = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var clientAPIKeys: [String] = []
    @State private var modelCatalog = ModelCatalogState()
    @State private var copiedModelID: String?

    var body: some View {
        Form {
            if proxy.isBinaryInstalled {
                serverSection
                clientAPIKeysSection
                availableModelsSection
                configurationSection
                versionSection
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("CLIProxyAPI", systemImage: "network")
                            .font(.headline)
                        Text("settings.proxy.optional".localized())
                            .foregroundStyle(.secondary)
                        Button("settings.proxy.installAndRun".localized()) {
                            run {
                                try await proxy.downloadAndInstallBinary()
                                try await proxy.start()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }
            if proxy.isDownloading {
                ProgressView(value: proxy.downloadProgress)
            } else if working {
                ProgressView().controlSize(.small)
            }
            if let errorMessage = errorMessage ?? proxy.lastError {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .disabled(working)
        .navigationTitle("CLIProxyAPI")
        .onAppear { portText = String(proxy.port) }
        .onChange(of: proxy.port) { _, port in portText = String(port) }
        .task {
            await refreshClientAPIKeys()
            await refreshModels()
        }
        .onChange(of: proxy.proxyStatus.running) { _, _ in
            Task {
                await refreshClientAPIKeys()
                await refreshModels()
            }
        }
        .sheet(isPresented: $showVersions) { ProxyVersionManagerSheet() }
    }

    private var serverSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label((proxy.proxyStatus.running ? "status.running" : "status.stopped").localized(),
                          systemImage: proxy.proxyStatus.running ? "checkmark.circle.fill" : "stop.circle")
                        .font(.headline)
                        .foregroundStyle(proxy.proxyStatus.running ? Color.green : Color.secondary)
                    Spacer()
                    Button((proxy.proxyStatus.running ? "action.stop" : "action.start").localized(),
                           systemImage: proxy.proxyStatus.running ? "stop.fill" : "play.fill") {
                        run {
                            if proxy.proxyStatus.running { await proxy.stopAndWait() }
                            else { try await proxy.start() }
                        }
                    }
                    Button("action.restart".localized(), systemImage: "arrow.clockwise") {
                        run { try await proxy.restart() }
                    }
                    .disabled(!proxy.proxyStatus.running)
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.proxy.endpoint".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(proxy.baseURL + "/v1")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("action.copy".localized(), systemImage: "doc.on.doc") {
                        pasteboard.copy(proxy.baseURL + "/v1")
                    }
                    .labelStyle(.iconOnly)
                    .help("action.copy".localized())
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { managementActions }
                    VStack(alignment: .leading, spacing: 8) { managementActions }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var managementActions: some View {
        Button("settings.proxy.openManagement".localized(), systemImage: "arrow.up.right.square") {
            if let url = proxy.managementPageURL { platform.open(url) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!proxy.proxyStatus.running)
        Button("settings.proxy.copyKey".localized(), systemImage: "key") {
            pasteboard.copy(proxy.managementKey)
        }
        .disabled(proxy.managementKey.isEmpty)
    }

    private var clientAPIKeysSection: some View {
        Section {
            if clientAPIKeys.isEmpty {
                Text("apiKeys.emptyDescription".localized())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clientAPIKeys, id: \.self) { key in
                    HStack {
                        Text(maskedKey(key))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("action.copy".localized(), systemImage: "doc.on.doc") {
                            pasteboard.copy(key)
                        }
                        .labelStyle(.iconOnly)
                        .help("action.copy".localized())
                    }
                }
            }
        } header: {
            Text("settings.proxy.clientAPIKeys".localized())
        } footer: {
            Text("settings.proxy.apiKeysHint".localized())
        }
    }

    private struct ModelGroup: Identifiable {
        let owner: String
        let entries: [ModelCatalogEntry]
        var id: String { owner }
    }

    private var modelGroups: [ModelGroup] {
        Dictionary(grouping: modelCatalog.entries, by: { $0.displayOwner ?? "" })
            .map { ModelGroup(owner: $0.key, entries: $0.value) }
            .sorted {
                $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending
            }
    }

    private var availableModelsSection: some View {
        Section {
            if !proxy.proxyStatus.running {
                modelNoteRow(icon: "pause.circle", text: "availableModels.proxyStopped".localized())
            } else if modelCatalog.isLoading && !modelCatalog.hasCompletedFetch {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("availableModels.loading".localized())
                        .foregroundStyle(.secondary)
                }
            } else if modelCatalog.entries.isEmpty && modelCatalog.lastFetchFailed {
                modelNoteRow(icon: "exclamationmark.triangle", text: "availableModels.error".localized())
            } else if modelCatalog.isEmptyLiveResult {
                modelNoteRow(icon: "tray", text: "availableModels.empty".localized())
            } else if !modelCatalog.entries.isEmpty {
                catalogRows
            }
        } header: {
            Text("settings.proxy.availableModels".localized())
        } footer: {
            Text("settings.proxy.availableModelsHint".localized())
        }
    }

    @ViewBuilder
    private var catalogRows: some View {
        HStack {
            Text(String(format: "availableModels.modelCount".localized(), modelCatalog.entries.count))
                .foregroundStyle(.secondary)
            Spacer()
            RefreshButton(title: "action.refresh".localized(), isRefreshing: modelCatalog.isLoading) {
                await refreshModels()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("action.refresh".localized())
        }
        if case .stale(let fetchedAt) = modelCatalog.freshness {
            Label(
                String(format: "availableModels.stale".localized(),
                       fetchedAt.formatted(date: .omitted, time: .standard)),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
        ForEach(modelGroups) { group in
            DisclosureGroup {
                ForEach(group.entries) { entry in
                    modelRow(entry)
                }
            } label: {
                HStack {
                    Text(modelGroupLabel(group.owner))
                    Spacer()
                    Text("\(group.entries.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        HStack {
            Text(entry.id)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("action.copy".localized(), systemImage: copiedModelID == entry.id ? "checkmark" : "doc.on.doc") {
                pasteboard.copy(entry.id)
                copiedModelID = entry.id
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedModelID == entry.id { copiedModelID = nil }
                }
            }
            .labelStyle(.iconOnly)
            .help("action.copy".localized())
        }
    }

    private func modelNoteRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .foregroundStyle(.secondary)
    }

    private func modelGroupLabel(_ owner: String) -> String {
        guard !owner.isEmpty else { return "availableModels.otherOwner".localized() }
        return QuotaProvider(rawValue: owner)?.displayName ?? owner
    }

    private func refreshModels() async {
        guard proxy.proxyStatus.running else {
            modelCatalog.reset()
            return
        }
        modelCatalog.beginLoading()
        do {
            let entries = try await proxy.availableModels()
            modelCatalog.apply(entries: entries, fetchedAt: Date())
        } catch {
            modelCatalog.applyFailure()
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(6))••••••••\(key.suffix(4))"
    }

    private func refreshClientAPIKeys() async {
        clientAPIKeys = await proxy.clientAPIKeys()
    }

    private var configurationSection: some View {
        Section("settings.proxy.configuration".localized()) {
            LabeledContent("settings.proxy.port".localized()) {
                HStack(spacing: 8) {
                    TextField("settings.proxy.port".localized(), text: $portText)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 80)
                    Button("action.save".localized()) {
                        if let port = UInt16(portText), port > 0 { proxy.setPort(port) }
                    }
                    .disabled(UInt16(portText).map { $0 == 0 || $0 == proxy.port } ?? true)
                }
            }
            Toggle("settings.autoStartProxy".localized(), isOn: Binding(
                get: { settings.proxyPreferences.autoStartProxy },
                set: { settings.setAutoStartProxy($0) }
            ))
        }
    }

    private var versionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("settings.proxy.version".localized()).font(.headline)
                    Spacer()
                    Text(proxy.currentVersion ?? proxy.installedProxyVersion ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { versionActions }
                    VStack(alignment: .leading, spacing: 8) { versionActions }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var versionActions: some View {
        if let version = proxy.availableUpgrade {
            Button(String(format: "settings.proxy.updateTo".localized(), version.version)) {
                run { try await proxy.performManagedUpgrade(to: version) }
            }
        } else {
            Button("action.checkUpdates".localized(), systemImage: "arrow.clockwise") {
                run { await proxy.checkForUpgrade() }
            }
        }
        Button("settings.proxy.manageVersions".localized()) { showVersions = true }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            do { try await action() } catch { errorMessage = proxy.errorMessage(for: error) }
        }
    }
}
