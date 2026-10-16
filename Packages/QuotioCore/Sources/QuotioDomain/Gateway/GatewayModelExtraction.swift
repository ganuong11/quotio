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
