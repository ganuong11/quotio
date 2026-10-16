import Foundation

/// Body-model extraction shared by the gateway route gates.
/// Content-type-agnostic by construction: it takes only the body bytes and
/// never reads headers, so the gate sees the same model regardless of the
/// client's declared Content-Type. Port of `ProxyBridge.extractModel` (the
/// listener uses it in `processRequest` metadata extraction).
public nonisolated enum GatewayModelExtraction {
    public static func extractModel(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }
}

/// Parses `stream_options.include_usage` from a request body. Only a genuine
/// JSON boolean true counts — numeric 1/0 or a numeric-looking string is not
/// an opt-in.
public nonisolated enum GatewayIncludeUsageFlag {
    public static func flag(in body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let streamOptions = json["stream_options"] as? [String: Any] else {
            return false
        }
        guard let value = streamOptions["include_usage"] as? NSNumber else {
            return false
        }
        return strcmp(value.objCType, "c") == 0 && value.boolValue
    }
}
