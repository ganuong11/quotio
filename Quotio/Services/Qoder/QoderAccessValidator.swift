//
//  QoderAccessValidator.swift
//  Quotio
//
//  Mirrors CPA's `config_access` provider on the Qoder path (ADR 0008, issue
//  #21). The Qoder branch bypasses CPA's `AuthMiddleware` (ADR 0003), so
//  ProxyBridge owns API-key validation for `qoder/*` traffic. This validator
//  reproduces CPA's candidate-extraction and decision semantics exactly, so a
//  client that authenticates against CPA authenticates against the Qoder path
//  too (and vice versa) — no surprise 401 at the routing seam.
//
//  CPA source of truth (fetched for this port):
//    - `internal/access/config_access/provider.go` — five-source candidate list
//      and `extractBearerToken`.
//    - `sdk/access/errors.go` — `NewNoCredentialsError` / `NewInvalidCredentialError`
//      (both `http.StatusUnauthorized`, messages "Missing API key" /
//      "Invalid API key").
//    - `sdk/access/manager.go` — provider `Register`/`unregister` (empty key set
//      → provider unregistered → `AuthMiddleware` allows all requests: "legacy
//      behaviour").
//    - `internal/api/server_middleware.go` — request-time candidate evaluation
//      and the missing-vs-invalid decision.
//
//  See `docs/adr/0008-qoder-api-key-validation.md` for the full rationale
//  (including the rejected "strict Bearer-only" alternative).
//

import Foundation

/// Validates Qoder-path requests against CPA's `config_access` provider
/// semantics (ADR 0008, issue #21).
///
/// The Qoder branch of `ProxyBridge` bypasses CPA's `AuthMiddleware`, so this
/// actor owns API-key validation for `qoder/*` traffic. It mirrors CPA's
/// candidate-extraction and decision logic exactly:
///
/// 1. **Five candidate sources, in order**: `Authorization` (bearer-extracted),
///    `X-Goog-Api-Key`, `X-Api-Key`, `?key=`, `?auth_token=`. The first
///    candidate that matches a configured key passes — a WRONG earlier
///    candidate does not stop a later VALID one from passing.
/// 2. **`extractBearerToken`**: empty header → ""; no space → whole header;
///    non-`bearer` scheme (e.g. `"Basic abc"`) → whole header as-is; `bearer`
///    scheme (any case) → `TrimSpace(remainder)`.
/// 3. **Missing check keys off source presence**: if ALL FIVE sources are empty
///    → `.missing`. The subtlety: `Authorization: Bearer ` (empty suffix) has
///    a non-empty RAW header → NOT missing; the extracted candidate is "" and
///    gets skipped, and if nothing else matches the decision is `.invalid` (a
///    source was present). The query sources use the SAME unescaped
///    `Query().Get` value for presence and candidate (CPA does too), so a
///    malformed escape (`?key=sec%ZZet`) counts as absent for both. Mirrors
///    CPA's `NoCredentials` vs `InvalidCredential`.
/// 4. **Candidates present but no match** → `.invalid`.
/// 5. **Key normalization**: each configured key `TrimSpace`'d, empties dropped,
///    duplicates removed.
/// 6. **Empty key set → `.notConfigured`** (CPA: provider unregistered →
///    `AuthMiddleware` allows all requests — "legacy behaviour"). Quotio users
///    who never configured `api-keys` keep working.
/// 7. Header names are case-insensitive; the first occurrence of a duplicated
///    header wins. Query parsing mirrors Go's `r.URL.Query().Get`: pairs split
///    on `&`; name AND value are `QueryUnescape`d (`+` → space, `%XX` → byte),
///    so parameter names are percent-sensitive (`%6bey` matches `key`); a pair
///    whose name or value fails to unescape is DROPPED (Go's `parseQuery`
///    skips it; `Query()` swallows the error); first surviving matching pair
///    wins.
/// 8. **Primed state — fail closed before first reload.** The snapshot is
///    empty until the first successful `reload` on the `fetchAPIKeys` cadence.
///    Empty-and-UNPRIMED cannot mean "no api-keys configured" (open access) —
///    it means "keys unknown yet" — so `authenticate` returns `.notPrimed`
///    (503 via ProxyBridge) until primed. This closes the fail-open window
///    between proxy start and the first successful key fetch.
///
/// The validator holds a `Set<String>` snapshot reloaded on the existing
/// `ManagementAPIClient.fetchAPIKeys()` cadence (ADR 0008 point 4):
/// `authenticate(...)` runs entirely against the in-memory snapshot — no
/// per-request file I/O or network.
actor QoderAccessValidator {

    /// CPA-faithful authentication decision (ADR 0008). `Sendable` so it can
    /// cross the actor boundary back to the `@MainActor` request path.
    enum Decision: Equatable, Sendable {
        /// A candidate matched a configured key. The associated `principal` is
        /// the candidate value that matched (CPA: `result.Principal`). The
        /// Qoder path uses it downstream for session-ID derivation, exactly as
        /// CPA forwards it as `userApiKey`.
        case allowed(principal: String)
        /// No raw source present at all → 401 "Missing API key". Mirrors CPA's
        /// `NewNoCredentialsError`.
        case missing
        /// One or more candidates were present but none matched → 401 "Invalid
        /// API key". Mirrors CPA's `NewInvalidCredentialError`.
        case invalid
        /// The validator has not yet received its first key snapshot (`reload`
        /// has never succeeded). Fail CLOSED — the key set is unknown, not
        /// known-empty, so we must not treat this as open access. ProxyBridge
        /// maps this to 503. There is no CPA analogue: CPA loads its config
        /// keys before the server accepts a single request.
        case notPrimed
        /// Primed, but the configured key set is empty → pass through. Mirrors
        /// CPA's "provider unregistered → allow all" legacy behaviour. Quotio
        /// users who never configured `api-keys` keep working.
        case notConfigured
    }

    /// Normalized configured keys (TrimSpace'd, empties dropped, de-duplicated).
    /// Mutated only by `reload(keys:)`. A `Set` mirrors CPA's hash-set membership
    /// check; constant-time comparison (`constantTimeEquals`) is layered on top
    /// of the lookup so timing leakage from the proxy's in-process set is no
    /// worse than CPA's (ADR 0008 point 3).
    private var keys: Set<String> = []

    /// `true` once `reload(keys:)` has run at least once. Distinguishes
    /// "no api-keys configured" (primed + empty → open access, CPA parity)
    /// from "keys unknown yet" (unprimed → fail closed with `.notPrimed`).
    /// See the `.notPrimed` decision and `QuotaViewModel.startProxy` for the
    /// priming call.
    private(set) var isPrimed = false

    /// Replace the configured-key snapshot with a normalized version of `keys`
    /// and mark the validator primed (even for an empty list — an empty list
    /// is still a positive statement from CPA: "there are no api-keys").
    ///
    /// Called on the existing `fetchAPIKeys()` cadence from `QuotaViewModel`
    /// (ADR 0008 point 4) — an explicit priming call at proxy start, plus the
    /// periodic quota refresh and after every add/update/delete on the API
    /// Keys screen. Cheap and idempotent.
    ///
    /// - Parameter keys: The freshly fetched configured keys (raw, possibly with
    ///   whitespace / empties / duplicates — normalized here).
    func reload(keys: [String]) {
        self.keys = QoderAccessValidator.normalizeKeys(keys)
        self.isPrimed = true
    }

    /// Authenticate a request against the current snapshot. No I/O.
    ///
    /// - Parameters:
    ///   - path: The request path including its query string (e.g.
    ///     `/v1/chat/completions?key=secret`). Used for the `?key=` and
    ///     `?auth_token=` candidate sources.
    ///   - headers: The request headers as `(name, value)` pairs, in received
    ///     order (first occurrence wins for duplicates; names compared
    ///     case-insensitively).
    /// - Returns: The CPA-faithful `.allowed`/`.missing`/`.invalid`/
    ///   `.notConfigured` decision — or `.notPrimed` before the first reload.
    func authenticate(path: String, headers: [(String, String)]) -> Decision {
        // Fail closed before the first reload: an empty-and-unprimed snapshot
        // means "keys unknown yet", not "no api-keys configured" — the latter
        // is a positive statement from CPA and only valid once primed. Closes
        // the fail-open window between proxy start and the first successful
        // fetchAPIKeys (see Decision.notPrimed).
        guard isPrimed else {
            return .notPrimed
        }

        // ADR 0008 point 6 / CPA legacy behaviour: primed-but-empty key set →
        // provider unregistered → allow all requests. Short-circuit before any
        // candidate extraction so we never return `.missing`/`.invalid` for an
        // unconfigured validator (matches CPA exactly).
        if keys.isEmpty {
            return .notConfigured
        }

        // Extract the five candidates in CPA's fixed order. The construction
        // also reports whether ANY source was present — the missing-vs-invalid
        // distinction keys off source presence, not candidate matchability
        // (see `extractCandidates`). The CPA subtlety: `Authorization: Bearer
        // ` (empty suffix) is a PRESENT source even though its extracted
        // candidate is "" → not missing; the empty candidate is skipped below;
        // if nothing else matches → `.invalid`.
        let extraction = QoderAccessValidator.extractCandidates(path: path, headers: headers)
        if !extraction.anySourcePresent {
            return .missing
        }

        // First matching candidate wins (ADR 0008 point 1). A wrong earlier
        // candidate is simply skipped — it does not shadow a later valid one.
        for candidate in extraction.candidates {
            // Empty extracted candidates (e.g. `Authorization: Bearer ` with no
            // suffix) are not real candidates — they can neither match nor
            // contribute to the "candidate present" decision beyond the raw-
            // presence check above. CPA's provider skips empty candidates
            // silently in its membership scan.
            guard !candidate.isEmpty else { continue }
            for configured in keys where QoderAccessValidator.constantTimeEquals(candidate, configured) {
                return .allowed(principal: candidate)
            }
        }

        // At least one raw source was present (else we'd have returned .missing
        // above), but no candidate matched → CPA's `InvalidCredential`.
        return .invalid
    }

    // MARK: - Pure helpers (nonisolated, testable)

    /// Normalize a raw configured-keys list: `TrimSpace` each entry, drop
    /// empties, de-duplicate. Mirrors CPA's `config_access` provider setup.
    ///
    /// - Parameter keys: Raw keys as returned by `GET /api-keys`.
    /// - Returns: A normalized `Set<String>` (insertion-order-independent).
    nonisolated static func normalizeKeys(_ keys: [String]) -> Set<String> {
        var seen = Set<String>()
        for key in keys {
            // CPA uses Go's `strings.TrimSpace`, which trims all Unicode
            // whitespace including newlines. Swift's `.whitespacesAndNewlines`
            // is the closest match (`.whitespaces` alone would miss `\n`, `\r`).
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            // CPA drops empty configured keys (they cannot match anything
            // meaningfully and would otherwise make an "all empties" config look
            // like "configured").
            guard !trimmed.isEmpty else { continue }
            seen.insert(trimmed)
        }
        return seen
    }

    /// CPA's `extractBearerToken` (verbatim semantics from
    /// `internal/access/config_access/provider.go`).
    ///
    /// - If the header is empty → "".
    /// - If there is no space → return the whole header.
    /// - If the first space-delimited part (lowercased) is not `"bearer"` →
    ///   return the WHOLE header as-is (e.g. `"Basic abc"` → `"Basic abc"`).
    ///   This is what makes a bare token in `Authorization` a valid candidate.
    /// - If the scheme is `bearer` (any case) → `TrimSpace(remainder)`. Note
    ///   the remainder is everything after the first space, then trimmed — so
    ///   `"Bearer   secret"` → `"secret"` and `"Bearer "` → `""`.
    ///
    /// - Parameter header: The raw `Authorization` header value (or "").
    nonisolated static func extractBearerToken(_ header: String) -> String {
        if header.isEmpty { return "" }
        // Split on the FIRST space only — the remainder may itself contain
        // spaces (CPA does the same; the scheme is everything before the first
        // space, the token is everything after, then trimmed).
        guard let spaceIndex = header.firstIndex(of: " ") else {
            // No space → return the whole header. A bare token like "secret"
            // (no scheme) lands here and becomes a candidate as-is.
            return header
        }
        let scheme = header[header.startIndex..<spaceIndex]
        let remainder = header[header.index(after: spaceIndex)..<header.endIndex]
        if scheme.lowercased() == "bearer" {
            // `strings.TrimSpace` (CPA) trims all Unicode whitespace including
            // newlines — use `.whitespacesAndNewlines` for parity.
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Non-bearer scheme (e.g. "Basic"): CPA returns the whole header as-is.
        // That string can still match a configured key if the user literally
        // configured `"Basic abc"` as a key.
        return header
    }

    /// First value for a query parameter in `path`, or "" if absent. Faithful
    /// to CPA's `r.URL.Query().Get(name)` (Go `net/url`):
    ///   - pairs split on `&`; a `#` fragment terminates the query;
    ///   - name AND value are `QueryUnescape`d — `+` → space, `%XX` → the
    ///     byte — so parameter NAMES are percent-sensitive: `%6bey` matches
    ///     `key`;
    ///   - a pair whose name OR value fails to unescape is DROPPED entirely
    ///     (Go's `parseQuery` skips it after recording the error; `Query()`
    ///     swallows the error) — e.g. `?key=sec%ZZet` yields NO `key` source;
    ///   - first surviving matching pair wins.
    ///
    /// - Parameters:
    ///   - name: The query parameter name (matched AFTER unescaping, like Go).
    ///   - path: The full request path including query string.
    nonisolated static func queryValue(for name: String, in path: String) -> String {
        guard let queryStart = path.firstIndex(of: "?") else { return "" }
        let query = String(path[path.index(after: queryStart)..<path.endIndex])
        // Stop at the first `#` so a fragment doesn't pollute the parse (Go's
        // `url.Parse` never includes the fragment in RawQuery).
        let queryNoFragment: String
        if let hashIndex = query.firstIndex(of: "#") {
            queryNoFragment = String(query[query.startIndex..<hashIndex])
        } else {
            queryNoFragment = query
        }
        for pair in queryNoFragment.split(separator: "&", omittingEmptySubsequences: true) {
            // Split on the FIRST `=` only — the value may itself contain `=`.
            // A flag-style pair with no `=` (e.g. bare `?key`) yields empty
            // name + empty value in Go's parseQuery; neither can match a
            // non-empty parameter name, so skip.
            guard let eqIndex = pair.firstIndex(of: "=") else { continue }
            let rawName = String(pair[pair.startIndex..<eqIndex])
            let rawValue = String(pair[pair.index(after: eqIndex)..<pair.endIndex])
            // Go unescapes BOTH sides. A malformed escape on either side drops
            // the whole pair (parseQuery skips it) — this is what makes
            // `?key=sec%ZZet` read as "no key source" in CPA.
            guard let decodedName = unescapeGoQuery(rawName),
                  let decodedValue = unescapeGoQuery(rawValue) else {
                continue
            }
            guard decodedName == name else { continue }
            // First surviving occurrence wins (return immediately).
            return decodedValue
        }
        return ""
    }

    /// Go `url.QueryUnescape` approximation: `+` → space, then percent-decode
    /// the result. Returns `nil` on a malformed escape so callers can DROP the
    /// pair (Go's parseQuery behavior), unlike `removingPercentEncoding` on a
    /// pre-`+`-substituted string which would mis-decode `+` escapes.
    nonisolated static func unescapeGoQuery(_ value: String) -> String? {
        let plusSubstituted = value.replacingOccurrences(of: "+", with: " ")
        return plusSubstituted.removingPercentEncoding
    }

    /// The five-source candidate extraction result: the candidates in CPA's
    /// fixed order, plus whether ANY source was present at all (the
    /// missing-vs-invalid distinction, ADR 0008 point 3). Both come from one
    /// scan so the two checks are structurally unable to drift.
    ///
    /// Order (verbatim from `internal/access/config_access/provider.go`):
    /// 1. `Authorization` → `extractBearerToken` (presence = RAW header
    ///    non-empty — CPA checks the raw `authHeader` — so `Authorization:
    ///    Bearer ` is PRESENT even though its extracted candidate is "")
    /// 2. `X-Goog-Api-Key` (presence = candidate = header value)
    /// 3. `X-Api-Key` (presence = candidate = header value)
    /// 4. `?key=` (presence = candidate = `Query().Get("key")` — CPA uses the
    ///    SAME unescaped value for both, so a malformed escape like
    ///    `?key=sec%ZZet` reads as "" for BOTH: the source is absent, matching
    ///    CPA's "Missing API key" outcome)
    /// 5. `?auth_token=` (same semantics as `?key=`)
    ///
    /// Header lookup is case-insensitive; the FIRST occurrence of a duplicated
    /// header wins (matches Go's `http.Header.Get`, which CPA uses).
    nonisolated static func extractCandidates(
        path: String,
        headers: [(String, String)]
    ) -> (candidates: [String], anySourcePresent: Bool) {
        let authorization = firstHeaderValue(named: "Authorization", in: headers)
        let googKey = firstHeaderValue(named: "X-Goog-Api-Key", in: headers)
        let apiKey = firstHeaderValue(named: "X-Api-Key", in: headers)
        let queryKey = queryValue(for: "key", in: path)
        let authToken = queryValue(for: "auth_token", in: path)

        let candidates = [
            extractBearerToken(authorization),
            googKey,
            apiKey,
            queryKey,
            authToken,
        ]
        let anySourcePresent = !authorization.isEmpty
            || !googKey.isEmpty
            || !apiKey.isEmpty
            || !queryKey.isEmpty
            || !authToken.isEmpty
        return (candidates, anySourcePresent)
    }

    /// Case-insensitive header lookup returning the FIRST occurrence of `name`
    /// in `headers` (mirrors Go's `http.Header.Get`). Returns "" if absent.
    /// `headers` is the `(name, value)` array ProxyBridge threads through.
    nonisolated static func firstHeaderValue(
        named name: String,
        in headers: [(String, String)]
    ) -> String {
        let lower = name.lowercased()
        for (headerName, headerValue) in headers where headerName.lowercased() == lower {
            return headerValue
        }
        return ""
    }

    /// Constant-time string comparison (ADR 0008 point 3). CPA uses a hash-set
    /// for membership; we layer constant-time byte comparison on top so the
    /// proxy's in-process lookup does not leak which configured key matched via
    /// short-circuit timing. Compares the UTF-8 byte views: each byte's XOR
    /// difference is OR-accumulated into a `UInt8` so no difference can cancel
    /// out. Length inequality returns `false` immediately (length itself is
    /// not a secret worth hiding in this context, and a length check is needed
    /// to avoid indexing past either buffer).
    ///
    /// - Parameters:
    ///   - candidate: The request-supplied candidate value.
    ///   - configured: A configured key from the snapshot.
    nonisolated static func constantTimeEquals(_ candidate: String, _ configured: String) -> Bool {
        let lhs = Array(candidate.utf8)
        let rhs = Array(configured.utf8)
        if lhs.count != rhs.count { return false }
        // OR every per-byte XOR into the accumulator. MUST be OR, not XOR:
        // XOR is self-inverting, so two differing positions with equal
        // XOR-deltas would cancel back to zero and compare equal (e.g.
        // "ab" vs "ba" — pinned by testConstantTimeEqualsXorCancellation).
        // OR accumulates any difference irreversibly; equal strings produce
        // `diff == 0`. No intermediate branch short-circuits on the mismatch
        // location.
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }
}
