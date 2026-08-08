//
//  QoderGatewayChunkerTests.swift
//  QuotioTests
//
//  Unit tests for the two-phase byte chunker extracted from
//  `QoderGatewayClient.openStream` (gap #1 fix). The chunker's first pull now
//  flushes at the first complete SSE frame boundary instead of accumulating
//  8KB — this aligns the router's 2s pre-handoff peek with first-frame-arrival,
//  so healthy slow-first-byte requests aren't falsely classified as a silent
//  stall. These tests drive the pure `nextChunk` policy with a scripted byte
//  provider (no network, no router).
//

import Foundation
import XCTest
@testable import Quotio

final class QoderGatewayChunkerTests: XCTestCase {

    // MARK: - First pull: frame-boundary flush

    /// The core regression: a complete SSE frame (~120 bytes) must surface on
    /// the first pull as soon as its `\n\n` boundary lands — NOT after 8KB
    /// accumulate. Pre-fix the first pull buffered to 8KB, so a healthy request
    /// whose first frame arrived under 2s but stayed under 8KB was invisible to
    /// the router's peek and falsely timed out as `.quota`.
    func testFirstPullFlushesAtCompleteSSEFrame() async throws {
        let frame = Self.qoderFrame(status: 200, content: "hi")
        let iter = ByteIterator([UInt8](frame))
        var firstPull = true
        let chunk = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(chunk, Data(frame), "first pull returns the complete frame at its boundary")
        XCTAssertFalse(firstPull, "firstPull flag flips after first pull")
    }

    /// First pull returns exactly at the `\n\n` boundary even when more bytes
    /// follow. This is the gap #1 regression: pre-fix, the chunker would keep
    /// accumulating toward 8KB and not return after the frame.
    func testTrickleBelow8KBReturnsAtFirstFrame() async throws {
        let frame = Self.qoderFrame(status: 200, content: "hi")  // ~120 bytes
        let tail = [UInt8](Data(repeating: 0x41, count: 200))  // arbitrary bytes after
        let stream = [UInt8](frame) + tail
        let iter = ByteIterator(stream)
        var firstPull = true
        let first = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(first, Data(frame), "first pull stops at the frame boundary, not 8KB")
        // The next pull should then return the tail (bulk path, EOF since <8KB).
        let second = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(second, Data(tail), "second pull drains the remainder at EOF")
    }

    /// CRLF line endings: the frame boundary is `\r\n\r\n` and must also flush.
    /// Some gateways emit CRLF; the chunker must recognize both shapes so the
    /// peek sees the complete first frame either way.
    func testFirstPullFlushesAtCRLFFrameBoundary() async throws {
        let frame = Self.qoderFrame(status: 200, content: "hi", lineEnding: "\r\n\r\n")
        let tail = [UInt8](Data(repeating: 0x41, count: 50))
        let stream = [UInt8](frame) + tail
        let iter = ByteIterator(stream)
        var firstPull = true
        let first = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(first, Data(frame), "CRLF frame boundary flushes the first pull")
    }

    // MARK: - First pull: hard cap without a boundary

    /// If no `\n\n`/`\r\n\r\n` ever lands (pathological single-line stream),
    /// the first pull caps at `maxFirstChunk` (8192) rather than blocking
    /// forever. Guards against a giant JSON blob with no SSE framing.
    func testFirstPullRespectsMaxCapWithoutBoundary() async throws {
        // Endless 'A' stream, no newline. The chunker must cap at maxFirstChunk.
        let counter = EndlessByteIterator(byte: 0x41)
        var firstPull = true
        let first = try await QoderGatewayChunker.nextChunk(
            nextByte: { await counter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(first?.count, QoderGatewayChunker.maxFirstChunk, "caps at maxFirstChunk")
        let emitted = await counter.count
        XCTAssertEqual(emitted, QoderGatewayChunker.maxFirstChunk, "pulled exactly maxFirstChunk bytes")
    }

    // MARK: - Subsequent pulls: 8KB bulk threshold

    /// After the first pull, the bulk path flushes at `bulkThreshold` (8192).
    /// Verifies the prior efficiency behavior is preserved for the bulk pump.
    func testSubsequentPullsFlushAtBulkThreshold() async throws {
        // First: a tiny frame to clear the first-pull policy.
        let frame = Self.qoderFrame(status: 200, content: "x")
        // Then a large body: first bulk pull should return exactly 8192.
        let bulk = [UInt8](repeating: 0x42, count: 20_000)
        let stream = [UInt8](frame) + bulk
        let iter = ByteIterator(stream)
        var firstPull = true
        _ = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        let bulkChunk = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertEqual(bulkChunk?.count, QoderGatewayChunker.bulkThreshold, "bulk pull flushes at 8KB")
    }

    /// Empty stream: first pull returns nil at EOF (no bytes, no boundary).
    /// The router maps this to the `.quota` silent-stall branch.
    func testEmptyStreamReturnsNilOnFirstPull() async throws {
        let iter = ByteIterator([])
        var firstPull = true
        let chunk = try await QoderGatewayChunker.nextChunk(
            nextByte: { await iter.next() },
            firstPull: &firstPull
        )
        XCTAssertNil(chunk, "empty stream returns nil on first pull")
    }

    // MARK: - Helpers

    /// Build one Qoder SSE envelope frame ending in `lineEnding`. Mirrors the
    /// shape `probeForUpstreamStatus` parses: `data: {statusCodeValue, body}\n\n`.
    private static func qoderFrame(status: Int, content: String, lineEnding: String = "\n\n") -> Data {
        let inner: [String: Any] = [
            "id": "test",
            "model": "qoder/auto",
            "choices": [["delta": ["content": content]]]
        ]
        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let innerStr = String(data: innerData, encoding: .utf8)!
        let envelope: [String: Any] = ["statusCodeValue": status, "body": innerStr]
        let envelopeData = try! JSONSerialization.data(withJSONObject: envelope)
        let envelopeStr = String(data: envelopeData, encoding: .utf8)!
        return Data("data: \(envelopeStr)\(lineEnding)".utf8)
    }
}

/// Scripted byte provider over a fixed array. `actor` so the `@Sendable`
/// `nextByte` closure the chunker calls can mutate `index` safely. Each `next()`
/// returns one byte and advances, or nil at end.
private actor ByteIterator {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    func next() -> UInt8? {
        guard index < bytes.count else { return nil }
        defer { index += 1 }
        return bytes[index]
    }
}

/// Endless byte provider that always returns the same byte. `actor` so the
/// `@Sendable` closure can read/mutate `count`. Used to test the hard cap.
private actor EndlessByteIterator {
    private let byte: UInt8
    private(set) var count = 0

    init(byte: UInt8) { self.byte = byte }

    func next() -> UInt8 {
        count += 1
        return byte
    }
}
