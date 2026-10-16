//
//  OpencodeRouteGate.swift
//  Quotio
//
//  Endpoint/method gate for the opencode branch — the sibling of
//  QoderRouteGate (issue #20, ADR 0009) for the `opencode/` namespace.
//
//  The gate is the single decision point for whether a request enters the
//  opencode branch: a request only qualifies when ALL of (model prefix,
//  method, path) match and the resolved model is in the free-model set.
//  Anything else is either rejected (opencode/ model on an unknown or
//  non-POST surface) or passed through to CPA untouched (no opencode/
//  prefix). The hard request-time free-model check is what keeps paid
//  upstream models from leaking through the proxy: the catalog knows the
//  cost-zero set and the gate refuses everything outside it.
//
//  Both OpenAI surfaces are valid request surfaces for every free model —
//  the client picks `/v1/chat/completions` or `/v1/responses`. The upstream
//  TARGET is the model's native surface, resolved separately from the
//  catalog by the router (ADR 0021 surface dispatch); this gate only
//  decides whether the request enters the opencode branch at all.
//
//  The catalog lookup is injected as a closure so the gate stays pure and
//  synchronous — `ProxyBridge.processRequest` is nonisolated and cannot
//  await. The cold-start `isEmpty` decision (empty → 503 catalog-unavailable
//  vs filled → 404 model_not_found) is made at the call site, which can see
//  `OpencodeModelCatalog.shared.isEmpty` when the gate returns
//  `.notInFreeSet`.
//
//  Pure value type — no I/O, no actor state. `public nonisolated enum` so it opts
//  out of the project's MainActor default and is callable from any
//  isolation domain. Matches `QoderRouteGate`.
//

import Foundation

/// The opencode-branch routing decision for one parsed HTTP request.
public nonisolated enum OpencodeRoute: Equatable, Sendable {
    /// `POST /v1/chat/completions` with a free `opencode/` model — the
    /// client's surface; the upstream target is the model's native surface
    /// (ADR 0021).
    case chat

    /// `POST /v1/responses` with a free `opencode/` model — the client's
    /// surface; same ADR 0021 note as `.chat`.
    case responses

    /// Prefix + POST + allowlisted path all matched, but the model is not in
    /// the free set. Caller decides 503 catalog-unavailable (empty catalog)
    /// or 404 model_not_found (populated catalog).
    case notInFreeSet

    /// An `opencode/` model on a wrong method or path (GET, /v1/embeddings,
    /// …) — reject; do NOT fall through to CPA.
    case rejected

    /// No `opencode/` model prefix — CPA passthrough, unchanged.
    case notOpencode
}

public nonisolated enum OpencodeRouteGate {

    /// The model prefix that opts a request into opencode routing.
    public static let opencodePrefix = "opencode/"

    /// The allowlisted POST paths, paired with the route they select.
    public static let allowedPaths: [(path: String, route: OpencodeRoute)] = [
        ("/v1/chat/completions", .chat),
        ("/v1/responses",        .responses),
    ]

    /// Resolve the opencode routing decision for a parsed request.
    /// - Parameters:
    ///   - method: raw request-line method (compared case-sensitively,
    ///     matching HTTP1RequestParser's preserved casing).
    ///   - path: raw request target, may include `?query` (stripped here).
    ///   - model: the body's `model` field, or nil.
    ///   - isFreeModel: membership test for the stripped upstream id —
    ///     `OpencodeModelCatalog.shared.isFree` at the call site.
    public static func resolve(
        method: String, path: String, model: String?,
        isFreeModel: (String) -> Bool
    ) -> OpencodeRoute {
        guard let model, model.hasPrefix(opencodePrefix) else {
            return .notOpencode
        }
        guard method == "POST" else {
            return .rejected
        }
        let pathOnly = QoderRouteGate.pathWithoutQuery(path)
        guard let route = allowedPaths.first(where: { $0.path == pathOnly })?.route else {
            return .rejected
        }
        let strippedID = String(model.dropFirst(opencodePrefix.count))
        guard isFreeModel(strippedID) else {
            return .notInFreeSet
        }
        return route
    }
}
