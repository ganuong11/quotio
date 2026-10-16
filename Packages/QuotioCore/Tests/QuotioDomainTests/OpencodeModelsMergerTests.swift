//
//  OpencodeModelsMergerTests.swift
//  QuotioTests
//

import Foundation
import XCTest
@testable import QuotioDomain

final class OpencodeModelsMergerTests: XCTestCase {

    private func cpaBody(_ ids: [String]) -> Data {
        let entries = ids.map {
            ["id": $0, "object": "model", "created": 1700000000, "owned_by": "test"] as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: ["object": "list", "data": entries])
    }

    private func mergedIDs(_ body: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return nil }
        return data.compactMap { $0["id"] as? String }
    }

    func testMergeAppendsNamespacedEntries() {
        let merged = OpencodeModelsMerger.mergeOpencodeModels(
            into: cpaBody(["gpt-4o"]),
            models: [
                OpencodeFreeModel(id: "big-pickle", displayName: "Big Pickle"),
                OpencodeFreeModel(id: "cat-jam-free", displayName: nil),
            ])
        let ids = mergedIDs(merged!)
        XCTAssertEqual(ids, ["gpt-4o", "opencode/big-pickle", "opencode/cat-jam-free"])
    }

    func testMergedEntryShape() {
        let merged = OpencodeModelsMerger.mergeOpencodeModels(
            into: cpaBody([]),
            models: [OpencodeFreeModel(id: "big-pickle", displayName: nil)])!
        let json = try! JSONSerialization.jsonObject(with: merged) as! [String: Any]
        XCTAssertEqual(json["object"] as? String, "list")
        let entry = (json["data"] as! [[String: Any]]).first!
        XCTAssertEqual(entry["id"] as? String, "opencode/big-pickle")
        XCTAssertEqual(entry["object"] as? String, "model")
        XCTAssertEqual(entry["owned_by"] as? String, "opencode")
        XCTAssertNotNil(entry["created"] as? Int)
    }

    func testExistingIDsNotDuplicated() {
        let merged = OpencodeModelsMerger.mergeOpencodeModels(
            into: cpaBody(["opencode/big-pickle"]),
            models: [OpencodeFreeModel(id: "big-pickle", displayName: nil)])!
        XCTAssertEqual(mergedIDs(merged), ["opencode/big-pickle"])
    }

    func testMalformedBodyReturnsNil() {
        XCTAssertNil(OpencodeModelsMerger.mergeOpencodeModels(
            into: Data("not json".utf8),
            models: [OpencodeFreeModel(id: "a", displayName: nil)]))
        XCTAssertNil(OpencodeModelsMerger.mergeOpencodeModels(
            into: Data(#"[{"id":"x"}]"#.utf8),
            models: [OpencodeFreeModel(id: "a", displayName: nil)]))
        XCTAssertNil(OpencodeModelsMerger.mergeOpencodeModels(
            into: Data(#"{"object":"list"}"#.utf8),
            models: [OpencodeFreeModel(id: "a", displayName: nil)]))
    }

    /// extractHTTPBody is shared with the Qoder merger; pin that a chunked
    /// upstream response round-trips into the merger.
    func testExtractHTTPBodyRoundTripsChunked() {
        let payload = #"{"object":"list","data":[{"id":"x"}]}"#
        var response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        response.append(Data(String(format: "%x\r\n", payload.utf8.count).utf8))
        response.append(Data(payload.utf8))
        response.append(Data("\r\n0\r\n\r\n".utf8))
        let body = QoderModelsMerger.extractHTTPBody(from: response)
        XCTAssertNotNil(body)
        XCTAssertNotNil(OpencodeModelsMerger.mergeOpencodeModels(
            into: body!, models: [OpencodeFreeModel(id: "a", displayName: nil)]))
    }
}
