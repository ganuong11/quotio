//
//  OpencodeDetectedCache.swift
//  QuotioCore
//
//  Lock-protected cache for the detected-credential snapshot the router
//  reads per request (the `detectedSnapshot` closure must be synchronous —
//  `OpencodeRouter` can't suspend to disk mid-candidate-enumeration). A
//  periodic refresh swaps the snapshot; `snapshot()` is the cheap
//  synchronous read wired into the router.
//

import Foundation

public nonisolated final class OpencodeDetectedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [DetectedOpencodeCredential] = []

    public init() {}

    /// Re-run filesystem discovery and swap the snapshot.
    public func refresh() {
        let found = OpencodeCredentialDetector.discover()
        lock.lock()
        credentials = found
        lock.unlock()
    }

    public func snapshot() -> [DetectedOpencodeCredential] {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }
}
