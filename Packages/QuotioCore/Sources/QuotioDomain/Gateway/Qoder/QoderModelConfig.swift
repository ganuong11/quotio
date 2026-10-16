import Foundation

// MARK: - Qoder-side model descriptor

/// Qoder-side model descriptor. Resolved upstream from the cached model
/// config; the translator does not look models up. `is_reasoning` flows
/// into `chat_context.extra.modelConfig`; `max_output_tokens` caps
/// `maxTokens`.
public nonisolated struct QoderModelConfig: Sendable, Equatable {
    public let key: String
    public let isReasoning: Bool
    public let maxOutputTokens: Int
    public let source: String

    public init(key: String, isReasoning: Bool, maxOutputTokens: Int, source: String) {
        self.key = key
        self.isReasoning = isReasoning
        self.maxOutputTokens = maxOutputTokens
        self.source = source
    }

    /// Safe default for unknown models, matching pi's fallback (max 32768,
    /// non-reasoning, system-sourced). Production callers resolve a real
    /// config; this is used when the catalog has no entry.
    public static let defaultUnknown = QoderModelConfig(
        key: "", isReasoning: false, maxOutputTokens: 32768, source: "system"
    )
}
