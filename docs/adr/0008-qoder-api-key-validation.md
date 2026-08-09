# Qoder path validates API keys via a CPA-mirrored access validator

## Context

The Qoder branch bypasses CPA's `AuthMiddleware` (ADR 0003 — only `qoder/*`
traffic takes the native COSY path; everything else forwards to CPA). Until now
that meant the Qoder path validated only that the `Authorization` suffix was
non-empty (`QoderFailoverRouter.openStream`). Any non-empty value passed, so
the `api-keys:` set Quotio writes into CPA's config was never consulted on the
Qoder path. Combined with the user-facing listener being reachable beyond
strict localhost (Cloudflare Quick Tunnel auto-start, `Quotio/ViewModels/
QuotaViewModel.swift:1596`), any reachable caller could spend Qoder quota by
supplying an arbitrary token. Tracked as P0 in
`docs/qoder-openai-proxy-gap-analysis.md`.

## Decision

The Qoder path owns a `QoderAccessValidator` that mirrors CPA's
`config_access` provider exactly, so Qoder and non-Qoder requests authenticate
identically.

1. **Same candidate sources and extraction as CPA.** Port
   `internal/access/config_access/provider.go` (`extractBearerToken` + the
   five-source candidate list): `Authorization` (Bearer-suffix **or** bare
   header when the scheme is not `bearer`), `X-Api-Key`, `X-Goog-Api-Key`,
   `?key=`, `?auth_token=`. First candidate that matches a configured key
   passes.
2. **Same failure shapes as CPA.** No candidate present → `401` +
   `{"error":{"message":"Missing API key"}}`; a candidate present but no match
   → `401` + `{"error":{"message":"Invalid API key"}}` (matches
   `sdk/access/errors.go`: `NewNoCredentialsError`, `NewInvalidCredentialError`,
   both `http.StatusUnauthorized`).
3. **Constant-time comparison** for candidate keys (CPA uses a hash-set; we add
   constant-time string compare on top so timing leakage from the proxy's
   in-process set is no worse than CPA's).
4. **Key set is a CPA-sourced snapshot, not a file re-read.** A small
   `QoderAccessValidator` actor holds a `Set<String>`; `reload(_:)` is called
   from the existing `ManagementAPIClient.fetchAPIKeys()` refresh cadence (the
   quota poll, and after any add/replace/update/delete on the API Keys screen).
   The Qoder request path calls `authenticate(...)` synchronously off the
   current snapshot. Rationale: `fetchAPIKeys()` is a live `GET /api-keys`
   against CPA's management API and reflects out-of-band mutations, which a
   YAML re-parse would miss; it also adds no per-request file I/O or network and
   keeps the request path off the `@MainActor`.

## Considered Options

- **Strict `Authorization: Bearer <key>` only** (the gap analysis's literal
  prescription). Rejected: CPA's own provider is deliberately lenient about the
  scheme and accepts five sources. A stricter Qoder path would make a client
  using `X-Api-Key` (or `?key=`, or a bare token) work against every non-Qoder
  model and 401 the moment it sends `model: qoder/...`. That is a worse, more
  surprising contract than the status quo for that client, and it contradicts
  the "we own key validation because CPA is bypassed" framing — the goal is to
  be indistinguishable from CPA at the auth boundary, not stricter.
- **Re-parse CPA's config YAML per request.** Rejected: the file is not
  authoritative after management-API mutations, and per-request file read + YAML
  parse on the hot path is wasteful when an already-maintained snapshot exists.
- **Live `GET /api-keys` per Qoder request (with TTL cache).** Rejected: adds a
  localhost HTTP round-trip to every Qoder request. The snapshot reloaded on
  the existing refresh cadence is fresh enough.

## Consequences

- Qoder and CPA auth surfaces match: any client that authenticates against one
  authenticates against the other. No surprise 401s at the routing seam.
- The validator must be reloaded on the same cadence `QuotaViewModel.apiKeys`
  already refreshes; if that cadence changes, the validator follows for free.
- This closes P0 of the gap analysis but does **not** address the separate
  listener-exposure question (localhost bind vs Cloudflare tunnel reachability)
  — that is a defense-in-depth decision tracked separately.
