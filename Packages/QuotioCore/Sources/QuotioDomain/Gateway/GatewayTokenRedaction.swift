import Foundation

/// Token redaction for log/error strings — replaces `pt-`/`jt-` runs (PAT and
/// job-token prefixes) with `pt-REDACTED`/`jt-REDACTED`. Single source shared
/// by the SSE reparser's error snippets and Task 14's PAT service.
public nonisolated enum GatewayTokenRedaction {
    public static func redactTokens(in text: String) -> String {
        let pattern = #"(pt|jt)-[A-Za-z0-9_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1-REDACTED")
    }
}
