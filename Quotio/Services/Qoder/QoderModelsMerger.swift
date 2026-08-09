//
//  QoderModelsMerger.swift
//  Quotio
//
//  Issue #10 / ADR 0016: merge the Qoder model catalog into the OpenAI
//  `GET /v1/models` response that CPA returns.
//
//  ADR 0003 §3 chose to leave `/v1/models` as a pure passthrough to CPA (Phase 2
//  minimum surface). The cost was that CLI agents could not auto-discover
//  `qoder/<id>` models: CPA's registry does not know the `qoder/` namespace
//  (ADR 0003 keeps Qoder out of CPA's config), so the catalog endpoint returned
//  by CPA never lists them. Users had to hardcode `qoder/auto` etc. in their
//  agent config. ADR 0016 reverses that trade (issue #10): ProxyBridge
//  intercepts `GET /v1/models`, fetches CPA's response, appends one entry per
//  enabled Qoder catalog key under the `qoder/<id>` namespace, and returns the
//  merged list. Any failure (unparseable body, wrong shape, decode error)
//  degrades to raw passthrough — model discovery must never break.
//
//  This file is the PURE, side-effect-free half of the merge: `mergeQoderModels`
//  takes CPA's already-fetched body bytes and returns the merged body bytes (or
//  nil to signal "give up, forward CPA's bytes unchanged"). The network half —
//  accumulate CPA's full response, decide status, write the agent-facing
//  response — lives in `ProxyBridge.serveModelsList`. Splitting the pure parser
//  from the I/O keeps the merge unit-testable without spinning up NWConnections
//  (mirrors how `QoderChatTranslator` is split from the network code).
//
//  `extractHTTPBody` is the second pure helper: given a WHOLE accumulated
//  upstream HTTP/1.1 response (ProxyBridge forces `Connection: close` upstream,
//  so the entire response lands before the socket closes), it returns just the
//  body, honouring `Content-Length` and `Transfer-Encoding: chunked`. The
//  network code can stay dumb (accumulate-until-close) while the parsing stays
//  unit-testable.
//
//  Pure value type — no I/O, no actor state. `nonisolated enum` with static
//  methods so it opts out of the project's MainActor default and is callable
//  from any isolation domain (ProxyBridge is `@MainActor`; the merger is
//  borrowed with no synchronization needs). Matches the declaration style of
//  `QoderModelRegistry` / `QoderOpenAIError` / `QoderRouteGate`.
//

import Foundation

/// Pure helpers for merging the Qoder model catalog into an OpenAI
/// `GET /v1/models` response (issue #10, ADR 0016).
///
/// Two entry points:
///   - `mergeQoderModels(into:)` — given CPA's models-list body bytes, return
///     the merged body bytes (Qoder entries appended under `qoder/<id>`), or
///     `nil` if the body is unparseable / wrong shape (caller forwards CPA's
///     bytes unchanged — model discovery must never break).
///   - `extractHTTPBody(from:)` — given a whole accumulated upstream HTTP/1.1
///     response, return just the body bytes (Content-Length or chunked), or
///     `nil` if the head is malformed or the body is incomplete.
nonisolated enum QoderModelsMerger {

    // MARK: - Constants

    /// The Qoder namespace prefix that every merged model id carries. Matches
    /// `QoderRouteGate.qoderPrefix` (ADR 0003 §1) — the same string that opts
    /// a *request* into Qoder routing is the one we advertise in the catalog.
    static let namespacePrefix = "qoder/"

    /// The `owned_by` value attached to every merged entry. OpenAI's spec
    /// allows any string; using `"qoder"` makes the catalog self-describing
    /// (a CLI agent can filter on `owned_by == "qoder"` to find Qoder models).
    static let ownedBy = "qoder"

    /// Fixed `created` epoch (UTC seconds) stamped on every merged entry.
    ///
    /// This is the **2026-08-03 catalog-refresh date** of `QoderModelRegistry`
    /// (see its header comment: "The entries below were refreshed on 2026-08-03
    /// against the live `GET /algo/api/v2/model/list?Encode=1` catalog"). Using
    /// a single constant — rather than per-call `Date()` — keeps the merged
    /// list byte-stable across calls and across process restarts, and matches
    /// how OpenAI's own `/v1/models` reports a fixed `created` per model.
    ///
    /// Verified via `date -j -u -f "%Y-%m-%d" "2026-08-03" +%s` → 1785715200.
    /// Decodes back to 2026-08-03T00:00:00Z (pinned by
    /// `testCatalogEpochDecodesTo2026August03UTC`, which asserts the full
    /// midnight-UTC instant, not just the calendar day).
    static let catalogEpoch: Int = 1785715200

    // MARK: - Merge

    /// Merge the Qoder catalog into CPA's `GET /v1/models` response body.
    ///
    /// CPA returns the OpenAI models-list shape:
    /// ```
    /// { "object": "list", "data": [ {"id":...,"object":"model","created":...,"owned_by":...}, ... ] }
    /// ```
    /// This function appends one entry per `QoderModelRegistry.catalogKeys`
    /// entry, in registry (seed) order, with:
    ///   - `id`: `"<namespacePrefix><key>"` (e.g. `"qoder/auto"`)
    ///   - `object`: `"model"`
    ///   - `created`: `catalogEpoch` (fixed, stable)
    ///   - `owned_by`: `ownedBy` (`"qoder"`)
    ///
    /// Defense in depth: any key whose `qoder/<key>` id is ALREADY present in
    /// CPA's list is skipped (CPA won't normally carry these — ADR 0003 keeps
    /// Qoder out of CPA's registry — but the dedupe is cheap and prevents a
    /// duplicate-id bug if that invariant ever loosens).
    ///
    /// The top-level `object: "list"` and any other top-level fields CPA
    /// includes (e.g. a future `"notice"`) are preserved unchanged; only the
    /// `data` array is mutated.
    ///
    /// - Parameter cpaBody: CPA's raw response body bytes (the HTTP body, not
    ///   the whole response — pass the output of `extractHTTPBody` here).
    /// - Returns: The merged body bytes, or `nil` if `cpaBody` is unparseable
    ///   as JSON, is not a JSON object, or has no `data` array. On `nil` the
    ///   caller must forward CPA's raw response unchanged (ADR 0016 §Decision:
    ///   any merge failure degrades to raw passthrough — never breaks
    ///   discovery).
    static func mergeQoderModels(into cpaBody: Data) -> Data? {
        // Parse CPA's body. JSONSerialization is the right tool: the OpenAI
        // models-list shape is a flat object with an array of small dicts, so
        // we don't need Codable's type-safety overhead, and JSONSerialization
        // preserves unknown top-level fields (e.g. a future `"notice"`) where a
        // Codable struct would drop them. `.fragmentsAllowed` is NOT set: the
        // models list is always a top-level object, and rejecting a bare
        // fragment (e.g. `"not json"`) is exactly the "give up, passthrough"
        // path we want.
        guard let parsed = try? JSONSerialization.jsonObject(with: cpaBody) else {
            return nil
        }

        // Must be a JSON object (dict). A bare array, string, or number is the
        // wrong shape → nil (passthrough).
        guard let root = parsed as? [String: Any] else {
            return nil
        }

        // `data` must be present and an array. Missing or wrong-typed → nil.
        guard let data = root["data"] as? [Any] else {
            return nil
        }

        // Collect the ids already present (case-sensitive string compare; model
        // ids are case-sensitive in OpenAI's contract). We only inspect the
        // existing entries to dedupe — we do NOT mutate or reorder them, so the
        // CPA portion of the list is byte-faithful modulo JSONSerialization
        // re-serialization (key order may shift; values are preserved).
        var existingIDs = Set<String>()
        for entry in data {
            if let dict = entry as? [String: Any], let id = dict["id"] as? String {
                existingIDs.insert(id)
            }
        }

        // Build the merged data array. Start from CPA's entries (mutable copy),
        // then append one entry per catalog key that isn't already present.
        // `catalogKeys` is in seed order (stable across calls); `knownIDs` is a
        // Set and unordered, so iterating `catalogKeys` — not `knownIDs` — is
        // what makes the merged list deterministic.
        var mergedData = data
        for key in QoderModelRegistry.catalogKeys {
            let namespacedID = namespacePrefix + key
            // Defense in depth: skip a key whose qoder/<key> id is already in
            // CPA's list. Normally a no-op (ADR 0003 keeps Qoder out of CPA's
            // registry); the dedupe exists so a future CPA change can't produce
            // duplicate ids via this path.
            if existingIDs.contains(namespacedID) { continue }
            mergedData.append([
                "id":       namespacedID,
                "object":   "model",
                "created":  catalogEpoch,
                "owned_by": ownedBy,
            ])
        }

        // Re-serialize. Mutate a copy of the root so any other top-level fields
        // CPA included are preserved byte-faithfully (modulo key order). Pretty
        // printing is OFF: the OpenAI models list is plain compact JSON, and
        // emitting compact JSON keeps the merged body within a few KB (15 Qoder
        // entries ≈ 2 KB) — a meaningful saving on every discovery call.
        var mergedRoot = root
        mergedRoot["data"] = mergedData
        return try? JSONSerialization.data(withJSONObject: mergedRoot)
    }

    // MARK: - HTTP body extraction

    /// Extract the body bytes from a WHOLE accumulated upstream HTTP/1.1
    /// response.
    ///
    /// ProxyBridge forces `Connection: close` on every upstream request
    /// (`forwardRequest` sets it unconditionally), so the full response — head
    /// + body — arrives before the target connection's `isComplete` fires. That
    /// means the network code can stay dumb (accumulate-until-close into one
    /// `Data` buffer) while THIS helper does all the framing: split head/body
    /// at the first `\r\n\r\n`, then honour `Content-Length` (slice exactly) or
    /// `Transfer-Encoding: chunked` (decode chunks).
    ///
    /// Header-name matching is case-insensitive (RFC 7230 §3.2); CPA's Go stack
    /// always sends `Content-Length`, but the case-insensitive scan keeps us
    /// correct against any upstream.
    ///
    /// - Parameter response: The whole accumulated upstream response (status
    ///   line + headers + `\r\n\r\n` + body).
    /// - Returns: The body bytes, or `nil` if:
    ///   - the head/body separator (`\r\n\r\n`) is missing (malformed head);
    ///   - a declared `Content-Length` is not a valid int, or its slice would
    ///     run past the available bytes (body is incomplete — wait for more,
    ///     or give up if the connection already closed);
    ///   - a chunked body has a malformed size line or is missing its
    ///     terminating `0` chunk.
    static func extractHTTPBody(from response: Data) -> Data? {
        // Locate the head/body separator (`\r\n\r\n`) at the BYTE level. We
        // cannot use String's range search and then index into `Data`, because
        // `String.count` counts Extended Grapheme Clusters while `Data` is
        // byte-indexed — for non-ASCII bodies the two diverge and the slice
        // offset would be wrong. Instead, scan the bytes directly: ASCII-only
        // comparison against the four bytes 0x0D 0x0A 0x0D 0x0A. The head is
        // ASCII per HTTP/1.1, so this is exact.
        let bytes = [UInt8](response)
        guard let sepIndex = findHeaderSeparator(bytes) else {
            // No head/body separator — head is malformed/incomplete.
            return nil
        }
        // `sepIndex` is the byte offset of the first `\r` of `\r\n\r\n`. The
        // head is bytes [0..<sepIndex]; the body starts after the four-byte
        // separator.
        let headBytes = Array(bytes[0..<sepIndex])
        let bodyStart = sepIndex + 4
        let bodyBytes = response.subdata(in: bodyStart..<response.count)

        // Parse the head's headers (case-insensitive name match). The status
        // line is the first line; the rest are `Name: Value` pairs. Decode the
        // head as UTF-8 here — headers are ASCII per RFC, so this is safe, and
        // it lets us use String's splitting helpers. We don't touch the body
        // through this String (we sliced `bodyBytes` from the original `Data`
        // above), so non-UTF-8 bodies are still handled correctly.
        guard let head = String(bytes: headBytes, encoding: .utf8) else {
            return nil  // head isn't UTF-8/ASCII — malformed
        }
        let headLines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        // Skip index 0 (status line); remaining lines are headers.
        for line in headLines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                headers[name.lowercased()] = value
            }
        }

        // RFC 7230 §3.3.3: chunked wins over Content-Length when both are
        // present (a proxy must remove Content-Length before forwarding
        // chunked, but be defensive). Check chunked first.
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            return decodeChunked(bodyBytes)
        }

        // Content-Length: slice exactly that many bytes. Guard BOTH bounds:
        // a NEGATIVE Content-Length parses as an Int but would trap in
        // `subdata(in: 0..<cl)` (Range requires lowerBound <= upperBound) —
        // this function's contract is nil-on-malformed, never a crash. If the
        // slice would run past `bodyBytes.count`, the body is incomplete → nil
        // (the connection closed early; the caller should passthrough rather
        // than ship a truncated body to the merger).
        if let clString = headers["content-length"], let cl = Int(clString) {
            guard cl >= 0, cl <= bodyBytes.count else {
                return nil  // invalid or incomplete body
            }
            return bodyBytes.subdata(in: 0..<cl)
        }

        // No Content-Length and no chunked encoding: with `Connection: close`
        // (which ProxyBridge forces upstream), RFC 7230 §3.3.3 #7 says the body
        // runs to the end of the connection. CPA always sends Content-Length
        // for /v1/models, so this fallback is a safety net — return everything
        // after the head.
        return bodyBytes
    }

    /// Find the first occurrence of the four-byte sequence `\r\n\r\n`
    /// (`0x0D 0x0A 0x0D 0x0A`) in `bytes`, returning the BYTE offset of the
    /// leading `\r`. Returns nil if the separator is absent (malformed head).
    /// Byte-level, not String-level: see `extractHTTPBody` for why.
    private static func findHeaderSeparator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A
                && bytes[i + 2] == 0x0D && bytes[i + 3] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }

    /// Minimal HTTP/1.1 chunked transfer-encoding decoder
    /// (RFC 7230 §4.1).
    ///
    /// Grammar per chunk:
    /// ```
    /// chunk          = chunk-size [ chunk-ext ] CRLF chunk-data CRLF
    /// chunk-size     = 1*HEXDIG
    /// chunk-ext      = *( ";" chunk-ext-name [ "=" chunk-ext-val ] )
    /// chunked-body   = *chunk last-chunk trailer-part CRLF
    /// last-chunk     = 1*("0") [ chunk-ext ] CRLF
    /// ```
    ///
    /// This decoder:
    ///   - parses the hex size line up to the first `;` (ignores chunk-ext);
    ///   - reads `size` data bytes after the CRLF;
    ///   - consumes the trailing CRLF;
    ///   - on size `0`, consumes the (optional) trailer lines up to a blank
    ///     line and returns the accumulated body. Trailers are ignored (the
    ///     OpenAI models list never uses them, but RFC allows them).
    ///
    /// Returns nil on any framing error (bad hex, short data, missing CRLF) so
    /// the caller degrades to raw passthrough.
    ///
    /// Pure byte-level: works directly on the `Data` so non-UTF-8 chunk bodies
    /// are byte-faithful (chunk framing itself is ASCII hex + CRLF). See
    /// `extractHTTPBody` for why we avoid String indexing here.
    private static func decodeChunked(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output = Data()
        var pos = 0

        while pos < bytes.count {
            // Read the chunk-size line up to CRLF. Hex digits (and optional
            // chunk-ext after ';') live here.
            guard let lineEnd = findCRLF(bytes, from: pos) else {
                return nil  // missing size-line terminator
            }
            // Decode the size line (ASCII hex + maybe ';') to a String so we
            // can use `Int(_:radix:16)` and the chunk-ext strip. The size line
            // is ASCII per RFC, so UTF-8 decode is safe.
            guard let sizeLine = String(bytes: bytes[pos..<lineEnd], encoding: .utf8) else {
                return nil
            }
            // Strip chunk-ext (everything after the first ';').
            let hexPart = (sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init)) ?? sizeLine
            // Empty or non-hex size → malformed.
            guard !hexPart.isEmpty,
                  let size = Int(hexPart.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            // Advance past the size line + its CRLF.
            pos = lineEnd + 2  // skip CRLF

            if size == 0 {
                // Last chunk. Consume the trailer section (zero or more
                // trailer header lines) up to the terminating blank line
                // (an empty line). We do not surface trailers to the caller;
                // we just need to validate framing ends cleanly. Tolerate the
                // buffer ending inside the trailer section (the connection is
                // closing anyway — RFC wants a terminating CRLF, but the body
                // is already complete).
                while pos < bytes.count {
                    guard let trailerEnd = findCRLF(bytes, from: pos) else {
                        return output
                    }
                    if trailerEnd == pos {
                        // Blank line — end of trailers.
                        return output
                    }
                    pos = trailerEnd + 2
                }
                return output
            }

            // Read `size` body bytes, slicing from the original `data` to stay
            // byte-faithful. The guard uses SUBTRACTION (`bytes.count -
            // dataStart`) rather than addition (`pos + size`): a huge chunk
            // size (e.g. Int.max) would wrap `pos + size` negative and sail
            // past an addition-based guard into a `subdata` trap. Subtraction
            // is overflow-proof here since `dataStart <= bytes.count`.
            let dataStart = pos
            guard size <= bytes.count - dataStart else {
                return nil  // chunk data truncated / absurd size
            }
            output.append(data.subdata(in: dataStart..<(dataStart + size)))
            pos = dataStart + size

            // Trailing CRLF after the chunk data.
            guard pos + 2 <= bytes.count,
                  bytes[pos] == 0x0D, bytes[pos + 1] == 0x0A else {
                return nil
            }
            pos += 2
        }

        // Reached end of buffer without seeing a 0-size terminator — malformed
        // chunked stream. Return nil so the caller degrades to passthrough.
        return nil
    }

    /// Find the next `\r\n` in `bytes` at or after `from`. Returns the index of
    /// the `\r` (so the CRLF occupies `[result, result+1]`), or nil if none.
    private static func findCRLF(_ bytes: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < bytes.count {
            if bytes[i] == 0x0D && bytes[i + 1] == 0x0A {
                return i
            }
            i += 1
        }
        return nil
    }
}
