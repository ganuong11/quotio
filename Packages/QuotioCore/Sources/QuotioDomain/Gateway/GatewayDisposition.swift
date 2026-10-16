import Foundation

/// Routing decision for a parsed gateway request. The front-door listener
/// resolves exactly one disposition per request before touching the upstream.
/// Today every request is `.passthrough` (byte-forwarded to the internal CPA
/// port); provider cases are added as the Qoder/OpenCode routers land.
public enum GatewayDisposition: Sendable, Equatable {
    case passthrough
    /// Intercepted `qoder/*` request — carries the resolved surface decision
    /// (chat / responses / rejected) for the dispatch layer.
    case qoder(QoderRoute)
    /// `GET /v1/models` — fetch CPA's list and merge provider catalogs.
    case modelsMerge
}
