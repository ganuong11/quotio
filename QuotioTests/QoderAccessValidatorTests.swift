//
//  QoderAccessValidatorTests.swift
//  QuotioTests
//
//  Issue #21 / ADR 0008: validate that `QoderAccessValidator` mirrors CPA's
//  `config_access` provider exactly. The acceptance matrix below covers the
//  five candidate sources, the presence-based missing-vs-invalid distinction,
//  the primed-state fail-closed gate, the primed-empty-set pass-through,
//  header case-insensitivity, duplicate-header first-wins, query precedence /
//  Go `net/url` parity (`+` → space, percent-decoded names and values,
//  malformed-escape pair drop), key normalization, and constant-time compare
//  edge cases (including the XOR-cancellation regression). Actor methods are
//  async — every call is `await`ed.
//

import Foundation
import XCTest
@testable import Quotio

// MARK: - Helper

/// Convenience to assert a Decision equals `.allowed(principal:)`. XCTAssertEqual
/// on the enum works directly because `Decision` is `Equatable`.
private func assertAllowed(
    _ decision: QoderAccessValidator.Decision,
    _ principal: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(decision, .allowed(principal: principal), file: file, line: line)
}

final class QoderAccessValidatorTests: XCTestCase {

    // MARK: - Primed state (fail closed before first reload)

    /// A fresh validator has no snapshot yet → `.notPrimed` regardless of
    /// input. The key set is UNKNOWN, not known-empty, so this must not
    /// degrade to `.notConfigured` (open access) — closes the fail-open
    /// window between proxy start and the first successful fetchAPIKeys.
    func testUnprimedValidatorFailsClosed() async {
        let v = QoderAccessValidator()
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        XCTAssertEqual(decision, .notPrimed)
    }

    /// `.notPrimed` holds even for a request with no credentials at all
    /// (which would be `.missing` once primed).
    func testUnprimedValidatorFailsClosedWithNoHeaders() async {
        let v = QoderAccessValidator()
        let decision = await v.authenticate(path: "/v1/chat/completions", headers: [])
        XCTAssertEqual(decision, .notPrimed)
    }

    /// The first reload primes the validator even for an EMPTY key list —
    /// an empty list is still a positive statement from CPA ("there are no
    /// api-keys"), so the decision becomes `.notConfigured`, not `.notPrimed`.
    func testReloadWithEmptyListPrimesToNotConfigured() async {
        let v = QoderAccessValidator()
        await v.reload(keys: [])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        XCTAssertEqual(decision, .notConfigured)
    }

    // MARK: - Primed-empty key set → notConfigured (CPA legacy behaviour)

    /// ADR 0008 point 6: a primed-but-empty configured-key set means the
    /// provider is unregistered → all requests pass. This must hold for ANY
    /// input, including inputs that would otherwise be `.missing` or
    /// `.invalid`.
    func testEmptySnapshotReturnsNotConfiguredForNoHeaders() async {
        let v = QoderAccessValidator()
        await v.reload(keys: [])
        let decision = await v.authenticate(path: "/v1/chat/completions", headers: [])
        XCTAssertEqual(decision, .notConfigured)
    }

    func testEmptySnapshotReturnsNotConfiguredEvenWithCandidatePresent() async {
        let v = QoderAccessValidator()
        await v.reload(keys: [])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        // A present-but-unmatchable candidate must STILL be `.notConfigured`
        // (not `.invalid`), because an empty snapshot means "auth disabled",
        // not "no keys match".
        XCTAssertEqual(decision, .notConfigured)
    }

    // MARK: - Missing vs invalid (presence distinction)

    /// No headers, no query → all five sources empty → `.missing` (401
    /// "Missing API key" in CPA).
    func testMissingWhenNoSourcesPresent() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(path: "/v1/chat/completions", headers: [])
        XCTAssertEqual(decision, .missing)
    }

    /// ADR 0008 point 3 subtlety: `Authorization: Bearer ` (empty suffix) makes
    /// the raw header non-empty → NOT missing. The extracted candidate is "",
    /// which is skipped; with no other source, the decision is `.invalid`
    /// (candidate present, none matched).
    func testBearerEmptySuffixIsInvalidNotMissing() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer ")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    /// A spaces-only Authorization header (`"   "`) has no scheme delimiter
    /// space split → extractBearerToken returns the whole header as the
    /// candidate (`"   "`), which is non-empty → present but unmatchable →
    /// `.invalid`. (Pins T3 extraction edge.)
    func testSpacesOnlyAuthorizationIsInvalidNotMissing() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "   ")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    /// A tab is NOT the scheme delimiter (CPA splits on `" "` only — Go's
    /// `strings.SplitN(h, " ", 2)`), so `"Bearer\tsecret"` is a whole-header
    /// candidate and does not match key "secret" → `.invalid`.
    func testTabIsNotSchemeDelimiter() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer\tsecret")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    // MARK: - Authorization source

    func testAuthorizationBearerMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        assertAllowed(decision, "secret")
    }

    /// Bare token in Authorization (no scheme) → extractBearerToken returns the
    /// whole header as the candidate.
    func testAuthorizationBareTokenMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "secret")]
        )
        assertAllowed(decision, "secret")
    }

    /// Bearer scheme is case-insensitive.
    func testAuthorizationLowercaseBearerMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "bearer secret")]
        )
        assertAllowed(decision, "secret")
    }

    func testAuthorizationUppercaseBearerMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "BEARER secret")]
        )
        assertAllowed(decision, "secret")
    }

    /// Non-bearer scheme → the WHOLE header becomes the candidate. Against a
    /// key "secret", "Basic secret" does not match → `.invalid`.
    func testAuthorizationBasicSchemeDoesNotMatchKeySecret() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Basic secret")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    /// But if the user literally configured `"Basic secret"` as a key, the
    /// whole-header candidate DOES match. This pins the "scheme-not-bearer →
    /// whole header" extraction rule.
    func testAuthorizationBasicSchemeMatchesWhenConfiguredAsKey() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["Basic secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Basic secret")]
        )
        assertAllowed(decision, "Basic secret")
    }

    // MARK: - X-Api-Key / X-Goog-Api-Key sources

    func testXApiKeyMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("X-Api-Key", "secret")]
        )
        assertAllowed(decision, "secret")
    }

    func testXGoogApiKeyMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("X-Goog-Api-Key", "secret")]
        )
        assertAllowed(decision, "secret")
    }

    // MARK: - Query sources (?key=, ?auth_token=)

    func testQueryKeyMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=secret",
            headers: []
        )
        assertAllowed(decision, "secret")
    }

    func testQueryAuthTokenMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?auth_token=secret",
            headers: []
        )
        assertAllowed(decision, "secret")
    }

    /// Percent-encoded value `sec%72et` → decodes to "secret".
    func testQueryKeyPercentDecodedMatches() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=sec%72et",
            headers: []
        )
        assertAllowed(decision, "secret")
    }

    /// Go `net/url` parity: `+` in a query VALUE decodes to space
    /// (`QueryUnescape`). A configured key containing a space, sent via query
    /// with `+` encoding, must match.
    func testQueryKeyPlusDecodesToSpace() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["a b"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=a+b",
            headers: []
        )
        assertAllowed(decision, "a b")
    }

    /// Go `net/url` parity: parameter NAMES are percent-decoded too —
    /// `%6bey` unescapes to `key` and matches (`ParseQuery("%6bey=x")` →
    /// `.Get("key") == "x"`).
    func testQueryParamNamePercentDecoded() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?%6bey=secret",
            headers: []
        )
        assertAllowed(decision, "secret")
    }

    // MARK: - Wrong key / shadowing

    func testWrongBearerIsInvalid() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer wrong")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    /// ADR 0008 point 1: a WRONG earlier candidate must NOT shadow a later VALID
    /// one. Authorization: Bearer wrong (source 1) → X-Api-Key: secret (source
    /// 3) → `.allowed` with principal "secret".
    func testWrongEarlierCandidateDoesNotShadowLaterValidOne() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [
                ("Authorization", "Bearer wrong"),
                ("X-Api-Key", "secret")
            ]
        )
        assertAllowed(decision, "secret")
    }

    /// Precedence pin: when both Authorization AND X-Api-Key carry a valid key,
    /// Authorization wins (it is earlier in the candidate list). Principal must
    /// be the Authorization key, not the X-Api-Key.
    func testAuthorizationWinsOverXApiKeyWhenBothValid() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["authz-secret", "apikey-secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [
                ("Authorization", "Bearer authz-secret"),
                ("X-Api-Key", "apikey-secret")
            ]
        )
        assertAllowed(decision, "authz-secret")
    }

    // MARK: - Header-name case-insensitivity / duplicate first-wins

    /// Header names are case-insensitive — a lowercase `x-api-key` must match.
    func testHeaderNameCaseInsensitive() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("x-api-key", "secret")]
        )
        assertAllowed(decision, "secret")
    }

    /// First occurrence of a duplicated header name wins (mirrors Go's
    /// `http.Header.Get`). The second (wrong) value must not shadow the first.
    func testDuplicateHeaderFirstOccurrenceWins() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [
                ("X-Api-Key", "secret"),
                ("X-Api-Key", "wrong")
            ]
        )
        assertAllowed(decision, "secret")
    }

    /// And reversed order: first is wrong → no match → `.invalid` (second never
    /// gets a chance).
    func testDuplicateHeaderFirstOccurrenceWinsReversed() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [
                ("X-Api-Key", "wrong"),
                ("X-Api-Key", "secret")
            ]
        )
        XCTAssertEqual(decision, .invalid)
    }

    // MARK: - Query precedence / malformed percent (Go parity)

    /// First occurrence of a repeated query parameter wins.
    func testDuplicateQueryKeyFirstWins() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=secret&key=wrong",
            headers: []
        )
        assertAllowed(decision, "secret")
    }

    /// First occurrence wins, reversed.
    func testDuplicateQueryKeyFirstWinsReversed() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=wrong&key=secret",
            headers: []
        )
        XCTAssertEqual(decision, .invalid)
    }

    /// Go parity: a malformed percent-escape DROPS the pair (Go's `parseQuery`
    /// skips it; `Query().Get` returns ""). `?key=sec%ZZet` as the only source
    /// → no `key` source present → `.missing` — exactly CPA's outcome.
    func testMalformedPercentEscapeDropsPairAsMissing() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=sec%ZZet",
            headers: []
        )
        XCTAssertEqual(decision, .missing)
    }

    /// A malformed `?key=` pair next to a VALID other source still authenticates
    /// via the other source — the dropped pair neither matches nor blocks.
    func testMalformedPercentPairDoesNotBlockOtherSources() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions?key=sec%ZZet",
            headers: [("X-Api-Key", "secret")]
        )
        assertAllowed(decision, "secret")
    }

    // MARK: - normalizeKeys

    /// Reload trims whitespace, drops empties, and de-duplicates. Pinning the
    /// exact set after normalization.
    func testNormalizeKeysTrimsDropsEmptiesAndDeduplicates() {
        let normalized = QoderAccessValidator.normalizeKeys(
            ["  secret  ", "", "secret", "other"]
        )
        XCTAssertEqual(normalized, Set(["secret", "other"]))
    }

    /// All-empty input → empty set (which then means `.notConfigured`).
    func testNormalizeKeysAllEmpty() {
        let normalized = QoderAccessValidator.normalizeKeys(["", "   ", ""])
        XCTAssertTrue(normalized.isEmpty)
    }

    /// Whitespace-only entries are dropped (trim → empty). Uses
    /// `.whitespacesAndNewlines` for parity with Go's `strings.TrimSpace`.
    func testNormalizeKeysWhitespaceOnlyDropped() {
        let normalized = QoderAccessValidator.normalizeKeys(["\t", "  ", "\n "])
        XCTAssertTrue(normalized.isEmpty)
    }

    /// Reload is idempotent — the actor's snapshot equals the normalized set
    /// and a second reload with the same input produces the same decisions.
    func testReloadIsIdempotent() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret", "secret", "  secret  "])
        let d1 = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        await v.reload(keys: ["secret"])
        let d2 = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        XCTAssertEqual(d1, .allowed(principal: "secret"))
        XCTAssertEqual(d2, .allowed(principal: "secret"))
    }

    // MARK: - extractBearerToken edge cases

    func testExtractBearerTokenEmpty() {
        XCTAssertEqual(QoderAccessValidator.extractBearerToken(""), "")
    }

    func testExtractBearerTokenNoSpace() {
        XCTAssertEqual(QoderAccessValidator.extractBearerToken("secret"), "secret")
    }

    func testExtractBearerTokenBearerScheme() {
        XCTAssertEqual(QoderAccessValidator.extractBearerToken("Bearer secret"), "secret")
    }

    func testExtractBearerTokenBearerSchemeExtraSpaces() {
        XCTAssertEqual(QoderAccessValidator.extractBearerToken("Bearer   secret"), "secret")
    }

    func testExtractBearerTokenBearerSchemeEmptySuffix() {
        XCTAssertEqual(QoderAccessValidator.extractBearerToken("Bearer "), "")
    }

    func testExtractBearerTokenNonBearerSchemeReturnsWholeHeader() {
        XCTAssertEqual(
            QoderAccessValidator.extractBearerToken("Basic abc"),
            "Basic abc"
        )
    }

    func testExtractBearerTokenBearerRemainderWithSpaces() {
        // Remainder may contain spaces; only outer-trimmed.
        XCTAssertEqual(
            QoderAccessValidator.extractBearerToken("Bearer a b c"),
            "a b c"
        )
    }

    /// Go parity: the delimiter is `" "` only — a tab does NOT split the
    /// scheme, so `"Bearer\tsecret"` is returned whole.
    func testExtractBearerTokenTabIsNotDelimiter() {
        XCTAssertEqual(
            QoderAccessValidator.extractBearerToken("Bearer\tsecret"),
            "Bearer\tsecret"
        )
    }

    // MARK: - queryValue edge cases (Go `net/url` parity)

    func testQueryValueAbsent() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/v1/chat/completions"),
            ""
        )
    }

    func testQueryValueFirstOccurrenceWins() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=first&key=second"),
            "first"
        )
    }

    func testQueryValuePercentDecoded() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=sec%72et"),
            "secret"
        )
    }

    /// Go parity: `+` → space in values.
    func testQueryValuePlusDecodesToSpace() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=a+b"),
            "a b"
        )
    }

    /// Go parity: parameter names are percent-decoded too.
    func testQueryValueParamNamePercentDecoded() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?%6bey=secret"),
            "secret"
        )
    }

    /// Go parity: a malformed escape DROPS the pair — no raw fallback.
    func testQueryValueMalformedPercentDropsPair() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=sec%ZZet"),
            ""
        )
    }

    /// A malformed escape on the NAME side drops the pair too.
    func testQueryValueMalformedNameDropsPair() {
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?%ZZey=secret"),
            ""
        )
    }

    func testQueryValueStopsAtFragment() {
        // Fragment is excluded from query parse.
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=ok#key=evil"),
            "ok"
        )
    }

    func testQueryValueValueContainingEquals() {
        // Split on FIRST `=` only.
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key=a=b=c"),
            "a=b=c"
        )
    }

    func testQueryValueFlagStyleParameterIgnored() {
        // `?key` with no `=` is flag-style; neither name nor value is a
        // `name=value` pair, so no candidate.
        XCTAssertEqual(
            QoderAccessValidator.queryValue(for: "key", in: "/p?key"),
            ""
        )
    }

    // MARK: - constantTimeEquals edge cases

    func testConstantTimeEqualsEqual() {
        XCTAssertTrue(QoderAccessValidator.constantTimeEquals("secret", "secret"))
    }

    func testConstantTimeEqualsUnequalLength() {
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("secret", "secre"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("sec", "secret"))
    }

    func testConstantTimeEqualsEmptyEmpty() {
        XCTAssertTrue(QoderAccessValidator.constantTimeEquals("", ""))
    }

    func testConstantTimeEqualsEmptyVsNonEmpty() {
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("", "a"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("a", ""))
    }

    func testConstantTimeEqualsSingleBitDifference() {
        // 'a' (0x61) vs 'b' (0x62) differ in a single bit (0x03).
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("a", "b"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("secret", "secrft"))
    }

    /// XOR-cancellation regression: the accumulator must be OR, not XOR. With
    /// XOR, two differing positions carrying equal XOR-deltas cancel back to
    /// zero and would compare equal — a false-accept in the auth gate.
    /// ("ab" vs "ba": ('a'^'b') ^ ('b'^'a') == 0.)
    func testConstantTimeEqualsXorCancellation() {
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("ab", "ba"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("aa", "bb"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("abcd", "bcda"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("sk-x1", "sk-y0"))
    }

    /// The cancellation pairs must NOT authenticate either — pin the gate,
    /// not just the helper.
    func testAuthenticateRejectsXorCancellationCandidate() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["ab"])
        let decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer ba")]
        )
        XCTAssertEqual(decision, .invalid)
    }

    func testConstantTimeEqualsMultiByteUTF8() {
        // UTF-8 byte views are compared, not code points.
        XCTAssertTrue(QoderAccessValidator.constantTimeEquals("sëcret", "sëcret"))
        XCTAssertFalse(QoderAccessValidator.constantTimeEquals("sëcret", "secret"))
    }

    // MARK: - extractCandidates (order + presence)

    /// Pin the five-source order explicitly. This guards against a future
    /// refactor silently reordering the sources (which would break the
    /// precedence semantics tested above).
    func testCandidatesInCpaOrder() {
        let extraction = QoderAccessValidator.extractCandidates(
            path: "/p?key=qkey&auth_token=qat",
            headers: [
                ("Authorization", "Bearer authz"),
                ("X-Goog-Api-Key", "goog"),
                ("X-Api-Key", "api")
            ]
        )
        XCTAssertEqual(extraction.candidates, ["authz", "goog", "api", "qkey", "qat"])
        XCTAssertTrue(extraction.anySourcePresent)
    }

    /// When Authorization uses a non-bearer scheme, candidate[0] is the WHOLE
    /// header value (per extractBearerToken).
    func testCandidatesBasicSchemeYieldsWholeHeader() {
        let extraction = QoderAccessValidator.extractCandidates(
            path: "/p",
            headers: [("Authorization", "Basic abc")]
        )
        XCTAssertEqual(extraction.candidates.first, "Basic abc")
        XCTAssertTrue(extraction.anySourcePresent)
    }

    /// Presence flag: false only when all five sources are empty.
    func testCandidatesNoSourcePresent() {
        let extraction = QoderAccessValidator.extractCandidates(path: "/p", headers: [])
        XCTAssertFalse(extraction.anySourcePresent)
    }

    /// Presence flag: `Authorization: Bearer ` (empty candidate) is still a
    /// PRESENT source — the missing-vs-invalid subtlety, pinned at the
    /// extraction level.
    func testCandidatesPresentWhenBearerEmptySuffix() {
        let extraction = QoderAccessValidator.extractCandidates(
            path: "/p",
            headers: [("Authorization", "Bearer ")]
        )
        XCTAssertTrue(extraction.anySourcePresent)
        XCTAssertEqual(extraction.candidates.first, "")
    }

    /// Presence flag: a malformed-escape `?key=` pair is ABSENT (Go drops the
    /// pair, `Query().Get` returns ""), while a clean query pair is present.
    func testCandidatesPresenceForMalformedAndCleanQuery() {
        let malformed = QoderAccessValidator.extractCandidates(
            path: "/p?key=sec%ZZet",
            headers: []
        )
        XCTAssertFalse(malformed.anySourcePresent)

        let clean = QoderAccessValidator.extractCandidates(path: "/p?key=x", headers: [])
        XCTAssertTrue(clean.anySourcePresent)
    }

    // MARK: - Reload replaces (not merges) the snapshot

    /// A second reload with a different key set must REPLACE the prior snapshot,
    /// not union with it. A key only in the old set must no longer authenticate.
    func testReloadReplacesNotMerges() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["old-secret"])
        var decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer old-secret")]
        )
        assertAllowed(decision, "old-secret")

        await v.reload(keys: ["new-secret"])
        decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer old-secret")]
        )
        XCTAssertEqual(decision, .invalid)

        decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer new-secret")]
        )
        assertAllowed(decision, "new-secret")
    }

    /// Reloading to an empty set re-enables `.notConfigured` pass-through —
    /// the user removing all keys is the user disabling auth (CPA legacy).
    func testReloadToEmptyReenablesNotConfigured() async {
        let v = QoderAccessValidator()
        await v.reload(keys: ["secret"])
        var decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        assertAllowed(decision, "secret")

        await v.reload(keys: [])
        decision = await v.authenticate(
            path: "/v1/chat/completions",
            headers: [("Authorization", "Bearer secret")]
        )
        XCTAssertEqual(decision, .notConfigured)
    }
}
