import CryptoKit
import Foundation

/// Fingerprint and credential-file helpers shared by the gateway providers.
/// Port of the legacy monitor identity helpers.
public nonisolated enum GatewayIdentity {
    public static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20).description
    }

    public static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    public static func json(at path: String) -> [String: Any]? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    public static func jwtString(_ token: String?, claim: String) -> String? {
        jwtPayload(token)?[claim] as? String
    }

    public static func jwtNestedString(_ token: String?, namespace: String, claim: String) -> String? {
        (jwtPayload(token)?[namespace] as? [String: Any])?[claim] as? String
    }

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension String {
    /// Trims surrounding whitespace; `nil` when nothing is left. Shared by the
    /// gateway adapters that sanitize third-party credential-store fields.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
