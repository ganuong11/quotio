//
//  QoderThinkingTagParser.swift
//  Quotio
//
//  Phase 2b (ADR 0004, ADR 0007 §3): streaming splitter for thinking/reasoning
//  tags embedded in Qoder's `delta.content` channel. Ported for parity from
//  pi-provider-qoder/src/thinking-parser.ts. Pure value type — no I/O, no actor
//  state, no globals. Owned as a per-stream `var` inside `QoderSSEReparser`,
//  which feeds each `delta.content` chunk through `processChunk` and maps the
//  returned emissions to OpenAI SSE (`.text` → `delta.content`, `.thinking` →
//  `delta.reasoning_content`).
//
//  What is ported: the parsing state machine only — `textBuffer`, `inThinking`,
//  `thinkingExtracted`, `activeEndTag`, the three `process*` branches, the
//  trailing-possible-tag-prefix holdback (so a tag split across stream deltas is
//  not partially emitted as text), the orphan-closer drop (Qoder's backend
//  routes the `<thinking>` opener into `reasoning_content` and the matching
//  `</thinking>` closer into `content` — the closer has no opener here and must
//  not leak into visible text), and the `stripThinkingTags` helper.
//
//  What is NOT ported: pi's block-index/splice/event-push machinery
//  (thinking-parser.ts lines ~201-234 — the `emitText`/`emitThinking` methods
//  that mutate an `AssistantMessage.content` array and push
//  `AssistantMessageEvent`s onto a pi-ai SDK stream). ADR 0004 explicitly skips
//  the pi-ai SDK layer ("one fewer layer"); Quotio re-encodes to OpenAI SSE
//  instead, so the parser returns typed emissions and the caller owns the wire
//  format.
//

import Foundation

/// Tag variants Qoder's backend may route into the content stream. Order
/// matters only for determinism in the "first tag wins" scan; pi lists
/// `<thinking>` first and we match.
nonisolated let QODER_THINKING_TAG_VARIANTS: [(open: String, close: String)] = [
    (open: "<thinking>", close: "</thinking>"),
    (open: "<think>", close: "</think>"),
    (open: "<reasoning>", close: "</reasoning>"),
    (open: "<thought>", close: "</thought>"),
]

/// A parsed piece of one chunk: either visible text or extracted reasoning.
/// The caller (`QoderSSEReparser`) maps `.text` → `delta.content` and
/// `.thinking` → `delta.reasoning_content`. Order in the returned array is the
/// order the pieces should be emitted.
nonisolated enum QoderThinkingEmission: Sendable, Equatable {
    case text(String)
    case thinking(String)
}

/// One-shot streaming splitter for thinking/reasoning tags inside the content
/// channel. Faithful port of pi's `ThinkingTagParser` state machine.
///
/// `nonisolated struct` with `mutating func` → callable from any isolation
/// domain; in practice owned as a per-stream `var` inside the reparser, which
/// itself is a per-request `var` inside the ProxyBridge actor. Never shared.
/// Matches `QoderSSEReparser` / `QoderWAFEncoder` / `QoderCOSYSigner`.
nonisolated struct QoderThinkingTagParser {
    /// Bytes received but not yet resolvable (a partial tag prefix at the tail
    /// is held back until the next chunk or `finalize()`).
    private var textBuffer: String = ""

    /// True while inside an opener/close pair (between `<thinking>` and its
    /// matching `</thinking>`). Once the closer lands, `thinkingExtracted`
    /// becomes true and the parser never re-enters thinking.
    private var inThinking: Bool = false

    /// Set once after the first thinking block's closer is consumed. Pi's
    /// `processAfterThinking` then emits remaining text verbatim (the second
    /// `<thinking>` in `a<th>1</h> b <th>2</h>` is NOT re-extracted — pi's
    /// vitest "handles multiple thinking blocks" pins this). ADR 0004 says
    /// "parity", so we match the one-shot behavior.
    private var thinkingExtracted: Bool = false

    /// The close tag matching the opener that opened the current thinking
    /// block. Defaults to `</thinking>` (pi's first variant) but is set from
    /// whichever variant's opener actually opened the block.
    private var activeEndTag: String = QODER_THINKING_TAG_VARIANTS[0].close

    /// Test seam default constructor.
    init() {}

    // MARK: - Entry points

    /// Feed one content delta. Returns the emissions produced this chunk, in
    /// order. A trailing partial-tag prefix is held back in the buffer and
    /// surfaces only when a later chunk resolves it or `finalize()` flushes.
    mutating func processChunk(_ chunk: String) -> [QoderThinkingEmission] {
        textBuffer.append(chunk)
        var emissions: [QoderThinkingEmission] = []
        // Mirror pi's loop: each branch may shrink the buffer; loop until no
        // progress is made.
        while !textBuffer.isEmpty {
            let prevLength = textBuffer.count
            if !inThinking && !thinkingExtracted {
                processBeforeThinking(into: &emissions)
                if textBuffer.isEmpty { break }
            }
            if inThinking {
                processInsideThinking(into: &emissions)
                if textBuffer.isEmpty { break }
            }
            if thinkingExtracted {
                processAfterThinking(into: &emissions)
                break
            }
            // No progress → stop (avoids an infinite loop when nothing resolves).
            if textBuffer.count >= prevLength { break }
        }
        return emissions
    }

    /// Flush any buffered content. Called once at stream end. If currently
    /// inside a thinking block, the remainder is emitted as thinking; otherwise
    /// as text. Idempotent — a second call produces nothing (buffer is cleared).
    mutating func finalize() -> [QoderThinkingEmission] {
        guard !textBuffer.isEmpty else { return [] }
        let leftover = textBuffer
        textBuffer.removeAll(keepingCapacity: false)
        if inThinking {
            return [.thinking(leftover)]
        }
        return emitText(leftover)
    }

    // MARK: - State-machine branches (ports of pi's process* methods)

    /// Pi `processBeforeThinking`: scan for the first opener and first closer.
    /// Opener-first → enter thinking. Orphan closer (no preceding opener) →
    /// drop it + its trailing separator whitespace. Neither yet → hold back any
    /// trailing prefix that could be the start of any tag.
    private mutating func processBeforeThinking(into emissions: inout [QoderThinkingEmission]) {
        // First opener + first closer across all variants (earliest position wins).
        var bestOpenPos: String.Index? = nil
        var bestOpenVariant: (open: String, close: String)? = nil
        var bestClosePos: String.Index? = nil
        var bestCloseVariant: (open: String, close: String)? = nil
        for variant in QODER_THINKING_TAG_VARIANTS {
            if let openPos = textBuffer.range(of: variant.open)?.lowerBound {
                if bestOpenPos == nil || openPos < bestOpenPos! {
                    bestOpenPos = openPos
                    bestOpenVariant = variant
                }
            }
            if let closePos = textBuffer.range(of: variant.close)?.lowerBound {
                if bestClosePos == nil || closePos < bestClosePos! {
                    bestClosePos = closePos
                    bestCloseVariant = variant
                }
            }
        }

        // Opener comes first (or is the only tag): a real thinking block in the
        // content stream. Emit any text before it, consume the opener, switch
        // to thinking mode. processInsideThinking handles the closer.
        if let openVariant = bestOpenVariant,
           bestCloseVariant == nil || bestOpenPos! < bestClosePos! {
            let openPos = bestOpenPos!
            if openPos > textBuffer.startIndex {
                emissions.append(contentsOf: emitText(String(textBuffer[textBuffer.startIndex..<openPos])))
            }
            textBuffer.removeSubrange(textBuffer.startIndex..<textBuffer.index(openPos, offsetBy: openVariant.open.count))
            activeEndTag = openVariant.close
            inThinking = true
            return
        }

        // Orphan closer: its matching opener arrived via the separate
        // `reasoning_content` channel (see QoderSSEReparser), so there is no
        // thinking block to close here. Emit text before it, drop the closer,
        // and drop the separator whitespace the model emits right after
        // (`\n\n` or a single `\n`) so it doesn't leak into visible text.
        if let closeVariant = bestCloseVariant {
            let closePos = bestClosePos!
            if closePos > textBuffer.startIndex {
                emissions.append(contentsOf: emitText(String(textBuffer[textBuffer.startIndex..<closePos])))
            }
            textBuffer.removeSubrange(textBuffer.startIndex..<textBuffer.index(closePos, offsetBy: closeVariant.close.count))
            if textBuffer.hasPrefix("\n\n") {
                textBuffer.removeFirst(2)
            } else if textBuffer.hasPrefix("\n") {
                textBuffer.removeFirst()
            }
            return
        }

        // No complete tag yet. Hold back any trailing prefix that could be the
        // start of ANY opener or closer, so a tag split across stream deltas is
        // not partially emitted as text.
        let allTags = QODER_THINKING_TAG_VARIANTS.flatMap { [$0.open, $0.close] }
        let trailingLength = maxTrailingPossibleTagPrefixLength(textBuffer, tags: allTags)
        let safeEndIndex = textBuffer.index(textBuffer.endIndex, offsetBy: -trailingLength)
        if safeEndIndex > textBuffer.startIndex {
            let safe = String(textBuffer[textBuffer.startIndex..<safeEndIndex])
            emissions.append(contentsOf: emitText(safe))
            textBuffer.removeSubrange(textBuffer.startIndex..<safeEndIndex)
        }
    }

    /// Pi `processInsideThinking`: look for the active close tag. Found → emit
    /// any thinking text before it, end the block, switch to thinkingExtracted,
    /// strip a trailing `\n\n`. Not found → emit thinking up to a possible
    /// partial closer at the tail (hold the partial back).
    private mutating func processInsideThinking(into emissions: inout [QoderThinkingEmission]) {
        if let endRange = textBuffer.range(of: activeEndTag) {
            let endPos = endRange.lowerBound
            if endPos > textBuffer.startIndex {
                emissions.append(.thinking(String(textBuffer[textBuffer.startIndex..<endPos])))
            }
            textBuffer.removeSubrange(textBuffer.startIndex..<textBuffer.index(endPos, offsetBy: activeEndTag.count))
            inThinking = false
            thinkingExtracted = true
            if textBuffer.hasPrefix("\n\n") {
                textBuffer.removeFirst(2)
            }
            return
        }

        // No closer yet — emit thinking up to a possible partial closer at the
        // tail (the next chunk may complete it).
        let trailingLength = trailingPossibleTagPrefixLength(textBuffer, tag: activeEndTag)
        let safeEndIndex = textBuffer.index(textBuffer.endIndex, offsetBy: -trailingLength)
        if safeEndIndex > textBuffer.startIndex {
            emissions.append(.thinking(String(textBuffer[textBuffer.startIndex..<safeEndIndex])))
            textBuffer.removeSubrange(textBuffer.startIndex..<safeEndIndex)
        }
    }

    /// Pi `processAfterThinking`: after the first thinking block, every
    /// remaining byte is plain text (the one-shot rule). Emit and clear.
    private mutating func processAfterThinking(into emissions: inout [QoderThinkingEmission]) {
        emissions.append(contentsOf: emitText(textBuffer))
        textBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Helpers

    /// Wrap a text fragment as a `.text` emission, dropping empty strings
    /// (pi's `if (!text) return`). A single input never yields more than one
    /// emission, but the array shape matches the other branches for uniform
    /// `append(contentsOf:)` use.
    private func emitText(_ text: String) -> [QoderThinkingEmission] {
        guard !text.isEmpty else { return [] }
        return [.text(text)]
    }

    /// Largest `len > 0` such that `text` ends with `tag.prefix(len)`, or 0.
    /// Port of pi's `getTrailingPossibleTagPrefixLength`.
    private func trailingPossibleTagPrefixLength(_ text: String, tag: String) -> Int {
        let maxPrefixLength = min(text.count, tag.count - 1)
        guard maxPrefixLength > 0 else { return 0 }
        // Walk from longest to shortest; first match wins (largest).
        for len in stride(from: maxPrefixLength, through: 1, by: -1) {
            let prefix = String(tag.prefix(len))
            if text.hasSuffix(prefix) {
                return len
            }
        }
        return 0
    }

    /// Max over all tags of `trailingPossibleTagPrefixLength`. Port of pi's
    /// `getMaxTrailingPossibleTagPrefixLength`.
    private func maxTrailingPossibleTagPrefixLength(_ text: String, tags: [String]) -> Int {
        var maxLength = 0
        for tag in tags {
            maxLength = max(maxLength, trailingPossibleTagPrefixLength(text, tag: tag))
        }
        return maxLength
    }
}

// MARK: - stripThinkingTags (free function, ported verbatim)

/// Remove every thinking/reasoning tag variant (open and close) from `text`.
/// Best-effort per call: a tag split across deltas is not caught here — the
/// `QoderThinkingTagParser` handles the content-channel side with cross-delta
/// buffering; this function strips the artifacts Qoder routes into the
/// `reasoning_content` channel (a literal `<thinking>` opener sometimes lands
/// there, with the matching `</thinking>` closer landing in `content`).
///
/// Port of pi's `stripThinkingTags`. `nonisolated` so the SSEReparser can call
/// it from its own isolation domain.
nonisolated func qoderStripThinkingTags(_ text: String) -> String {
    var out = text
    for variant in QODER_THINKING_TAG_VARIANTS {
        if !variant.open.isEmpty {
            out = out.replacingOccurrences(of: variant.open, with: "")
        }
        if !variant.close.isEmpty {
            out = out.replacingOccurrences(of: variant.close, with: "")
        }
    }
    return out
}
