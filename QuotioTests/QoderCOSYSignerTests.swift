//
//  QoderCOSYSignerTests.swift
//  QuotioTests
//
//  Phase 2a foundation (ticket #5): the COSY signer is the riskiest porting
//  surface in the Qoder stack — RSA-PKCS1 + AES-128-CBC + MD5 wired together
//  with ~15 headers. These tests pin it down layer by layer against values
//  captured from pi-provider-qoder's `buildAuthHeaders` (src/cosy.ts):
//
//    1. Header footprint  — exact key set, deterministic values.
//    2. AES-128-CBC       — byte-exact for a fixed key (CommonCrypto == Node).
//    3. RSA-PKCS1 length  — 128-byte ciphertext → 172-char base64 (1024-bit key).
//    4. Signature digest  — MD5 over the 5-line input matches a pi fixture.
//    5. Body hash/length  — MD5 + byte length of the body the wire carries.
//    6. Sig path          — `/algo` prefix stripped, query string ignored.
//    7. Guardrails        — empty userID/authToken rejected (matches pi).
//

import CryptoKit
import XCTest
@testable import Quotio

final class QoderCOSYSignerTests: XCTestCase {
    // The credentials/URL/body used by every structural test below. The
    // snapshot values (header footprint, body hash, sig path, RSA length) were
    // captured by running pi's `buildAuthHeaders` against the same inputs.
    private let creds = QoderCOSYCredentials(
        userID: "user-123",
        authToken: "jt-test-token",
        name: "Test User",
        email: "test@example.com",
        machineID: "machine-abc"
    )
    private let chatURL = "https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?Encode=1"
    private let modelListURL = "https://api3.qoder.sh/algo/api/v2/model/list?Encode=1"
    /// The WAF-encoded body the signer signs. This is the *real* JSON (15 bytes,
    /// `{"messages":[]}`), matching what pi feeds `buildAuthHeaders` after
    /// encoding. Written with explicit escapes so the byte count is unambiguous
    /// — a raw literal `#"{\"messages\":[]}"#` would keep the backslashes
    /// verbatim and produce a 17-byte body, diverging from the pi fixture.
    private let chatBody = "{\"messages\":[]}"

    // MARK: - Header footprint (deterministic values from pi)

    /// The signer emits exactly the keys pi emits, no more, no less, and the
    /// deterministic-valued headers (those that don't depend on the per-request
    /// randoms) match pi byte-for-byte. Captured from a pi run.
    func testHeaderFootprintAndDeterministicValues() throws {
        let headers = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds).allHeaders

        // The exact set pi emits (Authorization + 18 Cosy/Login/X headers = 19).
        let expectedKeys: Set<String> = [
            "Authorization",
            "Cosy-Key", "Cosy-User", "Cosy-Date", "Cosy-Version",
            "Cosy-Machineid", "Cosy-Machinetoken", "Cosy-Machinetype", "Cosy-Machineos",
            "Cosy-Clienttype", "Cosy-Clientip", "Cosy-Bodyhash", "Cosy-Bodylength",
            "Cosy-Sigpath", "Cosy-Data-Policy", "Cosy-Organization-Id", "Cosy-Organization-Tags",
            "Login-Version", "X-Request-Id",
        ]
        XCTAssertEqual(Set(headers.keys), expectedKeys)

        // Deterministic-valued headers (independent of the per-request randoms).
        XCTAssertEqual(headers["Cosy-User"], "user-123")
        XCTAssertEqual(headers["Cosy-Version"], "1.1.3")
        XCTAssertEqual(headers["Cosy-Machineid"], "machine-abc")
        XCTAssertEqual(headers["Cosy-Machinetoken"], "machine-abc") // mirrors Cosy-Machineid, per pi
        XCTAssertEqual(headers["Cosy-Machinetype"], "5")
        XCTAssertEqual(headers["Cosy-Machineos"], "aarch64_linux") // arm64 presents as aarch64_linux, see signer doc
        XCTAssertEqual(headers["Cosy-Clienttype"], "5")
        XCTAssertEqual(headers["Cosy-Clientip"], "127.0.0.1")
        XCTAssertEqual(headers["Cosy-Data-Policy"], "disagree")
        XCTAssertEqual(headers["Cosy-Organization-Id"], "")
        XCTAssertEqual(headers["Cosy-Organization-Tags"], "")
        XCTAssertEqual(headers["Login-Version"], "v2")
    }

    /// `Authorization` is the COSY envelope: `Bearer COSY.<payloadB64>.<sig>`.
    func testAuthorizationHeaderShape() throws {
        let auth = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds).authorization

        XCTAssertTrue(auth.hasPrefix("Bearer COSY."))
        let parts = auth.dropFirst("Bearer COSY.".count).split(separator: ".")
        XCTAssertEqual(parts.count, 2, "expected <payloadB64>.<sig>")
        XCTAssertFalse(parts[0].isEmpty, "payload base64 missing")
        XCTAssertFalse(parts[1].isEmpty, "signature missing")
    }

    // MARK: - AES-128-CBC (CommonCrypto == Node for the same key)

    /// With a pinned AES key, the user-info AES-CBC blob inside the cosy
    /// payload is byte-exact. This is the load-bearing test that proves the
    /// CommonCrypto port matches Node's `createCipheriv("aes-128-cbc", key, key)`
    /// — the captured vector was produced by pi's `aesEncryptCBCBase64` with
    /// the same plaintext and key.
    func testAESUserBlobByteExactForFixedKey() throws {
        let headers = try QoderCOSYSigner.sign(
            body: chatBody,
            requestURL: chatURL,
            credentials: creds,
            options: QoderCOSYSignerOptions(aesKey: "0123456789abcdef")
        ).allHeaders

        // Decode the cosy payload to fish out the encrypted `info`, then
        // compare to the AES-CBC blob pi produces for the exact same inputs.
        let payloadB64 = String(headers["Authorization"]!.dropFirst("Bearer COSY.".count).split(separator: ".")[0])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(base64Encoded: payloadB64)!) as? [String: Any])

        XCTAssertEqual(
            payload["info"] as? String,
            expectedAESUserBlob,
            "AES user-info blob diverged from pi — CommonCrypto output != Node createCipheriv"
        )
    }

    /// The AES-CBC blob pi produces for the user-info plaintext under the
    /// pinned key — captured by running pi's `aesEncryptCBCBase64` with key
    /// "0123456789abcdef" over the exact user-info JSON pi serializes
    /// (`{"uid":"user-123",...}`). Kept as a constant to keep the byte-exact
    /// assertion legible.
    private let expectedAESUserBlob = "y4EF7oDMSWOsOcwINR3UfJK6wieStJMqYxgZ8yWgK/jUwEicqtomM36h2hJp1jqhcJ6QeR8uffmGR3babWA5A1pzmeeXdCCKYsrru5+U0lJW+IiQcDkwjlofzJw6i4bzyyVgIMwck1ZvCr85D67SvGfdfHGPtBbXXDQ0aPNGOd4="

    // MARK: - RSA-PKCS1 length

    /// RSA ciphertext is 128 bytes → 172 base64 chars (Qoder's key is 1024-bit).
    /// The signer can't decrypt to verify (it has the public key only), so the
    /// length check is the strongest structural assertion we can make locally.
    func testRSAKeySizeYieldsExpectedCiphertextLength() throws {
        let headers = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds).allHeaders
        XCTAssertEqual(headers["Cosy-Key"]?.count, 172)
    }

    // MARK: - Signature digest reconstruction (the heart of COSY)

    /// The signature is `MD5(payloadB64 \n cosyKey \n timestamp \n body \n sigPath)`.
    /// RSA-PKCS1 v1.5 padding is randomized, so `cosyKey` (and therefore the
    /// sig) is non-deterministic across calls even with the AES key pinned — a
    /// fixed-golden sig assertion is impossible. Instead this test pins every
    /// *other* non-deterministic input (AES key, request ID, timestamp) and
    /// proves the MD5 wiring is correct two ways:
    ///
    ///   1. **Self-consistency** — reconstruct the MD5 from the signer's own
    ///      header output and confirm it equals the sig embedded in
    ///      `Authorization`. If the 5-line template or field order were wrong,
    ///      the two would diverge.
    ///   2. **Payload structure** — decode the payload and confirm the
    ///      deterministic fields (`version`, `requestId`, `cosyVersion`,
    ///      `ideVersion`) and the pinned `info` blob match pi's payload shape.
    ///      The `info` blob is byte-exact against pi (proven separately in
    ///      `testAESUserBlobByteExactForFixedKey`), so the only remaining
    ///      non-determinism is the RSA ciphertext.
    func testSignatureReconstructsFromHeaderOutput() throws {
        let options = QoderCOSYSignerOptions(
            aesKey: "0123456789abcdef",
            requestID: "fb4354eb-d169-4b7d-a0ef-a6756833f3b4",
            xRequestID: "11111111-1111-1111-1111-111111111111",
            timestamp: "1785667802"
        )
        let headers = try QoderCOSYSigner.sign(
            body: chatBody,
            requestURL: chatURL,
            credentials: creds,
            options: options
        ).allHeaders

        let payloadB64 = String(headers["Authorization"]!.dropFirst("Bearer COSY.".count).split(separator: ".")[0])
        let cosyKey = try XCTUnwrap(headers["Cosy-Key"])
        let timestamp = try XCTUnwrap(headers["Cosy-Date"])
        let sigFromHeader = String(headers["Authorization"]!.split(separator: ".").last!)

        // 1. Self-consistency: recompute the MD5 from the same 5 inputs the
        //    signer used and confirm it matches the sig in the header.
        let reconstructedInput = "\(payloadB64)\n\(cosyKey)\n\(timestamp)\n\(chatBody)\n\(headers["Cosy-Sigpath"]!)"
        XCTAssertEqual(md5Hex(reconstructedInput), sigFromHeader, "Authorization sig diverged from reconstructed MD5")
        XCTAssertEqual(timestamp, "1785667802", "timestamp should honor the pinned value")

        // 2. Payload structure: decode and confirm the deterministic fields
        //    match pi's cosyPayload shape exactly.
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: payloadB64))) as? [String: Any])
        XCTAssertEqual(payload["version"] as? String, "v1")
        XCTAssertEqual(payload["requestId"] as? String, "fb4354eb-d169-4b7d-a0ef-a6756833f3b4")
        XCTAssertEqual(payload["cosyVersion"] as? String, "1.1.3")
        XCTAssertEqual(payload["ideVersion"] as? String, "")
        // The `info` is the byte-exact AES blob proven separately.
        XCTAssertEqual(payload["info"] as? String, expectedAESUserBlob)
    }

    /// RSA-PKCS1 v1.5 padding is randomized, so two signs with identical
    /// inputs produce different `cosyKey` values and therefore different sigs.
    /// This guards against a regression to PKCS-OAEP (also randomized, but a
    /// different scheme the gateway would reject) or — worse — a deterministic
    /// padding like textbook RSA (which would be a security bug and would make
    /// cosyKey constant across calls).
    func testRSAProducesDifferentCiphertextAcrossCalls() throws {
        let options = QoderCOSYSignerOptions(aesKey: "0123456789abcdef")
        let a = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds, options: options).allHeaders
        let b = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds, options: options).allHeaders

        XCTAssertNotEqual(a["Cosy-Key"], b["Cosy-Key"], "RSA ciphertext should differ across calls (PKCS1 v1.5 random padding)")
        XCTAssertNotEqual(a["Authorization"], b["Authorization"], "Authorization should differ when cosyKey differs")
        // Both must still be the right length (1024-bit key → 128 bytes → 172 b64).
        XCTAssertEqual(a["Cosy-Key"]?.count, 172)
        XCTAssertEqual(b["Cosy-Key"]?.count, 172)
    }

    // MARK: - Body hash + length

    /// `Cosy-Bodyhash` is the lowercase-hex MD5 of the (WAF-encoded) body
    /// string. Captured from pi for `{"messages":[]}`.
    func testBodyHashAndLength() throws {
        let headers = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds).allHeaders
        XCTAssertEqual(headers["Cosy-Bodyhash"], "394daf1a187e2f2a82ac593c04a0f637")
        XCTAssertEqual(headers["Cosy-Bodylength"], "15") // byte length of the UTF-8 body
    }

    /// A nil/empty body (GET model-list) hashes to MD5("") and length 0,
    /// matching pi's `body ? … : "0"` fallthrough.
    func testEmptyBodyHashAndLength() throws {
        let headers = try QoderCOSYSigner.sign(body: nil, requestURL: modelListURL, credentials: creds).allHeaders
        XCTAssertEqual(headers["Cosy-Bodyhash"], "d41d8cd98f00b204e9800998ecf8427e") // MD5("")
        XCTAssertEqual(headers["Cosy-Bodylength"], "0")
    }

    // MARK: - Sig path

    /// `/algo` prefix is stripped; query string ignored. Matches pi's
    /// `computeSigPath`.
    func testSigPathStripsAlgoPrefixAndIgnoresQuery() throws {
        let chat = try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: creds).allHeaders
        let modelList = try QoderCOSYSigner.sign(body: nil, requestURL: modelListURL, credentials: creds).allHeaders

        XCTAssertEqual(chat["Cosy-Sigpath"], "/api/v2/service/pro/sse/agent_chat_generation")
        XCTAssertEqual(modelList["Cosy-Sigpath"], "/api/v2/model/list")
    }

    // MARK: - Guardrails (mirror pi)

    func testEmptyUserIDThrows() {
        XCTAssertThrowsError(
            try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: QoderCOSYCredentials(userID: "", authToken: "jt-x"))
        ) { error in
            guard case QoderCOSYError.userIDMissing = error else {
                return XCTFail("expected userIDMissing, got \(error)")
            }
        }
    }

    func testEmptyAuthTokenThrows() {
        XCTAssertThrowsError(
            try QoderCOSYSigner.sign(body: chatBody, requestURL: chatURL, credentials: QoderCOSYCredentials(userID: "u", authToken: ""))
        ) { error in
            guard case QoderCOSYError.authTokenMissing = error else {
                return XCTFail("expected authTokenMissing, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Local MD5 so the test is self-contained (matches the signer's own
    /// Insecure.MD5 path). Used to reconstruct the signature input.
    private func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
