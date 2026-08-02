//
//  QoderCOSYSigner.swift
//  Quotio
//
//  Phase 2a foundation (ADR 0001): produces the COSY signature envelope and
//  `Cosy-*` client headers for Qoder's chat/models gateway
//  (`api3.qoder.sh/algo/...`). Required for all `algo/...` calls; not required
//  for `openapi.qoder.sh/api/...` (PAT exchange, userinfo, quota — those use a
//  plain Bearer job token, handled by QoderPATService / QoderQuotaFetcher).
//
//  Pure value type: no I/O, no actor state, no clocks, no randomness source
//  other than an injectable `Options` bag. Isolated here so ticket #5 can unit-
//  test the riskiest porting surface (RSA + AES-CBC + MD5 wiring, ~15 headers)
//  against the TypeScript fixtures before ProxyBridge wires it in (06-07).
//
//  Reference: pi-provider-qoder/src/cosy.ts (`buildAuthHeaders`), ported
//  verbatim in every constant and every step that affects the bytes the
//  gateway validates. The body passed in is the *already-WAF-encoded* body
//  string (pi: `buildAuthHeaders(encodedBytes, chatURL, …)`), so the signature
//  and body hash cover exactly what goes on the wire.
//

import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Credentials fed into the COSY signer. Maps 1:1 to pi's `CosyCredentials` and
/// to the `MonitorOAuthCredential` shape per ADR 0002 / ADR 0006 §1:
/// - `userID`        ← credential.accountID (resolved from `/userinfo` at
///   PAT-exchange time; load-bearing — empty is a hard error, matching pi).
/// - `authToken`     ← credential.accessToken (the job token `jt-...`).
/// - `name`, `email` ← resolved identity (best-effort, may be empty).
/// - `machineID`     ← credential.extra["machineID"] (per-account, ADR 0006 §1).
nonisolated struct QoderCOSYCredentials: Sendable, Equatable {
    let userID: String
    let authToken: String
    let name: String
    let email: String
    let machineID: String

    init(userID: String, authToken: String, name: String = "", email: String = "", machineID: String = "") {
        self.userID = userID
        self.authToken = authToken
        self.name = name
        self.email = email
        self.machineID = machineID
    }
}

/// Injectable non-deterministic inputs. In production every field is nil and
/// the signer generates fresh randoms + the current time per call (matching
/// pi). In tests, pin every field to assert byte-exact output against a
/// fixture captured from pi with the same values.
nonisolated struct QoderCOSYSignerOptions: Sendable {
    /// 16-char AES key. Production passes nil → a fresh UUID-derived 16-char
    /// key (pi: `randomUUID().replace(/-/g, "").slice(0, 16)`).
    var aesKey: String?
    /// Cosy-payload `requestId` (UUID). Production passes nil → fresh UUID.
    var requestID: String?
    /// `X-Request-Id` header (UUID). Independent of `requestId` in pi; we keep
    /// them independent here too. Production passes nil → fresh UUID.
    var xRequestID: String?
    /// Unix seconds, as pi would format via `Math.floor(Date.now()/1000)`.
    /// Production passes nil → now.
    var timestamp: String?

    /// All-random, all-now — the production configuration.
    static let deferringToRandom = QoderCOSYSignerOptions()
}

/// The COSY signature envelope. A `[String: String]` so ticket 06 can stamp
/// each entry straight onto a `URLRequest`; insertion order is irrelevant to
/// HTTP (headers are unordered). The `Authorization` line carries the
/// `Bearer COSY.<payloadB64>.<sig>` token the gateway validates.
nonisolated struct QoderCOSYHeaders: Sendable, Equatable {
    let authorization: String
    let values: [String: String]

    /// Flatten into one dictionary, `Authorization` included. Mirrors the shape
    /// pi returns from `buildAuthHeaders`.
    var allHeaders: [String: String] {
        var combined = values
        combined["Authorization"] = authorization
        return combined
    }
}

/// Errors thrown when the inputs are unusable or the crypto primitives refuse
/// to play. The crypto-error branches are unreachable in practice (the key is
/// a constant 1024-bit RSA public key and AES-128-CBC never fails on a valid
/// 16-byte key) but Swift needs them and surfacing them beats trapping.
nonisolated enum QoderCOSYError: Error, LocalizedError {
    case userIDMissing
    case authTokenMissing
    case rsaKeyLoadFailed
    case rsaEncryptionFailed
    case aesKeyWrongLength(count: Int)
    case aesEncryptionFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .userIDMissing: return "Qoder COSY: user id is empty"
        case .authTokenMissing: return "Qoder COSY: auth token is empty"
        case .rsaKeyLoadFailed: return "Qoder COSY: embedded RSA public key could not be loaded"
        case .rsaEncryptionFailed: return "Qoder COSY: RSA encryption failed"
        case .aesKeyWrongLength(let count): return "Qoder COSY: AES key must be 16 bytes (got \(count))"
        case .aesEncryptionFailed(let status): return "Qoder COSY: AES encryption failed (status \(status))"
        }
    }
}

/// Qoder's request-signing scheme for the chat/models gateway. One method,
/// `sign(body:url:credentials:options:)`, produces the full header set.
///
/// `nonisolated enum` → all members inherit nonisolated, callable from any
/// isolation domain (ProxyBridge is an `actor`; the signer is borrowed across
/// with no synchronization needs). The project's default isolation is
/// MainActor; pure value types opt out explicitly, like `ProxyURLValidator`.
nonisolated enum QoderCOSYSigner {
    // MARK: - Constants (mirror pi verbatim; gateway validates against these)

    /// The IDE client version advertised via `Cosy-Version` and the cosy-payload
    /// `cosyVersion`. Older values cause the model endpoint to return a
    /// reduced catalog, so this stays in lockstep with the current Qoder CLI.
    static let ideVersion = "1.1.3"

    /// `Cosy-Clienttype` — Qoder's numeric client-type code for an IDE.
    static let clientType = "5"

    /// `Cosy-Data-Policy` — disagreement with Qoder's data-training prompt.
    /// Pi ships `"disagree"`; we match.
    static let dataPolicy = "disagree"

    /// `Login-Version` — Qoder login protocol version.
    static let loginVersion = "v2"

    /// `Cosy-Machinetype` — a magic constant pi sends verbatim, not a real OS
    /// identifier.
    static let machineTypeMagic = "5"

    /// `Cosy-Machineos`. Pi derives this from `process.platform`/`process.arch`
    /// and only ever emits a `*_linux`/`*_windows` variant because the CLI
    /// presents as a Linux client to the gateway. Quotio runs on macOS, but the
    /// gateway keys this off the value, not the actual OS — so we send the
    /// `aarch64_linux`/`x86_64_linux` string pi would send for the same arch to
    /// keep Quotio's COSY envelope byte-identical to pi's. Confirm with a
    /// live capture during Phase 2b integration; revisit if the gateway ever
    /// gates on real OS detection.
    static let machineOS = Self.detectMachineOS()

    /// `Cosy-Clientip` — a static loopback literal, never the real client IP.
    static let clientIP = "127.0.0.1"

    /// Qoder's 1024-bit RSA public key (SubjectPublicKeyInfo, X.509) as a PEM
    /// body. Used to RSA-PKCS1-encrypt the per-request AES key. Hardcoded — the
    /// gateway is the only consumer of the matching private key and the public
    /// half is shipped in every Qoder client.
    static let rsaPublicKeyPEMBody = """
    MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDA8iMH5c02LilrsERw9t6Pv5Nc\
    4k6Pz1EaDicBMpdpxKduSZu5OANqUq8er4GM95omAGIOPOh+Nx0spthYA2BqGz+l\
    6HRkPJ7S236FZz73In/KVuLnwI8JJ2CbuJap8kvheCCZpmAWpb/cPx/3Vr/J6I17\
    XcW+ML9FoCI6AOvOzwIDAQAB
    """

    // MARK: - Public entry point

    /// Build the COSY header envelope for one request.
    ///
    /// - Parameters:
    ///   - body: the **WAF-encoded** request body string (pi:
    ///     `buildAuthHeaders(encodedBytes, …)`). Pass `nil`/empty for GET-style
    ///     calls such as model-list — pi uses `""` there and the body hash is
    ///     the MD5 of empty.
    ///   - requestURL: the full gateway URL, e.g.
    ///     `https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?Encode=1`.
    ///     Only the pathname (with any `/algo` prefix stripped) feeds the
    ///     signature; the query string does not.
    ///   - credentials: the per-account identity + job token.
    ///   - options: non-deterministic inputs; pass `.deferringToRandom` in
    ///     production and pinned values in tests.
    /// - Returns: the `Authorization` line plus every `Cosy-*` / `Login-*` /
    ///   `X-Request-Id` header the gateway expects.
    static func sign(
        body: String?,
        requestURL: String,
        credentials: QoderCOSYCredentials,
        options: QoderCOSYSignerOptions = .deferringToRandom
    ) throws -> QoderCOSYHeaders {
        // pi throws up front on empty userID/authToken — the signature would
        // otherwise be valid-looking but rejected by the gateway, which is a
        // worse failure mode than a clear local error.
        guard !credentials.userID.isEmpty else { throw QoderCOSYError.userIDMissing }
        guard !credentials.authToken.isEmpty else { throw QoderCOSYError.authTokenMissing }

        // 1. Per-request AES key (random in production, pinned in tests).
        let aesKey = options.aesKey ?? Self.randomAESKey()

        // 2. AES-128-CBC the user-info blob (key reused as IV, PKCS#7 padding —
        //    Node's createCipheriv default). `aid` is always empty in pi.
        let userInfoJSON = Self.userInfoJSON(credentials)
        let infoB64 = try Self.aesEncryptCBCBase64(plaintext: userInfoJSON, key: aesKey)

        // 3. RSA-PKCS1 encrypt the AES key with Qoder's public key.
        let cosyKey = try Self.rsaEncryptBase64(aesKey)

        // 4. Timestamp + IDs (random/now in production, pinned in tests).
        let timestamp = options.timestamp ?? Self.currentUnixSeconds()
        let requestID = options.requestID ?? UUID().uuidString.lowercased()
        let xRequestID = options.xRequestID ?? UUID().uuidString.lowercased()

        // 5. Cosy payload → base64. JSON key order matches pi's insertion order
        //    so the payloadB64 is byte-identical to pi's for the same inputs
        //    (lets tests assert exact equality against a fixture). The gateway
        //    does not re-stringify, so order is not load-bearing upstream.
        let payloadJSON = Self.cosyPayloadJSON(
            requestID: requestID,
            info: infoB64
        )
        let payloadB64 = Data(payloadJSON.utf8).base64EncodedString()

        // 6. Sig path = URL pathname with any `/algo` prefix stripped. Query
        //    string is not part of the signature.
        let sigPath = Self.computeSigPath(requestURL)

        // 7. MD5 over `payloadB64 \n key \n timestamp \n body \n sigPath`.
        //    Body is the WAF-encoded string; nil → "" (pi: `body ? … : ""`).
        let bodyStr = body ?? ""
        let sig = Self.md5Hex([
            payloadB64,
            cosyKey,
            timestamp,
            bodyStr,
            sigPath,
        ].joined(separator: "\n"))

        // 8. Separate body hash + length headers. Note pi uses the *unencoded*
        //    body conceptually but in practice the caller always passes the
        //    encoded body here (see stream.ts:232), so the hash/length cover
        //    the same bytes the wire carries.
        let bodyHash = Self.md5Hex(bodyStr)
        let bodyLength = bodyStr.utf8.count

        // machineID is per-account (ADR 0006 §1); empty falls back to a random
        // UUID in pi, but Quotio always stores one per credential, so empty
        // here would be a Vault bug. We still tolerate it (matching pi) rather
        // than fail the whole request over a client-identification header.
        // Lowercase to match pi's `crypto.randomUUID()` shape (Node emits
        // lowercase; `UUID().uuidString` is uppercase). The other UUID-derived
        // fields (`requestID`, `xRequestID`) lowercased above for the same
        // reason.
        let machineID = credentials.machineID.isEmpty
            ? UUID().uuidString.lowercased()
            : credentials.machineID

        let values: [String: String] = [
            "Cosy-Key": cosyKey,
            "Cosy-User": credentials.userID,
            "Cosy-Date": timestamp,
            "Cosy-Version": ideVersion,
            "Cosy-Machineid": machineID,
            "Cosy-Machinetoken": machineID,
            "Cosy-Machinetype": machineTypeMagic,
            "Cosy-Machineos": machineOS,
            "Cosy-Clienttype": clientType,
            "Cosy-Clientip": clientIP,
            "Cosy-Bodyhash": bodyHash,
            "Cosy-Bodylength": String(bodyLength),
            "Cosy-Sigpath": sigPath,
            "Cosy-Data-Policy": dataPolicy,
            // Organization headers are empty in pi for individual accounts;
            // Qoder may populate them for org plans later. Keep the keys so the
            // header set matches pi's footprint exactly.
            "Cosy-Organization-Id": "",
            "Cosy-Organization-Tags": "",
            "Login-Version": loginVersion,
            "X-Request-Id": xRequestID,
        ]

        let authorization = "Bearer COSY.\(payloadB64).\(sig)"
        return QoderCOSYHeaders(authorization: authorization, values: values)
    }

    // MARK: - JSON builders

    /// Build the AES-encrypted user-info blob's plaintext. Byte-identical to
    /// pi's `JSON.stringify({uid, security_oauth_token, name, aid, email})` —
    /// same key order, same escaping — so the encrypted output matches a
    /// fixture captured with the same AES key.
    ///
    /// `aid` is always `""` in pi (never populated by the caller), hardcoded
    /// here to make that invariant explicit.
    private static func userInfoJSON(_ c: QoderCOSYCredentials) -> String {
        // Order matters: uid, security_oauth_token, name, aid, email.
        return "{"
            + "\"uid\":\(jsonString(c.userID)),"
            + "\"security_oauth_token\":\(jsonString(c.authToken)),"
            + "\"name\":\(jsonString(c.name)),"
            + "\"aid\":\"\","
            + "\"email\":\(jsonString(c.email))"
            + "}"
    }

    /// Build the cosy-payload JSON plaintext. Byte-identical to pi's
    /// `JSON.stringify({version, requestId, info, cosyVersion, ideVersion})` —
    /// `version` is always `"v1"`, `ideVersion` always `""`.
    private static func cosyPayloadJSON(requestID: String, info: String) -> String {
        // Order matters: version, requestId, info, cosyVersion, ideVersion.
        return "{"
            + "\"version\":\"v1\","
            + "\"requestId\":\(jsonString(requestID)),"
            + "\"info\":\(jsonString(info)),"
            + "\"cosyVersion\":\"\(ideVersion)\","
            + "\"ideVersion\":\"\""
            + "}"
    }

    /// Quote + escape a JSON string value. Matches V8's `JSON.stringify`
    /// escaping: `"`, `\`, and control chars (< 0x20) are escaped; `\b\f\n\r\t`
    /// get their short forms, everything else below 0x20 becomes `\u00XX`.
    /// UTF-8 multi-byte scalars pass through unchanged (V8 emits them as-is
    /// unless they're surrogates/control). Used for the manual JSON builders
    /// above so the output is byte-identical to pi rather than subject to
    /// Foundation's arbitrary key ordering.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    // Control char with no short form → \u00XX.
                    out.append(String(format: "\\u%04x", scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }

    // MARK: - Crypto

    /// RSA-PKCS1 encrypt `plaintext` with the embedded Qoder public key,
    /// return base64. Mirrors pi's `rsaEncryptBase64`.
    ///
    /// Uses `Security` framework (CryptoKit has no RSA). The public key is a
    /// 1024-bit SubjectPublicKeyInfo, so the ciphertext is always 128 bytes →
    /// 172 base64 chars. The signer does not depend on the length, but the
    /// gateway does.
    private static func rsaEncryptBase64(_ plaintext: String) throws -> String {
        let key = try Self.loadRSAPublicKey()
        var error: Unmanaged<CFError>?
        // `.pkcs1` maps to RSA_PKCS1_PADDING (PKCS#1 v1.5), matching
        // crypto.constants.RSA_PKCS1_PADDING in pi. RSA-OAEP would not decrypt
        // server-side.
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionPKCS1,
            Data(plaintext.utf8) as CFData,
            &error
        ) as Data? else {
            throw QoderCOSYError.rsaEncryptionFailed
        }
        return encrypted.base64EncodedString()
    }

    /// Parse the embedded public key into a `SecKey` each call. Not cached:
    /// `SecKeyCreateWithData` on a 1024-bit key is microseconds, the gateway
    /// call that follows is hundreds of milliseconds, and a cached `SecKey` in
    /// static state would make the signer non-pure (and trip Swift 6's
    /// global-mutable-state check). The signer stays a stateless value type.
    private static func loadRSAPublicKey() throws -> SecKey {
        // Re-wrap the PEM body with header/footer and strip to DER. PEM is just
        // base64 of the DER; we store the body only to keep the source tidy.
        let pem = "-----BEGIN PUBLIC KEY-----\n"
            + rsaPublicKeyPEMBody
            + "\n-----END PUBLIC KEY-----"
        let stripped = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let derData = Data(base64Encoded: stripped) else {
            throw QoderCOSYError.rsaKeyLoadFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(derData as CFData, attributes as CFDictionary, &error) else {
            throw QoderCOSYError.rsaKeyLoadFailed
        }
        return key
    }

    /// AES-128-CBC encrypt `plaintext` to base64, key reused as IV, with PKCS#7
    /// padding (Node's `createCipheriv` default). Mirrors pi's
    /// `aesEncryptCBCBase64`. CommonCrypto is the same primitive Node uses
    /// under the hood, so the output matches byte-for-byte for a given key.
    private static func aesEncryptCBCBase64(plaintext: String, key: String) throws -> String {
        // AES-128 needs a 16-byte key. Pi derives 16 hex chars from a UUID;
        // we accept any 16-byte string. A short/long key would not match pi.
        // Throwing (rather than trapping) matches every other failure path
        // here and in QoderPATService, and matters because `aesKey` is
        // injectable via Options — a bad caller value should error, not crash.
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == 16 else {
            throw QoderCOSYError.aesKeyWrongLength(count: keyBytes.count)
        }

        let ivBytes = keyBytes // pi: key reused as IV.
        let plaintextBytes = Array(plaintext.utf8)
        let bufferSize = plaintextBytes.count + kCCBlockSizeAES128 // one block of padding worst case
        var buffer = Data(count: bufferSize)
        var moved = 0

        let status = buffer.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            plaintextBytes.withUnsafeBufferPointer { inBytes in
                keyBytes.withUnsafeBufferPointer { keyPtr in
                    ivBytes.withUnsafeBufferPointer { ivPtr in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyBytes.count,
                            ivPtr.baseAddress,
                            inBytes.baseAddress, plaintextBytes.count,
                            outBytes.baseAddress, bufferSize,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw QoderCOSYError.aesEncryptionFailed(status: status)
        }
        buffer.count = moved
        return buffer.base64EncodedString()
    }

    /// Lowercase hex MD5 of `s`. Insecure for crypto, fine for the COSY
    /// signature — the gateway MD5s the same input list and string-compares.
    private static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    /// Pi's `aesKey = randomUUID().replace(/-/g, "").slice(0, 16)`: a UUID
    /// without dashes, truncated to 16 hex chars. We produce the same shape.
    private static func randomAESKey() -> String {
        String(UUID().uuidString.filter { $0 != "-" }.prefix(16))
    }

    /// Unix seconds as a decimal string, matching pi's
    /// `Math.floor(Date.now() / 1000).toString()`.
    private static func currentUnixSeconds() -> String {
        String(Int(Date().timeIntervalSince1970.rounded(.down)))
    }

    /// Strip the `/algo` prefix from the URL pathname, matching pi's
    /// `computeSigPath`. Anything before the first `?` is the pathname; the
    /// query string is never part of the signature.
    ///
    /// `URL(string:)` would parse this for us but it lowercases hosts and
    /// normalizes away trailing quirks the gateway may rely on; pi uses `new
    /// URL(...)` and reads `.pathname`, so we mirror that with `URLComponents`
    /// (which gives the raw pathname without host-side normalization).
    private static func computeSigPath(_ urlStr: String) -> String {
        guard let comps = URLComponents(string: urlStr) else { return "" }
        var path = comps.path
        if path.hasPrefix("/algo") {
            path.removeFirst("/algo".count)
        }
        return path
    }

    /// Detect the `Cosy-Machineos` value. Pi only ever emits `*_linux`/
    /// `*_windows` variants because it presents as a non-Mac client; we match
    /// that even on macOS (see the `machineOS` doc comment above).
    private static func detectMachineOS() -> String {
        #if arch(arm64)
        return "aarch64_linux"
        #elseif arch(x86_64)
        return "x86_64_linux"
        #else
        return "aarch64_linux"
        #endif
    }
}
