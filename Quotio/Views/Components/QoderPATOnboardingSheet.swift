//
//  QoderPATOnboardingSheet.swift
//  Quotio
//
//  Two-step Qoder onboarding per ADR 0006 §3:
//    1. paste a Personal Access Token (`pt-…`)
//    2. confirm the resolved identity (email/name/userID) before saving
//
//  Networking and Vault access live on the view-model (AGENTS.md: no networking
//  in views); this sheet is pure presentation. The exchange step calls
//  `viewModel.exchangeQoderPAT(_:)`, the confirm step calls
//  `viewModel.saveQoderAccount(from:)`. CN-region PATs are rejected implicitly
//  by the global endpoint (ADR 0006) and surface here as an upstream error,
//  not a special case.
//

import SwiftUI

struct QoderPATOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel

    /// Called when the sheet fully completes its work (after the save step),
    /// so the presenter can dismiss + refresh.
    var onComplete: () -> Void = {}

    @State private var step: Step = .pastePAT
    @State private var pat: String = ""
    @State private var exchangeResult: QoderPATResult?
    @State private var errorMessage: String?
    @State private var isWorking = false

    private enum Step {
        case pastePAT
        case confirmIdentity
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch step {
                case .pastePAT:
                    pasteStep
                case .confirmIdentity:
                    if let result = exchangeResult {
                        confirmStep(for: result)
                    } else {
                        // Defensive: state out of sync — bounce back to step 1.
                        pasteStep
                            .onAppear { step = .pastePAT }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            footer
        }
        .frame(width: 450)
        .focusEffectDisabled()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            ProviderIcon(provider: .qoder, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("qoder.onboarding.title".localized())
                    .font(.headline)
                Text("qoder.onboarding.subtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 1: paste PAT

    private var pasteStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("qoder.onboarding.patLabel".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField("qoder.onboarding.patPlaceholder".localized(), text: $pat)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                    .onChange(of: pat) { _, _ in
                        if errorMessage != nil { errorMessage = nil }
                    }
                Text("qoder.onboarding.pasteHint".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Step 2: confirm identity

    private func confirmStep(for result: QoderPATResult) -> some View {
        let identity = result.identity
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("qoder.onboarding.confirmTitle".localized())
                    .font(.subheadline.weight(.semibold))
                Text("qoder.onboarding.confirmSubtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                if !identity.name.isEmpty {
                    identityRow(label: "qoder.onboarding.confirmName", value: identity.name)
                }
                if !identity.email.isEmpty {
                    identityRow(label: "qoder.onboarding.confirmEmail", value: identity.email)
                }
                identityRow(label: "qoder.onboarding.confirmUserID", value: identity.userID)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
    }

    private func identityRow(label key: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.localized())
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step == .confirmIdentity {
                Button("qoder.onboarding.back".localized()) {
                    errorMessage = nil
                    step = .pastePAT
                }
                .disabled(isWorking)
            }
            Spacer()
            Button("action.cancel".localized(), role: .cancel) {
                dismiss()
            }
            .disabled(isWorking)
            primaryButton
        }
        .padding(20)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .pastePAT:
            Button {
                Task { await exchange() }
            } label: {
                if isWorking {
                    SmallProgressView()
                } else {
                    Text("qoder.onboarding.connect".localized())
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AIProvider.qoder.color)
            .disabled(!canExchange || isWorking)
        case .confirmIdentity:
            Button {
                Task { await save() }
            } label: {
                if isWorking {
                    SmallProgressView()
                } else {
                    Text("qoder.onboarding.save".localized())
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AIProvider.qoder.color)
            .disabled(isWorking)
        }
    }

    private var canExchange: Bool {
        let trimmed = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("pt-") && trimmed.count > "pt-".count
    }

    // MARK: - Actions

    /// Step 1 → 2. On failure, surface the upstream error verbatim
    /// (`QoderPATError.errorDescription` is already redacted of secrets) and
    /// stay on the paste step so the user can re-paste. PAT is preserved.
    private func exchange() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await viewModel.exchangeQoderPAT(pat)
            exchangeResult = result
            errorMessage = nil
            step = .confirmIdentity
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Step 2 → save. On duplicate-account, surface the localized message but
    /// stay on the confirm step (the user can go back and re-paste a different
    /// PAT, or cancel). On success, hand control back to the presenter.
    private func save() async {
        guard let result = exchangeResult else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await viewModel.saveQoderAccount(from: result)
            onComplete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Preview

#Preview {
    QoderPATOnboardingSheet()
        .environment(QuotaViewModel())
}
