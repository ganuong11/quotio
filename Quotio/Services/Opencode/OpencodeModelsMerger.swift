//
//  OpencodeModelsMerger.swift
//  Quotio
//
//  Merge the resolved opencode free-model catalog into the OpenAI
//  `GET /v1/models` response that CPA returns — the sibling of
//  QoderModelsMerger (issue #10, ADR 0016) for the `opencode/` namespace.
//  Without this, CLI agents cannot auto-discover `opencode/<id>` models:
//  CPA's registry does not know them.
//
//  Pure, side-effect-free: takes CPA's already-fetched body bytes and
//  returns merged body bytes, or nil to signal "forward CPA's bytes
//  unchanged" — model discovery must never break. The HTTP framing helper
//  `QoderModelsMerger.extractHTTPBody` is shared with the Qoder merger.
//

import Foundation

nonisolated enum OpencodeModelsMerger {

    /// The namespace prefix every merged model id carries — matches
    /// `OpencodeRouteGate.opencodePrefix`.
    static let namespacePrefix = "opencode/"

    static let ownedBy = "opencode"

    /// Fixed `created` epoch stamped on merged entries — 2026-10-15 UTC
    /// (verified `date -j -u -f "%Y-%m-%d" 2026-10-15 +%s` → 1792064400),
    /// matching the live upstream `created` values observed in the Task 0
    /// spike. A constant keeps merged output byte-stable.
    static let catalogEpoch: Int = 1_792_064_400

    /// Merge opencode free models into CPA's `GET /v1/models` body.
    /// Returns nil when the body is unparseable or not the models-list shape
    /// (caller forwards CPA's bytes unchanged).
    static func mergeOpencodeModels(
        into cpaBody: Data,
        models: [OpencodeFreeModel]
    ) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: cpaBody) as? [String: Any],
              let data = root["data"] as? [Any] else {
            return nil
        }
        var existingIDs = Set<String>()
        for entry in data {
            if let dict = entry as? [String: Any], let id = dict["id"] as? String {
                existingIDs.insert(id)
            }
        }
        var mergedData = data
        for model in models {
            let namespacedID = namespacePrefix + model.id
            if existingIDs.contains(namespacedID) { continue }
            mergedData.append([
                "id":       namespacedID,
                "object":   "model",
                "created":  catalogEpoch,
                "owned_by": ownedBy,
            ])
        }
        var mergedRoot = root
        mergedRoot["data"] = mergedData
        return try? JSONSerialization.data(withJSONObject: mergedRoot)
    }
}
