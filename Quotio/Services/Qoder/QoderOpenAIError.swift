//
//  QoderOpenAIError.swift
//  Quotio
//
//  OpenAI error envelope builder for the Qoder + bridge paths (issue #16,
//  ADR 0010).
//
//  OpenAI's contract requires every error response to carry a JSON body of the
//  shape `{"error":{"message":...,"type":...,"code":...}}` (code optional).
//  CPA enforces this in `BuildErrorResponseBody`
//  (`sdk/api/handlers/handlers.go`), which every CPA-served endpoint already
//  uses; `ProxyBridge.sendError` previously returned `text/plain`, so a client
//  saw JSON errors for non-Qoder models and a literal string for Qoder / bridge
//  parse failures — two contracts depending on the path (ADR 0010 §Context).
//
//  This file ports CPA's builder byte-faithfully: the status→type/code map, the
//  empty-message → HTTP reason-phrase fallback, and the valid-JSON pass-through
//  (so an upstream Qoder JSON error is preserved verbatim instead of re-wrapped).
//  One builder serves both `ProxyBridge.sendError` (HTTP response bodies) and
//  the Qoder streaming mid-stream failure frame (ADR 0010 §Mid-stream).
//
//  Pure value type — no I/O, no actor state. `nonisolated enum` with static
//  methods so it opts out of the project's MainActor default and is callable
//  from any isolation domain (ProxyBridge is an actor; the builder is reached
//  from both the actor and its `nonisolated` helpers). Mirrors the declaration
//  style of `QoderChatTranslator` / `QoderResponsesTranslator`.
//

import Foundation

/// Port of CPA's `BuildErrorResponseBody` — one builder for the bridge + Qoder
/// paths. Pure value type — no I/O. Produces the OpenAI error envelope JSON:
/// `{"error":{"message":...,"type":...,"code":...}}` (`code` omitted when empty,
/// matching Go's `omitempty`).
///
/// Two entry points:
///   - `body(statusCode:message:)` — the JSON envelope bytes, for the body of an
///     HTTP error response (replaces `ProxyBridge.sendError`'s former
///     `text/plain` body).
///   - `sseTerminalFrame(statusCode:message:)` — the SSE terminal frames for a
///     mid-stream failure (after the `200 OK` SSE head has shipped and the HTTP
///     status can no longer change): `data: {envelope}\n\n` then
///     `data: [DONE]\n\n`. ADR 0010 §Mid-stream.
nonisolated enum QoderOpenAIError {

    /// Build the OpenAI error envelope body bytes for a status + message.
    /// Mirrors CPA's `BuildErrorResponseBody`:
    ///   1. `status <= 0` → default to 500.
    ///   2. Empty message → the HTTP reason phrase for the status.
    ///   3. If the (trimmed) message is valid JSON, return it verbatim
    ///      (byte-faithful pass-through of an upstream Qoder JSON error).
    ///   4. Otherwise wrap as `{"error":{"message":...,"type":...,"code":...}}`
    ///      with type/code derived from the status; `code` is omitted when empty.
    static func body(statusCode: Int, message: String) -> Data {
        // 1. CPA: status <= 0 → 500.
        var status = statusCode
        if status <= 0 {
            status = 500
        }

        // 2. CPA: TrimSpace(errText) == "" → errText = HTTP StatusText(status).
        // `errText` is the trimmed working copy; the original `message` may
        // carry surrounding whitespace that we strip before the JSON-validity
        // check (step 3 returns the trimmed text, matching CPA).
        var errText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if errText.isEmpty {
            errText = reasonPhrase(for: status)
        }

        // 3. CPA: if json.Valid(trimmed) → return trimmed verbatim. CPA accepts
        // any valid JSON top-level (object, array, string, number, bool, null),
        // not only objects — mirror that. Returning the trimmed text preserves
        // upstream Qoder JSON errors byte-faithfully instead of re-wrapping.
        if let trimmedData = errText.data(using: .utf8),
           asAnyJSON(trimmedData) != nil {
            return trimmedData
        }

        // 4. Build the envelope. CPA's switch maps status → (type, code); code
        // is "" for unmapped cases, which the `omitempty` tag then omits.
        let errType: String
        let code: String
        switch status {
        case 401:
            errType = "authentication_error"
            code = "invalid_api_key"
        case 403:
            errType = "permission_error"
            code = "insufficient_quota"
        case 429:
            errType = "rate_limit_error"
            code = "rate_limit_exceeded"
        case 404:
            errType = "invalid_request_error"
            code = "model_not_found"
        default:
            if status >= 500 {
                errType = "server_error"
                code = "internal_server_error"
            } else {
                // 400 and any other unmapped 4xx: invalid_request_error, no
                // code (matches CPA's default arm).
                errType = "invalid_request_error"
                code = ""
            }
        }

        // 5. Marshal {error:{message, type, code}}. Include `code` ONLY when
        // non-empty (Go's `omitempty`).
        var error: [String: Any] = [
            "message": errText,
            "type": errType,
        ]
        if !code.isEmpty {
            error["code"] = code
        }
        let payload: [String: Any] = ["error": error]

        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            return data
        }

        // 6. CPA fallback if Marshal fails (cannot happen for this dict shape,
        // but mirror the source of truth): hand-built JSON with the server_error
        // defaults. JSONSerialization failing here is pathological — the dict is
        // all strings — but the fallback keeps byte parity with CPA.
        let safeMessage = jsonEscape(errText)
        let fallback = "{\"error\":{\"message\":\(safeMessage),\"type\":\"server_error\",\"code\":\"internal_server_error\"}}"
        return Data(fallback.utf8)
    }

    /// The SSE terminal frames for a mid-stream failure (after the `200 OK`
    /// head): `data: {envelope}\n\n` then `data: [DONE]\n\n`. The client sees a
    /// structured error instead of a silent truncation (ADR 0010 §Mid-stream).
    /// Used on the Chat Completions streaming path; the Responses path uses
    /// `QoderResponsesAdapter.errorEvent` instead (no `[DONE]` in Responses).
    static func sseTerminalFrame(statusCode: Int, message: String) -> Data {
        let envelope = body(statusCode: statusCode, message: message)
        return Data("data: ".utf8) + envelope + Data("\n\n".utf8) + Data("data: [DONE]\n\n".utf8)
    }

    // MARK: - Helpers

    /// The HTTP reason phrase for a status, mirroring Go's
    /// `http.StatusText` for the codes this codebase serves (ADR 0010 maps the
    /// Qoder failure kinds onto 400/401/403/404/429/500/501/502/503). Unknown
    /// positive statuses fall back to "Internal Server Error" — CPA reaches the
    /// same default via the `status <= 0 → 500` path; this mirrors that for an
    /// unknown-but-positive status with an empty message. Internal so
    /// `ProxyBridge.sendError` reuses it for the HTTP status line (one
    /// reason-phrase table, not two).
    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default:  return "Internal Server Error"
        }
    }

    /// CPA's `json.Valid` accepts any JSON value at the top level (object,
    /// array, string, number, bool, null). `JSONSerialization.jsonObject` with
    /// `.allowFragments` mirrors that — without the flag it rejects non-object
    /// / non-array top-level values. Returns the parsed value or nil.
    private static func asAnyJSON(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }

    /// Minimal JSON string escape for the marshal-failure fallback path only.
    /// The primary path uses `JSONSerialization`, which escapes correctly; this
    /// is only reached if that serialization fails (pathological for an
    /// all-string dict), where we hand-build the JSON to keep CPA byte parity.
    private static func jsonEscape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(Character(scalar))
                }
            }
        }
        out += "\""
        return out
    }
}
