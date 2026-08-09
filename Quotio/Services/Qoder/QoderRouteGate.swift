//
//  QoderRouteGate.swift
//  Quotio
//
//  Endpoint/method gate for the Qoder branch (issue #20, ADR 0009).
//
//  ADR 0009 closes the gap-analysis P1 ("endpoint/method"): the Qoder branch
//  must be selected by a CONJUNCTIVE allowlist of (model prefix, method, path),
//  not by the body-`model:` prefix alone. A request with `model: "qoder/..."`
//  on `/v1/completions`, `/v1/embeddings`, a GET, or any other non-allowlisted
//  surface is unsafe to forward: the Qoder translator only knows Chat
//  Completions (and, since issue #11, Responses), and falling such a request
//  through to CPA is also unsafe — CPA does not know `qoder/` models (ADR 0003)
//  and a fallback rule could misroute the unknown model. The gate instead
//  rejects those requests with a Qoder-owned `404 model_not_found` envelope,
//  matching how CPA itself rejects unknown routes.
//
//  This helper is the single decision point for that gate. `ProxyBridge
//  .processRequest` consults `QoderRouteGate.resolve` where it previously
//  computed `isQoderBound` / `isResponsesEndpoint`, and acts on the result:
//    - `.chat` / `.responses` enter the Qoder branch (router-willing);
//    - `.rejected` short-circuits with `sendError(..., statusCode: 404, ...)`,
//      which `QoderOpenAIError.body` maps to `model_not_found` (ADR 0010);
//    - `.notQoder` falls through to CPA, unchanged.
//
//  ADR 0009 §Consequences anticipates the allowlist growing: issue #10
//  (`/v1/models` merge) and issue #11 (`/v1/responses` adapter) add entries.
//  #11 has landed — `/v1/responses` is already an allowed route here; excluding
//  it would regress #11. #10 has landed too — `GET /v1/models` is intercepted
//  separately in `ProxyBridge.processRequest` (ADR 0016), independent of this
//  gate, which still never matches it (no body model on a GET).
//
//  Pure value type — no I/O, no actor state. `nonisolated enum` with a single
//  static method so it opts out of the project's MainActor default and is
//  callable from any isolation domain (`processRequest` is `nonisolated`).
//  Matches the declaration style of `QoderModelRegistry` / `QoderOpenAIError`.
//

import Foundation

/// The Qoder-branch routing decision for one parsed HTTP request. Produced by
/// `QoderRouteGate.resolve`. Equatable + Sendable so it crosses the
/// `processRequest` (nonisolated) → MainActor Task boundary without ceremony
/// (Swift 6 strict concurrency).
nonisolated enum QoderRoute: Equatable, Sendable {
    /// `POST /v1/chat/completions` with a `qoder/` model — the canonical Qoder
    /// surface (ADR 0001). Routes to `QoderChatTranslator` via the failover
    /// router, responsesMode = false.
    case chat

    /// `POST /v1/responses` with a `qoder/` model — the Responses API surface
    /// (issue #11). Routes to `QoderResponsesTranslator.synthesizeChatBody`
    /// pre-router, then the Chat gateway core with responsesMode = true.
    case responses

    /// A `qoder/` model on any other method/path combination (e.g.
    /// `/v1/completions`, `/v1/embeddings`, a GET). Reject with a Qoder-owned
    /// `404 model_not_found` (ADR 0009); do NOT fall through to CPA.
    case rejected

    /// No `qoder/` model prefix (nil model, or any other provider's model).
    /// CPA passthrough — unchanged from the pre-#20 behavior.
    case notQoder
}

/// Pure decision helper for the Qoder branch's endpoint/method gate
/// (issue #20, ADR 0009).
///
/// `resolve` is the single source of truth for "does this request enter the
/// Qoder branch, and if so which adapter?" — every conjunct (model prefix,
/// method, path) lives here. Callers must strip nothing beforehand; the raw
/// parser surface (`method` from the request line, `path` including any query
/// string, `model` from the JSON body) is the intended input. The helper
/// strips the query itself before path comparison (see `pathWithoutQuery`).
nonisolated enum QoderRouteGate {

    /// The model prefix that opts a request into Qoder routing at all
    /// (ADR 0003 §1). Anything not starting with this string is `.notQoder`.
    static let qoderPrefix = "qoder/"

    /// The allowlisted paths, paired with the route they select. Order does
    /// not matter (paths are distinct); defined as a tuple list so adding the
    /// next entry (per ADR 0009 §Consequences) is a one-line change.
    static let allowedPaths: [(path: String, route: QoderRoute)] = [
        ("/v1/chat/completions", .chat),
        ("/v1/responses",        .responses),
    ]

    /// Resolve the Qoder routing decision for a parsed request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method from the request line, uppercase
    ///     (`HTTP1RequestParser` preserves client casing; OpenAI clients send
    ///     uppercase `POST`/`GET`). Comparison is case-sensitive — matching
    ///     the parser's casing and avoiding a silent `post`-lowercase accept.
    ///   - path: The request target from the request line. **May include a
    ///     query string** (`HTTP1RequestParser.parsedPath = requestLineParts[1]`
    ///     at HTTP1RequestParser.swift:406 captures the whole target), so
    ///     `POST /v1/chat/completions?timeout=30` must still match. The query
    ///     is stripped before comparison; the path comparison is otherwise
    ///     case-sensitive (paths are literal OpenAI routes, not patterns).
    ///   - model: The `model` field from the JSON body, if any. `nil` when the
    ///     body is absent, malformed, or omits `model` (ProxyBridge
    ///     `extractMetadata` returns nil in all those cases).
    /// - Returns: The routing decision. See `QoderRoute` cases for semantics.
    static func resolve(method: String, path: String, model: String?) -> QoderRoute {
        // ADR 0003 §1: the prefix test is the first conjunct. Nil model, empty
        // model, or any non-`qoder/` model short-circuits to CPA passthrough.
        // `hasPrefix` on `qoder/` (not `qoder`) matches the existing
        // `isQoderBound` semantics — a bare `qoder` (no slash) is not a Qoder
        // model. A bare `qoder/` prefix with empty ID is still Qoder-bound at
        // the gate's level; the gateway rejects unknown IDs upstream (ADR 0003
        // §Consequences, QoderModelRegistry drift).
        guard let model, model.hasPrefix(qoderPrefix) else {
            return .notQoder
        }

        // Only POST is allowlisted (ADR 0009). GET/PUT/DELETE/etc. with a
        // qoder/ model are `.rejected` — even on an otherwise-allowlisted path
        // (e.g. `GET /v1/chat/completions`). Case-sensitive to match parser
        // casing and avoid silently accepting a lowercase `post`.
        guard method == "POST" else {
            return .rejected
        }

        // Strip the query string before comparison. `HTTP1RequestParser`
        // captures the whole request target (path + ?query), so
        // `POST /v1/chat/completions?timeout=30` must still match
        // `/v1/chat/completions`. The bare `?` separator is RFC 7230's
        // request-target form; everything after the first `?` is the query.
        let pathOnly = pathWithoutQuery(path)

        // ADR 0009: the path must match the allowlist exactly. First match
        // wins; the list contains distinct literal paths, so ordering is
        // irrelevant. `allowedPaths` is small (two entries today) and the
        // linear scan compiles to nothing meaningful — a dictionary lookup
        // would complicate the route attachment without measurable benefit
        // at this size. An unknown path with a qoder/ model is `.rejected`.
        for entry in allowedPaths where entry.path == pathOnly {
            return entry.route
        }
        return .rejected
    }

    /// Return the path portion of a request target (everything before the
    /// first `?`). RFC 7230 §5.3 request-target = origin-form
    /// (absolute-path [ "?" query ]). The path itself cannot legally contain
    /// a literal `?` (it is percent-encoded as `%3F`), so `firstIndex(of: "?")`
    /// is a safe split. A target with no `?` returns itself unchanged.
    ///
    /// Visible to tests so the route matrix can pin the strip behavior on both
    /// sides of the helper without re-implementing it.
    static func pathWithoutQuery(_ target: String) -> String {
        if let question = target.firstIndex(of: "?") {
            return String(target[..<question])
        }
        return target
    }
}
