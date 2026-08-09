//
//  QoderGatewayChunker.swift
//  Quotio
//
//  Two-phase byte chunker for `QoderGatewayStream`'s pull source. Decouples
//  *when the router's pre-handoff peek sees its first chunk* from the bulk
//  pump's efficiency threshold.
//
//  ## Why this exists (gap #1 fix)
//
//  The router's `confirmStreamAndHandOff` races `nextChunk()` against a 2s
//  timeout to detect the live quota-exhaustion shape (HTTP 200 + headers, then
//  zero bytes indefinitely — a true silent stall). For that timeout to mean
//  "no first byte arrived," the *first* pull must return as soon as a complete
//  SSE frame is available — not after 8KB accumulate.
//
//  The previous inline flush loop (`QoderGatewayClient.openStream`) buffered
//  every pull to 8KB. So the 2s clock measured time-to-8KB, not time-to-first-
//  byte. Healthy long-context / reasoning requests (TTFT routinely 2-11s, small
//  SSE frames ~tens of bytes) frequently stay under 8KB at 2s → false `.quota`
//  classification → 60s cooldown → rotation or 503. The 8KB loop lived inline
//  in `openStream`, unreachable by tests, which is why the bug shipped.
//
//  Extracted here as a pure, injected accumulator so the first-pull boundary
//  policy is unit-testable without a network. Production wires `AsyncBytesBox`
//  as the byte provider; tests wire a scripted closure.
//
//  ## Boundary policy
//
//  - First pull: flush at the first complete SSE frame boundary (`\n\n` or
//    `\r\n\r\n`), capped at `maxFirstChunk` (8192), or at EOF. A *complete*
//    frame is required (not just the first byte) because `probeForUpstreamStatus`
//    parses the `data:` JSON line — a partial `{"statusCodeValue":4` would be
//    skipped and the quota envelope handed to the agent.
//  - Subsequent pulls: flush at `bulkThreshold` (8192) or EOF — unchanged from
//    the prior behavior, purely for reparser efficiency (so it sees reasonable
//    frame sizes rather than one byte per await).
//
//  The reparser splits on `\n` and buffers partial trailing lines across feeds
//  (`QoderSSEReparser.buffer`), so a small first chunk followed by large
//    bulk chunks is framing-safe. CRLF split across the chunk boundary is
//    handled per-feed (the `\r\n` → `\n` collapse in `feed`). Multi-byte UTF-8
//    characters split across a chunk boundary are handled the same way —
//    `feed()` decodes the longest valid prefix and stashes the dangling
//    trailing bytes for the next feed (see `pendingUTF8`).
//

import Foundation

/// Pure byte-chunking policy: given a `nextByte` provider, return chunks
/// according to the two-phase boundary policy above. The router's peek calls
/// `nextChunk()` once (first pull → frame-boundary flush); ProxyBridge's pump
/// calls it repeatedly (bulk → 8KB flush).
///
/// `Sendable` so it can live inside the `@Sendable` pull-source closure. State
/// (`firstPull`) is confined to a single `@unchecked Sendable` owner box in
/// production (`AsyncBytesSource`), mirroring the prior `AsyncBytesBox` pattern;
/// the single-owner contract (peek completes before pump begins) serializes
/// access. In tests the chunker is driven on one task, so no contention.
nonisolated struct QoderGatewayChunker: Sendable {
    /// First-pull flush boundaries. The first pull returns once the buffer's
    /// suffix matches either (SSE spec is `\n\n`; some gateways emit CRLF).
    static let firstFrameBoundary = "\n\n"
    static let firstFrameBoundaryCRLF = "\r\n\r\n"
    /// Hard cap on the first pull even if no frame boundary ever lands. Guards
    /// against a pathological stream that never emits `\n\n` (e.g. a giant
    /// single-line JSON blob). 8192 is generous: a real Qoder SSE frame is
    /// tens to low hundreds of bytes.
    static let maxFirstChunk = 8192
    /// Bulk-pull flush threshold. Matches the prior inline loop.
    static let bulkThreshold = 8192

    /// Pull the next chunk. `nextByte` advances the underlying byte source
    /// (production: `AsyncBytes.Iterator`; tests: a scripted closure) and
    /// returns a single byte, or nil at stream end.
    ///
    /// First call applies the frame-boundary policy; later calls apply the bulk
    /// threshold. Callers own the mutation of `firstPull` via the `firstPull`
    /// inout — production passes a box-stored flag, tests pass a local.
    static func nextChunk(
        nextByte: @escaping @Sendable () async throws -> UInt8?,
        firstPull: inout Bool
    ) async throws -> Data? {
        if firstPull {
            firstPull = false
            return try await firstPullChunk(nextByte: nextByte)
        }
        return try await bulkPullChunk(nextByte: nextByte)
    }

    /// First pull: flush at the first complete SSE frame boundary, the hard
    /// cap, or EOF (whichever comes first).
    private static func firstPullChunk(
        nextByte: @Sendable () async throws -> UInt8?
    ) async throws -> Data? {
        var buffer = Data()
        while let byte = try await nextByte() {
            buffer.append(byte)
            if buffer.count >= maxFirstChunk { return buffer }
            if buffer.endsWith(Self.firstFrameBoundaryData)
                || buffer.endsWith(Self.firstFrameBoundaryCRLFData) {
                return buffer
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// Subsequent pull: flush at the bulk threshold or EOF. Identical to the
    /// prior inline loop.
    private static func bulkPullChunk(
        nextByte: @Sendable () async throws -> UInt8?
    ) async throws -> Data? {
        var buffer = Data()
        while let byte = try await nextByte() {
            buffer.append(byte)
            if buffer.count >= bulkThreshold { return buffer }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private static let firstFrameBoundaryData = Data(firstFrameBoundary.utf8)
    private static let firstFrameBoundaryCRLFData = Data(firstFrameBoundaryCRLF.utf8)
}

/// Suffix check for `Data`. `Data` has no `hasSuffix` unlike `String`; this
/// compares the trailing bytes of `self` against `trailer`. Used by the
/// chunker's frame-boundary detection.
private nonisolated extension Data {
    func endsWith(_ trailer: Data) -> Bool {
        guard count >= trailer.count else { return false }
        return trailer.elementsEqual(suffix(trailer.count))
    }
}
