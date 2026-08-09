# Quotio

A native macOS menu bar app that wraps **CLIProxyAPI (CPA)** — a third-party Go
binary Quotio bundles as a subprocess — to manage OAuth, quota visibility, and
proxy routing for many AI providers from one menu bar UI.

## Language

### Auth & credentials

**PAT (Personal Access Token)**:
A long-lived, user-issued credential (`pt-...`) used to mint short-lived working tokens. Never sent to upstream APIs directly; must first be exchanged.
_Avoid_: API key (when the key is short-lived or sent directly upstream)

**Job Token**:
The short-lived working credential (`jt-...`) produced by exchanging a PAT. Sent as a `Bearer` header on Qoder OpenAPI calls and embedded into the COSY signature on Qoder gateway calls. Expires (observed ~24h).
_Avoid_: access token (Qoder's is not OAuth-derived)

**MonitorCredentialVault**:
Quotio's Keychain drawer (`dev.quotio.desktop.monitor-auth`) holding refresh-style credentials as `MonitorOAuthCredential` JSON, one entry per `MonitorAccount.id`. Provides compare-and-swap rotation.
_Avoid_: keychain (generic), credential store (vague)

**CustomProviderService**:
The `UserDefaults`-backed store for credentials that must round-trip into CPA's YAML config as Bearer headers (GLM, ClinePass, OpenRouter API keys). Not a Keychain drawer.
_Avoid_: provider config (too generic)

**MonitorAccount**:
Quotio's stable identity for one account in the quota/monitoring dictionary: `{provider, accountKey, source, credentialReference, ...}`.

### Provider routing

**CPA (CLIProxyAPI)**:
The third-party Go binary Quotio bundles. Listens on localhost, speaks OpenAI Chat Completions shape, translates per-provider, signs per-provider, routes upstream. Quotio writes its auth files and YAML config; Quotio does not own its protocol code.
_Avoid_: the proxy (ambiguous), CLIProxyAPI-Plus (a specific build flavour)

**ProxyBridge**:
An in-process `NWListener` in Quotio that sits between CLI agents and CPA. Today it is a transparent byte-forwarder that forces `Connection: close` to dodge stale-connection bugs. Under Option A for Qoder, it becomes branchy: Qoder-bound requests are intercepted, COSY-signed, and shipped direct to `api3.qoder.sh`; all other traffic still forwards to CPA unchanged.
_Avoid_: bridge, proxy (ambiguous with CPA)

**Routing discriminator**:
The rule ProxyBridge uses to decide whether a request is Qoder-bound (and therefore takes the COSY path) or CPA-bound. A conjunctive allowlist: body `model:` starts with `qoder/` **and** method is `POST` **and** path is an explicitly supported endpoint (today: `/v1/chat/completions`; extensible as #451/#452 land). A `qoder/` model on anything else is rejected with a Qoder-owned 404 — it does not fall through to CPA. ADR 0003 (prefix) refined by ADR 0009 (method+path).

**QoderAccessValidator**:
The in-process API-key gate that owns authentication on the Qoder path, since CPA's `AuthMiddleware` is bypassed for `qoder/*` traffic. Mirrors CPA's `config_access` provider exactly — same five candidate sources (`Authorization` Bearer-or-bare, `X-Api-Key`, `X-Goog-Api-Key`, `?key=`, `?auth_token=`), same `401` failure shapes, same key set (a CPA-sourced snapshot reloaded on the `fetchAPIKeys()` cadence). ADR 0008.
_Avoid_: auth middleware (that's CPA's), API key check (vague)

### Qoder-specific

**Qoder**:
The international/global Qoder AI service. The only Qoder flavour Quotio supports. Endpoints under `openapi.qoder.sh` (auth, quota) and `api3.qoder.sh` (chat/models, COSY-signed).
_Avoid_: qoder-cn, Qoder China, Qoder CN — explicitly out of scope

**PAT exchange**:
`POST openapi.qoder.sh/api/v1/jobToken/exchange { personal_token } → { token, refresh_token, expires_at }`. Turns a PAT into a Job Token. No COSY signature required for this call.
_Avoid_: token refresh (that's OAuth terminology; this is re-exchange)

**COSY signature**:
Qoder's request-signing scheme for the chat/models gateway. RSA-encrypts an AES key, AES-CBC-encrypts a user-info JSON blob, then MD5s (`payloadB64 \n cosyKey \n timestamp \n body \n sigPath`) into an `Authorization: Bearer COSY.<payload>.<sig>` header, plus ~15 `Cosy-*` headers. Required for all `api3.qoder.sh/algo/...` calls; not required for `openapi.qoder.sh/api/...`.
_Avoid_: Qoder auth (ambiguous with PAT exchange)

**Machine ID**:
A per-install UUID embedded in COSY headers (`Cosy-Machineid`, `Cosy-Machinetoken`). Persisted so the same Quotio install presents a stable identity to Qoder across re-exchanges.

**WAF body encoding (`Encode=1`)**:
An obfuscation wrapper applied to chat/model-list request bodies before signing. Required for the full model catalog and for chat requests; without it the gateway returns a reduced response.

**Non-streaming aggregation (`QoderCompletionAggregator`)**:
The Qoder gateway speaks SSE only, so for a `stream != true` Chat Completions request (missing `stream` or `stream: false` — OpenAI's spec default is `false`), Quotio keeps consuming the SSE upstream and folds the streamed deltas into a single `chat.completion` JSON object returned with `Content-Type: application/json`. The streaming `QoderSSEReparser` remains the single parser of the Qoder envelope; the aggregator consumes its OpenAI-shape output. See ADR 0014.
_Avoid_: "non-streaming mode" implying an upstream change — the upstream is always SSE.
