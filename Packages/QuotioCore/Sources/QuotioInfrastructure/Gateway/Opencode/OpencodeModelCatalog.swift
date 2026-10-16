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
//  Each resolved model also carries its NATIVE upstream surface (ADR 0021),
//  derived from models.dev npm metadata: per-model `provider.npm` override,
//  else the provider-level `npm`, else chat. The router dispatches on it;
//  `/v1/models` advertises only models servable on a client-facing surface.
//
//  The resolved set is readable synchronously off-actor (ProxyBridge's route
//  gate is nonisolated) via an NSLock-protected box. Persisted snapshots let
//  the gate work offline and through refresh failures: once populated, the
//  list never empties. v1 snapshots (pre-surface) decode with surface nil and
//  resolve to `.chat` at lookup — a legacy-default window that the startup
//  refresh closes in seconds.
//

import Foundation
import QuotioApplication
import QuotioDomain

/// The upstream protocol surface a model is native to (ADR 0021). Only
/// `chat` and `responses` have client-facing surfaces today; the others are
/// refused with 422 `unsupported_surface` and never advertised.
public nonisolated enum OpencodeSurface: String, Sendable, Codable, Equatable {
    case chat
    case responses
    case messages
    case gemini
    case mistral

    /// models.dev `provider.npm` → surface. Unknown/missing → `chat`: the
    /// provider-level default is `@ai-sdk/openai-compatible`, which is the
    /// chat surface.
    public init(npm: String?) {
        switch npm {
        case "@ai-sdk/openai": self = .responses
        case "@ai-sdk/anthropic": self = .messages
        case "@ai-sdk/google": self = .gemini
        case "@ai-sdk/mistral": self = .mistral
        default: self = .chat
        }
    }

    /// Whether Quotio can serve requests for a model with this native
    /// surface (passthrough or translation). Drives `/v1/models` filtering.
    public var isServable: Bool { self == .chat || self == .responses }
}

public nonisolated struct OpencodeFreeModel: Sendable, Equatable, Codable {
    public let id: String
    public let displayName: String?
    /// Native upstream surface. Nil only for pre-ADR-0021 persisted snapshots
    /// (resolved to `.chat` at lookup until the next refresh re-derives it).
    public let surface: OpencodeSurface?

    public init(id: String, displayName: String?, surface: OpencodeSurface? = nil) {
        self.id = id
        self.displayName = displayName
        self.surface = surface
    }
}

public actor OpencodeModelCatalog {
    public static let liveModelsURL = URL(string: "https://opencode.ai/inference/v1/models")!
    public static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    /// models.dev api.json is multi-MB; re-fetch at most hourly.
    public static let modelsDevTTL: TimeInterval = 3600

    /// Internal models that must never pass the route gate. Task 0 spike:
    /// `jev-1.13` and `jev-1.13-free` appear in the live list (86 models) and
    /// are systemone-internal models, not user-facing free tier.
    private static func isExcluded(_ id: String) -> Bool {
        id.hasPrefix("jev-") || id.contains("systemone")
    }

    /// Lock-protected resolved set for synchronous route-gate reads.
    public final class ResolvedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: [OpencodeFreeModel] = []
        private var _ids: Set<String> = []
        private var _surfaces: [String: OpencodeSurface] = [:]

        public var models: [OpencodeFreeModel] { lock.withLock { _models } }
        public var isEmpty: Bool { lock.withLock { _models.isEmpty } }
        /// Models servable on a client-facing surface — the `/v1/models`
        /// advertisement set (ADR 0021: never advertise what we can't serve).
        public var advertisedModels: [OpencodeFreeModel] {
            lock.withLock { _models.filter { ($0.surface ?? .chat).isServable } }
        }

        public func set(_ models: [OpencodeFreeModel]) {
            lock.withLock {
                _models = models
                _ids = Set(models.map(\.id))
                _surfaces = Dictionary(uniqueKeysWithValues: models.map {
                    ($0.id, $0.surface ?? .chat)
                })
            }
        }

        public func contains(_ id: String) -> Bool { lock.withLock { _ids.contains(id) } }
        /// Native surface for a model id; `.chat` when unknown or when the
        /// entry predates surface capture (legacy snapshot default).
        public func surface(_ id: String) -> OpencodeSurface {
            lock.withLock { _surfaces[id] ?? .chat }
        }
    }

    public struct ModelsDevSnapshot: Codable {
        public struct Entry: Codable {
            public let name: String?
            public let status: String?
            public let costInput: Double?
            public let costOutput: Double?
            /// Per-model `provider.npm` override (ADR 0021 surface source).
            /// Nil on pre-surface caches and on models without an override.
            public let npm: String?
        }
        /// Provider-level `npm` fallback. Optional so pre-surface caches
        /// (which lack the field) still decode.
        public var providerNpm: String?
        public var fetchedAt: Date
        public var entries: [String: Entry]
    }

    private struct CatalogSnapshot: Codable {
        public var fetchedAt: Date
        var models: [OpencodeFreeModel]
    }

    private nonisolated let box = ResolvedBox()

    private let session: URLSession
    private let storageDirectory: URL
    private let logger: (any ApplicationLogging)?
    private var modelsDevSnapshot: ModelsDevSnapshot?

    public static func defaultStorageDirectory(identity: RuntimeIdentity) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Gateway/Opencode", isDirectory: true)
    }

    public init(identity: RuntimeIdentity, logger: (any ApplicationLogging)? = nil) {
        self.session = URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 30))
        self.storageDirectory = Self.defaultStorageDirectory(identity: identity)
        self.logger = logger
    }

    public init(
        session: URLSession = URLSession(configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 30)),
        storageDirectory: URL,
        logger: (any ApplicationLogging)? = nil
    ) {
        self.session = session
        self.storageDirectory = storageDirectory
        self.logger = logger
    }

    // MARK: - synchronous route-gate surface

    public nonisolated var models: [OpencodeFreeModel] { box.models }
    public nonisolated var advertisedModels: [OpencodeFreeModel] { box.advertisedModels }
    public nonisolated var isEmpty: Bool { box.isEmpty }
    public nonisolated func isFree(_ modelID: String) -> Bool { box.contains(modelID) }
    public nonisolated func surface(for modelID: String) -> OpencodeSurface { box.surface(modelID) }

    // MARK: - refresh

    /// v2 carries per-model surfaces (ADR 0021). v1 files are still read as
    /// an upgrade fallback — their entries decode surface-less and resolve
    /// to `.chat` until the first refresh.
    private var catalogURL: URL { storageDirectory.appendingPathComponent("catalog-v2.json") }
    private var legacyCatalogURL: URL { storageDirectory.appendingPathComponent("catalog-v1.json") }
    private var modelsDevCacheURL: URL { storageDirectory.appendingPathComponent("modelsdev-cache-v1.json") }

    public func refresh() async {
        guard let liveIDs = await fetchLiveModels() else {
            await logger?.write(.warning, message: "opencode catalog: live model fetch failed; keeping current list")
            return
        }
        guard let snapshot = await modelsDevEntries() else {
            await logger?.write(.warning, message: "opencode catalog: models.dev unavailable and no cache; keeping current list")
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
            return OpencodeFreeModel(
                id: id,
                displayName: entry.name,
                surface: OpencodeSurface(npm: entry.npm ?? snapshot.providerNpm))
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
                    costOutput: (cost?["output"] as? NSNumber)?.doubleValue,
                    npm: (model["provider"] as? [String: Any])?["npm"] as? String
                )
            }
            return ModelsDevSnapshot(
                providerNpm: provider["npm"] as? String,
                fetchedAt: Date(),
                entries: entries)
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
    public func prime() async {
        loadPersisted()
        await refresh()
    }

    /// Load the persisted snapshot (offline start). Called once at app/proxy
    /// start. v2 first; a lingering v1 file is the pre-surface upgrade
    /// fallback (its entries resolve to `.chat` until the next refresh).
    public func loadPersisted() {
        if modelsDevSnapshot == nil {
            modelsDevSnapshot = loadPersistedModelsDev()
        }
        let data = FileManager.default.contents(atPath: catalogURL.path)
            ?? FileManager.default.contents(atPath: legacyCatalogURL.path)
        guard let data, let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) else {
            return
        }
        box.set(snapshot.models)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
