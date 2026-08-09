//
//  QoderGatewayStreamTests.swift
//  QuotioTests
//
//  Tests for ADR 0012 (issue #22): the Qoder pump is cancelled promptly on
//  agent disconnect, and `QoderGatewayStream.cancel()` tears down the upstream
//  URLSession task rather than letting it drain until the next `sendToAgent`
//  happens to fail.
//
//  The ProxyBridge-side wiring (`pumpTasks[connectionId]` insert/remove + the
//  `stateUpdateHandler` fold in `handleNewConnection`) is tied to live
//  `NWConnection`s and is covered by manual/integration verification, matching
//  the precedent set by QoderResponsesWiringTests. These tests pin the CONTRACT
//  that wiring depends on, at the stream seam:
//    - `cancel()` is idempotent and fires the teardown exactly once;
//    - `pump` checks cooperative cancellation each iteration and calls
//      `cancel()` on EVERY exit path (normal end, early-stop, error,
//      cancellation) so the URLSession never outlives its reader.
//

import XCTest
@testable import Quotio

final class QoderGatewayStreamTests: XCTestCase {

    // MARK: - Helpers

    private func gatewayURL() -> URL {
        URL(string: "https://api3.qoder.sh/v1/chat/completions")!
    }

    private func httpResponse(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: gatewayURL(),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    // MARK: - cancel()

    func testCancelFiresTeardownExactlyOnce() {
        // The disconnect-driven cancel (stateUpdateHandler → pump Task cancel →
        // pump's defer) can race an explicit cancel; `cancel()` must be
        // idempotent so the URLSession task is torn down exactly once.
        let spy = CancelSpy()
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in nil }

        stream.cancel()
        stream.cancel()
        stream.cancel()

        XCTAssertEqual(spy.count, 1)
    }

    func testTestStreamWithoutOnCancelStillCancels() {
        // Test streams built with the pre-ADR-0012 `init(response:source:)`
        // convenience have a no-op teardown; `cancel()` must not crash and
        // must stay idempotent.
        let stream = QoderGatewayStream(response: httpResponse()) { () -> Data? in nil }
        stream.cancel()
        stream.cancel()
    }

    // MARK: - pump teardown on every exit path

    func testPumpNormalCompletionCancelsStream() async throws {
        // Normal end: source yields two buffers then nil. The pump must deliver
        // both and still tear down the URLSession on exit.
        let spy = CancelSpy()
        let box = OneShotBox(chunks: [Data("a".utf8), Data("b".utf8)])
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in await box.next() }

        var received: [Data] = []
        let receivedBox = ReceivedBox()
        try await stream.pump { chunk in
            await receivedBox.append(chunk)
            return true
        }
        received = await receivedBox.all

        XCTAssertEqual(received, [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(spy.count, 1)
    }

    func testPumpEarlyStopCancelsStream() async throws {
        // Early-stop (`onChunk` returned false — e.g. agent went away): the
        // pump must stop pulling AND tear down the upstream, not abandon a
        // still-running URLSession.
        let spy = CancelSpy()
        let box = OneShotBox(chunks: [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in await box.next() }

        let receivedBox = ReceivedBox()
        try await stream.pump { chunk in
            await receivedBox.append(chunk)
            return false // stop after the first buffer
        }

        let received = await receivedBox.all
        XCTAssertEqual(received, [Data("a".utf8)])
        XCTAssertEqual(spy.count, 1)
    }

    func testPumpTransportErrorCancelsStream() async {
        // Thrown transport failure: the error must propagate AND the upstream
        // must be torn down (the defer covers the throw path).
        struct TransportFailure: Error {}
        let spy = CancelSpy()
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in throw TransportFailure() }

        await XCTAssertThrowsErrorAsync {
            try await stream.pump { _ in true }
        }
        XCTAssertEqual(spy.count, 1)
    }

    func testPumpTaskCancellationThrowsPromptlyAndCancelsStream() async throws {
        // The load-bearing ADR 0012 behavior: cancelling the pump Task (as the
        // agent connection's stateUpdateHandler now does on disconnect) must
        // surface promptly even when the next `source()` pull is blocked on a
        // slow upstream — and must tear the upstream down. The source blocks
        // 60s unless itself cancelled (modeling URLSession.AsyncBytes.next(),
        // which propagates cancellation).
        let spy = CancelSpy()
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return nil
        }

        let pumpTask = Task {
            try await stream.pump { _ in true }
        }
        // Let the pump enter the blocking pull before cancelling.
        try await Task.sleep(nanoseconds: 50_000_000)
        pumpTask.cancel()

        let start = Date()
        do {
            try await pumpTask.value
            XCTFail("pump should throw on cooperative cancellation")
        } catch {
            // CancellationError (from the checkCancellation/pull) — expected.
        }
        // Prompt: nowhere near the 60s blocked pull. 5s is generous headroom.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        XCTAssertEqual(spy.count, 1)
    }

    func testPumpDoesNotPullAfterCancellation() async throws {
        // Cancellation must stop consumption, not just teardown: no pull after
        // the cancel (the per-iteration checkCancellation runs before each
        // pull).
        let spy = CancelSpy()
        let box = OneShotBox(chunks: [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        let stream = QoderGatewayStream(
            response: httpResponse(),
            onCancel: { spy.record() }
        ) { () -> Data? in await box.next() }

        let pumpTask = Task {
            try await stream.pump { _ in
                // Stop after the first buffer; then cancel before resuming.
                try await Task.sleep(nanoseconds: 10_000_000)
                return true
            }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        pumpTask.cancel()
        do {
            try await pumpTask.value
            XCTFail("pump should throw on cooperative cancellation")
        } catch {
            // Expected.
        }
        let pulls = await box.pulls
        XCTAssertEqual(pulls, 1)
        XCTAssertEqual(spy.count, 1)
    }
}

// MARK: - Test boxes

/// Counts `cancel()` firings. `@unchecked Sendable` like the sibling mock
/// boxes in QoderFailoverRouterTests; mutations are lock-guarded.
private final class CancelSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func record() {
        lock.lock()
        _count += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}

/// Yields each scripted chunk once across pulls, then nil (stream end).
/// Mirrors MockTrickleBox in QoderFailoverRouterTests.
private actor OneShotBox {
    private let chunks: [Data]
    private var index = 0
    private(set) var pulls = 0

    init(chunks: [Data]) { self.chunks = chunks }

    func next() -> Data? {
        pulls += 1
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
}

/// Collects the buffers the pump delivered, from inside the `@Sendable`
/// receiver closure.
private actor ReceivedBox {
    private var buffers: [Data] = []
    func append(_ data: Data) { buffers.append(data) }
    var all: [Data] { buffers }
}

/// `XCTAssertThrowsError` has no async variant; minimal async equivalent.
private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
