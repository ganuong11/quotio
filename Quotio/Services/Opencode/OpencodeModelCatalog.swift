//
//  OpencodeModelCatalog.swift
//  Quotio
//
//  Resolves which upstream opencode models are actually free:
//  live GET https://opencode.ai/inference/v1/models ids
//    ∩ models.dev `opencode` models where cost.input == 0 && cost.output == 0
//      && status != "deprecated"
//    − internal models that must never pass the route gate.
//
//  The resolved set is readable synchronously off-actor (ProxyBridge's route
//  gate is nonisolated) via an NSLock-protected box. Persisted snapshots let
//  the gate work offline and through refresh failures: once populated, the
//  list never empties.
//

import Foundation

nonisolated struct OpencodeFreeModel: Sendable, Equatable, Codable {
    let id: String
    let displayName: String?
}

actor OpencodeModelCatalog {
    static let shared = OpencodeModelCatalog()

    static let liveModelsURL = URL(string: "https://opencode.ai/inference/v1/models")!
    static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    /// models.dev api.json is multi-MB; re-fetch at most hourly.
    static let modelsDevTTL: TimeInterval = 3600

    /// Internal models that must never pass the route gate. Task 0 spike:
    /// `jev-1.13` and `jev-1.13-free` appear in the live list (86 models) and
    /// are systemone-internal models, not user-facing free tier.
    private static func isExcluded(_ id: String) -> Bool {
        id.hasPrefix("jev-") || id.contains("systemone")
    }

    /// Lock-protected resolved set for synchronous route-gate reads.
    final class ResolvedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: [OpencodeFreeModel] = []
        private var _ids: Set<String> = []

        var models: [OpencodeFreeModel] { lock.withLock { _models } }
        var isEmpty: Bool { lock.withLock { _models.isEmpty } }

        func set(_ models: [OpencodeFreeModel]) {
            lock.withLock {
                _models = models
                _ids = Set(models.map(\.id))
            }
        }

        func contains(_ id: String) -> Bool { lock.withLock { _ids.contains(id) } }
    }

    struct ModelsDevSnapshot: Codable {
        struct Entry: Codable {
            let name: String?
            let status: String?
            let costInput: Double?
            let costOutput: Double?
        }
        var fetchedAt: Date
        var entries: [String: Entry]
    }

    private struct CatalogSnapshot: Codable {
        var fetchedAt: Date
        var models: [OpencodeFreeModel]
    }

    nonisolated private let box = ResolvedBox()

    private let session: URLSession
    private let storageDirectory: URL
    private var modelsDevSnapshot: ModelsDevSnapshot?

    static var defaultStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Opencode", isDirectory: true)
    }

    init(session: URLSession = .shared, storageDirectory: URL = OpencodeModelCatalog.defaultStorageDirectory) {
        self.session = session
        self.storageDirectory = storageDirectory
    }

    // MARK: - synchronous route-gate surface

    nonisolated var models: [OpencodeFreeModel] { box.models }
    nonisolated var isEmpty: Bool { box.isEmpty }
    nonisolated func isFree(_ modelID: String) -> Bool { box.contains(modelID) }

    // MARK: - refresh

    private var catalogURL: URL { storageDirectory.appendingPathComponent("catalog-v1.json") }
    private var modelsDevCacheURL: URL { storageDirectory.appendingPathComponent("modelsdev-cache-v1.json") }

    func refresh() async {
        guard let liveIDs = await fetchLiveModels() else {
            Log.quota("opencode catalog: live model fetch failed; keeping current list")
            return
        }
        guard let snapshot = await modelsDevEntries() else {
            Log.quota("opencode catalog: models.dev unavailable and no cache; keeping current list")
            return
        }
        let resolved = resolve(liveIDs: liveIDs, snapshot: snapshot)
        box.set(resolved)
        persist(resolved)
    }

    private func resolve(liveIDs: [String], snapshot: ModelsDevSnapshot) -> [OpencodeFreeModel] {
        liveIDs.compactMap { id in
            guard let entry = snapshot.entries[id],
                  entry.status != "deprecated",
                  entry.costInput == 0, entry.costOutput == 0,
                  !Self.isExcluded(id) else { return nil }
            return OpencodeFreeModel(id: id, displayName: entry.name)
        }.sorted { $0.id < $1.id }
    }

    private func fetchLiveModels() async -> [String]? {
        do {
            let (data, response) = try await session.data(from: Self.liveModelsURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else { return nil }
            return list.compactMap { ($0["id"] as? String)?.nilIfBlank }
        } catch {
            return nil
        }
    }

    private func modelsDevEntries() async -> ModelsDevSnapshot? {
        if let snapshot = modelsDevSnapshot,
           Date().timeIntervalSince(snapshot.fetchedAt) < Self.modelsDevTTL {
            return snapshot
        }
        if let fresh = await fetchModelsDev() {
            modelsDevSnapshot = fresh
            persistModelsDev(fresh)
            return fresh
        }
        // stale cache is better than no cache
        if modelsDevSnapshot == nil, let persisted = loadPersistedModelsDev() {
            modelsDevSnapshot = persisted
        }
        return modelsDevSnapshot
    }

    private func fetchModelsDev() async -> ModelsDevSnapshot? {
        do {
            let (data, response) = try await session.data(from: Self.modelsDevURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let provider = json["opencode"] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { return nil }
            var entries: [String: ModelsDevSnapshot.Entry] = [:]
            for (id, raw) in models {
                guard let model = raw as? [String: Any] else { continue }
                let cost = model["cost"] as? [String: Any]
                entries[id] = ModelsDevSnapshot.Entry(
                    name: model["name"] as? String,
                    status: model["status"] as? String,
                    costInput: (cost?["input"] as? NSNumber)?.doubleValue,
                    costOutput: (cost?["output"] as? NSNumber)?.doubleValue
                )
            }
            return ModelsDevSnapshot(fetchedAt: Date(), entries: entries)
        } catch {
            return nil
        }
    }

    // MARK: - persistence

    private func persist(_ models: [OpencodeFreeModel]) {
        try? SecureAtomicFileWriter.write(
            JSONEncoder().encode(CatalogSnapshot(fetchedAt: Date(), models: models)),
            to: catalogURL
        )
    }

    private func persistModelsDev(_ snapshot: ModelsDevSnapshot) {
        try? SecureAtomicFileWriter.write(JSONEncoder().encode(snapshot), to: modelsDevCacheURL)
    }

    private func loadPersistedModelsDev() -> ModelsDevSnapshot? {
        guard let data = FileManager.default.contents(atPath: modelsDevCacheURL.path) else { return nil }
        return try? JSONDecoder().decode(ModelsDevSnapshot.self, from: data)
    }

    /// Startup warmup: load the persisted snapshot, then refresh from the
    /// network — serialized inside the actor so a slow persisted load can
    /// never land on top of a faster refresh (the two used to run as
    /// independent tasks at proxy start and could finish out of order).
    func prime() async {
        loadPersisted()
        await refresh()
    }

    /// Load the persisted snapshot (offline start). Called once at app/proxy start.
    func loadPersisted() {
        if modelsDevSnapshot == nil {
            modelsDevSnapshot = loadPersistedModelsDev()
        }
        guard let data = FileManager.default.contents(atPath: catalogURL.path),
              let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) else { return }
        box.set(snapshot.models)
    }
}
