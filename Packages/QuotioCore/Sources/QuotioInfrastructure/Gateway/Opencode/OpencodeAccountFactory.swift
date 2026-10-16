//
//  OpencodeAccountFactory.swift
//  QuotioCore
//
//  Maps a console identity + token set to the canonical gateway account:
//  accountKey = console userID (stable across email changes), displayName =
//  email, org/server stashed in credential extras for the router.
//

import Foundation
import QuotioDomain

public nonisolated enum OpencodeAccountFactory {
    public static func makeAccount(
        identity: OpencodeIdentity,
        accessToken: String,
        refreshToken: String,
        expiresIn: Int,
        server: String = OpencodeConsoleClient.defaultServer
    ) -> (GatewayAccount, GatewayCredential) {
        let account = GatewayAccount.make(
            provider: .opencode,
            accountKey: identity.userID,
            displayName: identity.email,
            source: .onboarded,
            email: identity.email
        )
        var extra: [String: String] = ["server": server]
        if let orgID = identity.orgID { extra["orgID"] = orgID }
        if let orgName = identity.orgName { extra["orgName"] = orgName }
        let credential = GatewayCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: nil,
            accountID: identity.userID,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            extra: extra
        )
        return (account, credential)
    }
}
