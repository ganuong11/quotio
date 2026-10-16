//
//  OpencodeConsoleClient.swift
//  QuotioCore
//
//  Console API client for opencode device OAuth (Task 24 fills in the
//  methods). `defaultServer` lives here because the credential detector
//  already needs it for canonical server keys.
//

import Foundation

public enum OpencodeConsoleClient {
    /// The opencode console base URL.
    public static let defaultServer = "https://opencode.ai/console"
}
