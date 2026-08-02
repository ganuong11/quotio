//
//  QoderWAFEncoder.swift
//  Quotio
//
//  Phase 2a foundation (ADR 0001): the WAF body-encoding wrapper applied to
//  chat/model-list request bodies before they are COSY-signed and shipped to
//  `api3.qoder.sh`. Without it the gateway returns a reduced model catalog
//  (CONTEXT.md — "WAF body encoding (`Encode=1`)").
//
//  Pure function: no I/O, no actor state, no globals. Isolated here so ticket
//  #5 can unit-test the riskiest porting surface against the TypeScript
//  fixtures before ProxyBridge wires it in (tickets 06-07).
//
//  Reference: pi-provider-qoder/src/qoder-encoding.ts (`qoderEncodeBody`),
//  ported verbatim — same base64, same slice rearrange, same custom alphabet,
//  same `=` → `$` substitution.
//

import Foundation

/// Qoder's WAF body encoder. `Encode=1` requests route the raw request body
/// through this before signing; the gateway reverses the transform.
///
/// The transform is fully deterministic and reversible:
///   1. standard base64 of the UTF-8 body bytes (padding `=` included);
///   2. rotate the base64 string by `a = n/3` so the layout becomes
///      `tail(n-a) + middle(a, n-a) + head(0, a)`;
///   3. substitute each character through a fixed custom alphabet
///      (positional swap, not a hash);
///   4. replace base64 padding `=` with `$`.
///
/// `nonisolated enum` → all members inherit nonisolated, callable from any
/// isolation domain (the project's default isolation is MainActor; pure value
/// types must opt out explicitly, like `ProxyURLValidator` and `AIProvider`).
nonisolated enum QoderWAFEncoder {
    /// Qoder's substitution target alphabet. The character at index `i` is the
    /// encoded form of the standard-base64 character at index `i` of
    /// `standardBase64Alphabet`. Mirrors `qoderCustomAlphabet` in pi verbatim,
    /// so the encoded output is byte-identical to the TypeScript provider.
    static let customAlphabet = "_doRTgHZBKcGVjlvpC,@aFSx#DPuNJme&i*MzLOEn)sUrthbf%Y^w.(kIQyXqWA!"

    /// RFC 4648 standard base64 alphabet — the lookup table the custom alphabet
    /// indexes into. Hardcoded (not `Data.base64EncodedString`'s output
    /// iterated, which would be slower) and asserted for the right length at
    /// first use.
    static let standardBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /// Encode a request body the way `qoderEncodeBody` does in pi. Accepts the
    /// raw request bytes so the caller can pipe the JSON body straight in.
    ///
    /// - Parameter body: raw request body bytes (UTF-8 JSON for chat/model-list).
    ///   An empty input returns an empty string, matching pi.
    /// - Returns: the WAF-encoded string to ship as the request body.
    static func encode(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        return encodeStandardBase64(body.base64EncodedString())
    }

    /// Convenience overload for string bodies. Encodes the UTF-8 bytes.
    static func encode(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        return encode(Data(body.utf8))
    }

    /// Apply the rearrange + custom-alphabet + `=` → `$` pass to a *standard*
    /// base64 string. Split out so the encoder is testable against a fixture
    /// that already supplies the standard-base64 layer (and so the byte path
    /// and the string path share one implementation).
    private static func encodeStandardBase64(_ std: String) -> String {
        // The alphabets must be the same length, otherwise the positional
        // substitution is meaningless. A build or runtime change that broke
        // either constant would otherwise produce silently-wrong signatures.
        precondition(
            customAlphabet.count == standardBase64Alphabet.count,
            "QoderWAFEncoder: alphabet length mismatch (\(customAlphabet.count) vs \(standardBase64Alphabet.count))"
        )

        let characters = Array(std)
        let n = characters.count
        let a = n / 3

        // Rotate: tail(n-a) + middle(a, n-a) + head(0, a), exactly as in pi's
        // `std.slice(n - a) + std.slice(a, n - a) + std.slice(0, a)`. With
        // `a = n/3`, the three slices are [n-a, n), [a, n-a), [0, a) — and
        // n-a + (n-2a) + a == n, so the rearranged length always equals the
        // input length (no characters dropped or doubled).
        var rearranged = [Character]()
        rearranged.reserveCapacity(n)
        rearranged.append(contentsOf: characters[(n - a)..<n])
        rearranged.append(contentsOf: characters[a..<(n - a)])
        rearranged.append(contentsOf: characters[0..<a])

        // Build a fast lookup from standard-alphabet index → custom character,
        // then walk the rearranged buffer once. The `=` (padding) case is
        // separate because `=` is not a member of the standard alphabet.
        // Each ASCII char < 128 that appears in the standard alphabet maps
        // directly; everything else passes through unchanged (mirrors pi's
        // `idx >= 0 ? customAlphabet[idx] : c`).
        var index = [Int](repeating: -1, count: 128)
        for (i, c) in standardBase64Alphabet.utf8.enumerated() where c < 128 {
            index[Int(c)] = i
        }

        var out = [UInt8]()
        out.reserveCapacity(n)
        for c in rearranged {
            let scalar = c.asciiValue ?? 0
            if c == "=" {
                out.append(UInt8(ascii: "$"))
            } else if scalar < 128, scalar > 0, let custom = scalarForStandardIndex(index[Int(scalar)]) {
                out.append(custom)
            } else {
                // Non-ASCII or not in the base64 alphabet: pass through. Base64
                // output never contains such characters in practice, so this
                // branch is defensive; pi emits the original char too.
                c.utf8.forEach { out.append($0) }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Look up the custom-alphabet byte for a given standard-alphabet index.
    /// Returns nil for `-1` (character not in the standard alphabet) so the
    /// caller can fall through to pass-through. Hoisted out of the hot loop so
    /// the index check reads clearly.
    private static func scalarForStandardIndex(_ i: Int) -> UInt8? {
        guard i >= 0, i < customAlphabet.utf8.count else { return nil }
        return customAlphabet.utf8[customAlphabet.utf8.index(customAlphabet.utf8.startIndex, offsetBy: i)]
    }
}
