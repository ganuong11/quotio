//
//  OpencodeModels.swift
//  QuotioCore
//
//  Gateway-owned value types for the opencode branch: a free model's id,
//  display name, and the upstream surface it is native to (ADR 0021).
//

import Foundation

/// The upstream protocol surface a model is native to (ADR 0021). Only
/// `chat` and `responses` have client-facing surfaces today; the others are
/// refused with 422 `unsupported_surface` and never advertised.
public nonisolated enum OpencodeSurface: String, Sendable, Codable, Equatable {
    case chat
    case responses
    case messages
    case gemini
    case mistral

    /// models.dev `provider.npm` → surface. Unknown/missing → `chat`: the
    /// provider-level default is `@ai-sdk/openai-compatible`, which is the
    /// chat surface.
    public init(npm: String?) {
        switch npm {
        case "@ai-sdk/openai": self = .responses
        case "@ai-sdk/anthropic": self = .messages
        case "@ai-sdk/google": self = .gemini
        case "@ai-sdk/mistral": self = .mistral
        default: self = .chat
        }
    }

    /// Whether Quotio can serve requests for a model with this native
    /// surface (passthrough or translation). Drives `/v1/models` filtering.
    public var isServable: Bool { self == .chat || self == .responses }
}

public nonisolated struct OpencodeFreeModel: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String?
    /// Native upstream surface. Nil only for pre-ADR-0021 persisted snapshots
    /// (resolved to `.chat` at lookup until the next refresh re-derives it).
    public let surface: OpencodeSurface?

    public init(id: String, displayName: String?, surface: OpencodeSurface? = nil) {
        self.id = id
        self.displayName = displayName
        self.surface = surface
    }
}

