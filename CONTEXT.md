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
The third-party Go binary Quotio bundles. It listens on a loopback-only internal port (`18317` production, `18318` development) — agents never reach it directly. It speaks OpenAI Chat Completions shape, translates per-provider, signs per-provider, routes upstream. Quotio writes its auth files and YAML config; Quotio does not own its protocol code.
_Avoid_: the proxy (ambiguous), CLIProxyAPI-Plus (a specific build flavour)

**GatewayListener** (was ProxyBridge):
An in-process `NWListener` in Quotio that owns the agent-facing front door (`8317` production, `8318` development). Provider-owned traffic (`qoder/*`, `opencode/*`) is intercepted and served by the Swift gateways — Qoder requests are COSY-signed and shipped direct to `api3.qoder.sh`; OpenCode requests go through `OpencodeRouter`'s account-aware failover. All other inference and CPA management traffic byte-forwards to CPA's internal port. The old name survives in some ADRs and docs.
_Avoid_: bridge, proxy (ambiguous with CPA)

**Routing discriminator**:
The rule GatewayListener uses to decide whether a request is Qoder-bound (and therefore takes the COSY path) or CPA-bound. A conjunctive allowlist: body `model:` starts with `qoder/` **and** method is `POST` **and** path is an explicitly supported endpoint (today: `/v1/chat/completions` and `/v1/responses`; extensible as #451/#452 land). A `qoder/` model on anything else is rejected with a Qoder-owned 404 — it does not fall through to CPA. ADR 0003 (prefix) refined by ADR 0009 (method+path).

**/v1/models merge**:
`GET /v1/models` is intercepted by GatewayListener and answered with CPA's list plus the Qoder catalog under `qoder/<id>` (one entry per `QoderModelRegistry` seed key, `created` pinned to the 2026-08-03 catalog-refresh epoch). Any failure — non-2xx from CPA, unparseable body, merge error — degrades to raw CPA passthrough (the agent sees exactly what CPA sent), so model discovery never breaks. The merge only runs when `qoderRouter` is wired; otherwise the endpoint stays a pure passthrough. The endpoint stays on CPA's auth surface (client `Authorization` flows through; `QoderAccessValidator` is not involved). ADR 0016 reverses ADR 0003 §3.

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

**Exchange pacing**:
`QoderPATService` gates every `jobToken/exchange` call with a minimum interval (default 1s, sleep-recheck-claim slot) so multi-account bursts — synchronized job-token expiries tripped by quota polling, plus failover re-exchanges — cannot hammer the rate-limited exchange endpoint. Single funnel: quota poller (`credentials(fromPat:)`), failover router (`refreshCredential`), and onboarding all route through `QoderPATService.shared`. ADR 0017.
_Avoid_: per-path throttling (leaves the other path unpaced), claim-before-sleep (wrong under actor reentrancy)

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

**Message trim (`QoderChatTranslator.trimmingMessages`)**:
What happens to a Chat Completions request whose `messages` exceed `maxMessages` (9999): the translator keeps the leading system/developer preamble plus the newest turns, cutting at a boundary that never orphans a `tool` result — instead of rejecting with 400 (issue #14's original behavior, which permanently broke any session that crossed the cap, since client history only grows). Upstream's own message limit is unverified above 999; a request between 1000 and 9999 messages is forwarded untrimmed and could still hit it. See ADR 0019.
_Avoid_: "context window" (that's token-based, client-side compaction), message cap rejection (the old behavior)

### OpenCode-specific

**OpenCode**:
The OpenCode Console AI service (`opencode.ai/console` for auth, `opencode.ai/inference` for inference). Free inference models are served through a Quotio-native GatewayListener branch (ADR 0020): account-aware failover over Quotio-managed device-code logins plus read-only detection of the system opencode install's credentials (`auth.json`, `opencode*.db` via temp copies — never written back).
_Avoid_: opencode (ambiguous with the client app), OpenCode CLI (the client, not the service)

**OpenCode free-tier gate**:
The upstream fingerprint check on `opencode.ai/inference`: full released-client UA (`opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14` — unrecognized versions 403), `x-opencode-*` metadata headers, `stream:true`, a `read` tool present, and an Apple TLS stack (URLSession passes, curl 403s — all upstream calls stay on URLSession). Tools named `read/bash/write/edit/glob/grep` with empty `parameters.properties` are 403'd; Quotio substitutes the real opencode schemas for degenerate definitions.
_Avoid_: auth gate (that's the proxy API key surface)

**OpenCode surface dispatch**:
Each `opencode/<model>` request targets the model's **native** upstream surface (chat completions / responses), resolved per model from models.dev `provider.npm` (per-model override, else provider-level, else chat). Same-surface requests pass through byte-faithful; cross-surface requests translate at the seam in both directions — a Responses-speaking client on a chat-native model reuses the Qoder translator/adapter/aggregator; a chat client on a responses-native model translates via `OpencodeProtocolMapper.chatRequestToResponses` + `OpencodeChatSSEAdapter` (reasoning summaries → `delta.reasoning_content`; clean EOF synthesizes `stop`). Because the gate forces `stream:true` upstream, `stream:false` clients are aggregated into one JSON body on every arm (head written after aggregation; mid-aggregation failure is a true 502). ADR 0021 supersedes ADR 0020's surface-passthrough decision.
_Avoid_: family mapping (the pre-0021 design keyed off model families, not surfaces)
