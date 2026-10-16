# Route Qoder traffic through a Quotio-native COSY translator in ProxyBridge

## Context

Quotio wraps CPA (CLIProxyAPI), a third-party Go binary, which owns all
per-provider protocol translation and signing for the providers it supports
(Anthropic, Google, xAI, OpenAI, GitHub Copilot, AWS CodeWhisperer…). Qoder is
not among them, and CPA has no COSY support and no `qoder` provider type. Qoder's
chat/models gateway (`api3.qoder.sh/algo/...`) demands a COSY signature and WAF
body encoding that CPA cannot produce.

A PAT cannot be handed to CPA either: CPA would treat it as a static Bearer API
key, but PATs cannot authenticate upstream calls directly — they must first be
exchanged for a short-lived job token (~24h), and CPA has no re-exchange logic.

## Decision

Implement Qoder routing Quotio-side. `ProxyBridge` becomes branchy: requests
whose body `model:` field is Qoder-bound are intercepted, COSY-signed, WAF-
encoded, and shipped direct to `api3.qoder.sh`, bypassing CPA entirely. All
other traffic still forwards to CPA unchanged, byte-for-byte.

Quotio owns the COSY signer, the WAF encoder, the PAT → job-token exchange, and
job-token re-exchange on expiry.

## Considered Options

- **A. Quotio-native COSY in ProxyBridge** *(chosen)* — Quotio holds the COSY
  code; CPA never sees Qoder. Lets us ship without waiting on a CPA release and
  without bundling a second binary.
- **B. Local adapter binary alongside CPA** — ship a small OpenAI-shape ↔ COSY
  translator process; Quotio writes a `openai-compatibility:` YAML block pointing
  CPA at it. Keeps Quotio free of protocol code but adds a binary to build,
  version, and supervise.
- **C. Push COSY upstream into CPA** — cleanest seam, zero Quotio protocol code,
  but requires an upstream Go contribution and CPA release-cycle coordination.
  Months, not weeks.

## Consequences

- Quotio now holds real upstream-protocol code (COSY + WAF), which the codebase
  otherwise deliberately avoids. Future COSY drift is on us to track.
- `ProxyBridge` loses its "transparent byte-forwarder" invariant for Qoder
  traffic. It must parse request bodies to route. See ADR 0002.
- Job-token lifetime management is Quotio's responsibility, not CPA's. See
  ADR 0003.
- If CPA later ships native Qoder support, the COSY code here becomes redundant
  and the path is: collapse the ProxyBridge Qoder branch, hand the PAT to CPA as
  a new auth-file type, delete the signer. Option A is the reversible option of
  the three.
