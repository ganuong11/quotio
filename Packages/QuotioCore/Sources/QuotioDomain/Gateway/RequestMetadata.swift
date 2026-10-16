import Foundation

/// Per-request accounting record emitted by the gateway listener. Populated on
/// both the CPA passthrough path and the provider-intercept paths; the token
/// fields are filled by the Qoder branch from the SSE final chunk's `usage`
/// block (ADR 0005 §2) and stay nil on passthrough (CPA's own /usage endpoint
/// is the source of truth there — nil avoids double-counting).
public struct GatewayRequestMetadata: Sendable {
    public let timestamp: Date
    public let method: String
    public let path: String
    public let provider: String?
    public let model: String?
    public let resolvedModel: String?
    public let resolvedProvider: String?
    public let statusCode: Int?
    public let durationMs: Int
    public let requestSize: Int
    public let responseSize: Int
    public let responseSnippet: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?

    public init(
        timestamp: Date,
        method: String,
        path: String,
        provider: String?,
        model: String?,
        resolvedModel: String? = nil,
        resolvedProvider: String? = nil,
        statusCode: Int?,
        durationMs: Int,
        requestSize: Int,
        responseSize: Int,
        responseSnippet: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.provider = provider
        self.model = model
        self.resolvedModel = resolvedModel
        self.resolvedProvider = resolvedProvider
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.requestSize = requestSize
        self.responseSize = responseSize
        self.responseSnippet = responseSnippet
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}
