//
//  QoderWAFEncoderTests.swift
//  QuotioTests
//
//  Golden-vector tests for the Phase 2a WAF encoder (ticket #5). Every
//  expected value was captured by running pi-provider-qoder's `qoderEncodeBody`
//  (src/qoder-encoding.ts) on the same inputs, so a passing suite means the
//  Swift port is byte-identical to the TypeScript reference.
//

import XCTest
@testable import Quotio

final class QoderWAFEncoderTests: XCTestCase {
    // (input, expected encoded output) — captured from pi's qoderEncodeBody.
    private static let goldenVectors: [(String, String)] = [
        ("", ""),                              // empty → empty
        ("a", "$p$#"),                         // base64 padding → `$`
        ("hello", "q$FruHPH"),
        ("hello world", "YuHp$Hq&J(WPHFru"),
        ("test input", ".J_$$od)uEdJHF^J"),
        ("input A", "pp$$Jxp&PSQf"),
        ("input B", "p&$$Jxp&PSQf"),           // 1-char input change → different output
        ("The quick brown fox", "hBHDbm_$$SjUBHKYukJFHiLBZg.P"),
        ("{\"key\":\"value\",\"num\":42}", "Q.u,ByjRKWK(#S%.D,BrBOmYKUDxz*l*"),
    ]

    /// Byte-exact parity with pi across the structural cases from
    /// `qoder-encoding.test.ts`. If any of these fail, the Swift port has
    /// diverged from the reference and the gateway will reject the body.
    func testGoldenVectorsMatchReference() throws {
        for (input, expected) in Self.goldenVectors {
            let actual = QoderWAFEncoder.encode(input)
            XCTAssertEqual(actual, expected, "WAF encode mismatch for input \(input.debugDescription)")
        }
    }

    /// Data in / String out must equal String in / String out for the same
    /// bytes — the production caller passes the JSON body as `Data`.
    func testDataOverloadMatchesStringOverload() throws {
        for (input, _) in Self.goldenVectors where !input.isEmpty {
            let fromData = QoderWAFEncoder.encode(Data(input.utf8))
            let fromString = QoderWAFEncoder.encode(input)
            XCTAssertEqual(fromData, fromString)
        }
    }

    /// Binary content (bytes outside the ASCII base64 alphabet) round-trips
    /// through the same pipeline. Vector captured from pi.
    func testHandlesBinaryContent() throws {
        let bytes: [UInt8] = [0x00, 0xff, 0x80, 0x7f, 0x01]
        XCTAssertEqual(QoderWAFEncoder.encode(Data(bytes)), "T$A_ef_v")
    }

    /// The encoded output never contains `=` — base64 padding is always mapped
    /// to `$`. This is the structural property `qoder-encoding.test.ts`
    /// asserts on every input.
    func testOutputNeverContainsPaddingEquals() {
        let inputs = ["a", "ab", "abc", "abcd", "hello world", String(repeating: "x", count: 100)]
        for input in inputs {
            XCTAssertFalse(QoderWAFEncoder.encode(input).contains("="), "padding leaked for \(input)")
        }
    }

    /// Determinism: same input → same output across calls (no hidden state).
    func testDeterministic() {
        XCTAssertEqual(QoderWAFEncoder.encode("test input"), QoderWAFEncoder.encode("test input"))
    }

    /// Distinctness: distinct inputs → distinct outputs (sanity — guards
    /// against a constant-output bug in the port).
    func testDistinctInputsProduceDistinctOutputs() {
        XCTAssertNotEqual(QoderWAFEncoder.encode("input A"), QoderWAFEncoder.encode("input B"))
    }
}
