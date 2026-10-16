//
//  OpencodeDeviceAuthorizer.swift
//  QuotioCore
//
//  `OAuthAuthorizing` for the OpenCode Console device-code flow:
//  request code → prompt (verification URI + user code, auto-opened through
//  the `URLOpening` port) → poll until authorized → fetch identity →
//  `OpencodeAccountFactory` → vault. Mirrors the legacy coordinator's
//  `opencodeDeviceFlow`; the CPA-side authorizer cannot run this flow (the
//  console endpoints are Quotio-owned).
//

import Foundation
import QuotioApplication
import QuotioDomain

public actor OpencodeDeviceAuthorizer: OAuthAuthorizing {
    private let console: OpencodeConsoleClient
    private let urlOpener: any URLOpening
    private let credentials: any GatewayCredentialStoring
    private var cancelledAttempts: Set<OAuthAttemptID> = []

    public init(
        console: OpencodeConsoleClient = OpencodeConsoleClient(),
        urlOpener: any URLOpening,
        credentials: any GatewayCredentialStoring
    ) {
        self.console = console
        self.urlOpener = urlOpener
        self.credentials = credentials
    }

    public func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        guard request.providerID.rawValue == QuotaProvider.opencode.rawValue else {
            throw OAuthFlowFailure.unsupportedProvider
        }
        defer { cancelledAttempts.remove(attemptID) }
        do {
            let device = try await console.requestDeviceCode()
            guard let verificationURL = URL(string: device.verificationURIComplete) else {
                throw OAuthFlowFailure.invalidResponse
            }
            let prompt = OAuthPrompt(authorizationURL: verificationURL, userCode: device.userCode)
            await progress(prompt)
            if request.automaticallyOpensBrowser, !(await urlOpener.open(verificationURL)) {
                throw OAuthFlowFailure.browserOpenFailed
            }

            var interval = max(5, device.interval)
            let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
            while Date() < deadline {
                try Task.checkCancellation()
                if cancelledAttempts.contains(attemptID) { throw CancellationError() }
                try await Task.sleep(for: .seconds(interval))
                switch try await console.pollDeviceToken(deviceCode: device.deviceCode) {
                case .pending:
                    continue
                case .slowDown:
                    interval += 5
                    continue
                case .denied:
                    throw OAuthFlowFailure.expired
                case .authorized(let accessToken, let refreshToken, let expiresIn, let orgID):
                    let identity = try await console.fetchIdentity(accessToken: accessToken, orgID: orgID)
                    let (account, credential) = OpencodeAccountFactory.makeAccount(
                        identity: identity,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiresIn: expiresIn
                    )
                    try await credentials.store(credential, account: account)
                    return .completed(surfaceAccount(for: account))
                }
            }
            throw OAuthFlowFailure.expired
        } catch let failure as OAuthFlowFailure {
            await cancel(attemptID: attemptID)
            throw failure
        } catch is CancellationError {
            await cancel(attemptID: attemptID)
            throw OAuthFlowFailure.expired
        } catch {
            await cancel(attemptID: attemptID)
            throw OAuthFlowFailure.provider(Self.errorCode(error))
        }
    }

    public func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        throw OAuthFlowFailure.unsupportedProvider
    }

    public func cancel(attemptID: OAuthAttemptID) async {
        cancelledAttempts.insert(attemptID)
    }

    /// The surfaced `Account` row for a freshly onboarded gateway account.
    private func surfaceAccount(for account: GatewayAccount) -> Account {
        Account.make(
            providerID: AccountProviderID(rawValue: QuotaProvider.opencode.rawValue),
            accountKey: account.accountKey,
            displayName: account.displayName,
            source: .quotioKeychain,
            credentialReference: "keychain",
            capabilities: [.disable, .delete],
            status: .ready
        )
    }

    private static func errorCode(_ error: Error) -> String {
        if let consoleError = error as? OpencodeConsoleError {
            switch consoleError {
            case .unauthorized: return "unauthorized"
            case .invalidResponse: return "invalid_response"
            case .invalidGrant: return "invalid_grant"
            case .httpStatus(let status, _): return "http_\(status)"
            }
        }
        return "opencode_console_error"
    }
}

