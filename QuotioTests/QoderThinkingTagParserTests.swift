//
//  QoderThinkingTagParserTests.swift
//  QuotioTests
//
//  Phase 2b tests for the thinking-tag streaming splitter (ADR 0004, ADR 0007
//  §3). Ported from pi-provider-qoder/src/__tests__/thinking-parser.test.ts —
//  each vitest case maps to one XCTest golden vector, asserting the parser
//  produces the same text/thinking split as the TypeScript reference.
//
//  The pi suite asserts against an `output.content` block model with
//  block-index splice semantics; the Swift port returns flat `.text` /
//  `.thinking` emissions and skips pi-ai's SDK block layer (ADR 0004: "one
//  fewer layer"). Assertions are re-expressed in terms of the concatenated
//  text and concatenated thinking the emissions carry, plus ordering checks
//  where order matters (e.g. orphan-closer + trailing text).
//

import XCTest
@testable import Quotio

final class QoderThinkingTagParserTests: XCTestCase {

    // MARK: - Helpers

    /// Concatenate all `.text` emissions from a sequence of process/finalize
    /// calls. Each input string is fed as one chunk; finalize is always run.
    private func allText(_ chunks: [String]) -> String {
        var parser = QoderThinkingTagParser()
        var emissions: [QoderThinkingEmission] = []
        for chunk in chunks {
            emissions.append(contentsOf: parser.processChunk(chunk))
        }
        emissions.append(contentsOf: parser.finalize())
        return emissions.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }

    /// Concatenate all `.thinking` emissions across process+finalize.
    private func allThinking(_ chunks: [String]) -> String {
        var parser = QoderThinkingTagParser()
        var emissions: [QoderThinkingEmission] = []
        for chunk in chunks {
            emissions.append(contentsOf: parser.processChunk(chunk))
        }
        emissions.append(contentsOf: parser.finalize())
        return emissions.compactMap { if case .thinking(let t) = $0 { return t } else { return nil } }.joined()
    }

    /// Full emission list across process+finalize (for order-sensitive tests).
    private func allEmissions(_ chunks: [String]) -> [QoderThinkingEmission] {
        var parser = QoderThinkingTagParser()
        var emissions: [QoderThinkingEmission] = []
        for chunk in chunks {
            emissions.append(contentsOf: parser.processChunk(chunk))
        }
        emissions.append(contentsOf: parser.finalize())
        return emissions
    }

    // MARK: - Plain text (no thinking tags)

    /// "passes plain text through without modification"
    func testPlainTextPassesThrough() {
        XCTAssertEqual(allText(["Hello world"]), "Hello world")
        XCTAssertEqual(allThinking(["Hello world"]), "")
    }

    /// "handles empty input"
    func testEmptyInputProducesNothing() {
        XCTAssertTrue(allEmissions([]).isEmpty, "empty input must produce no emissions")
    }

    // MARK: - Standard <thinking> tags

    /// "extracts thinking content from <thinking> tags"
    /// pi: `Hello <thinking>reasoning here</thinking> world` → text "Hello "
    /// + thinking "reasoning here" + text " world". The Swift port preserves
    /// the text/thinking split but NOT pi's block splice ordering — we emit in
    /// arrival order: text "Hello ", thinking "reasoning here", text " world".
    func testExtractsThinkingFromThinkingTags() {
        let emissions = allEmissions(["Hello <thinking>reasoning here</thinking> world"])
        XCTAssertEqual(emissions, [
            .text("Hello "),
            .thinking("reasoning here"),
            .text(" world"),
        ])
    }

    /// "handles thinking-only content"
    func testThinkingOnlyContent() {
        XCTAssertEqual(allThinking(["<thinking>just thinking</thinking>"]), "just thinking")
        XCTAssertEqual(allText(["<thinking>just thinking</thinking>"]), "")
    }

    // MARK: - Alternative tag variants

    /// "handles <think> tags"
    func testHandlesThinkTags() {
        let emissions = allEmissions(["Hello <think>reasoning</think> world"])
        XCTAssertEqual(emissions, [
            .text("Hello "),
            .thinking("reasoning"),
            .text(" world"),
        ])
    }

    /// "handles <reasoning> tags"
    func testHandlesReasoningTags() {
        XCTAssertEqual(allThinking(["<reasoning>deep thought</reasoning>"]), "deep thought")
    }

    /// "handles <thought> tags"
    func testHandlesThoughtTags() {
        XCTAssertEqual(allThinking(["<thought>pondering</thought>"]), "pondering")
    }

    // MARK: - Chunked streaming (cross-delta buffering) — the trickiest port

    /// "handles thinking content split across multiple chunks"
    /// `<thin` + `king>part1 ` + `part2</think` + `ing> world`. The opener
    /// `<thinking>` and closer `</thinking>` each resolve across two chunks;
    /// the parser holds the partial tags back and emits:
    ///   text "Hello "  (held back until the opener resolves)
    ///   thinking "part1 " then thinking "part2"  (two deltas, as pi emits two
    ///     thinking_delta events that accumulate into one block)
    ///   text " world"
    /// Concatenated thinking = "part1 part2" (matches pi's accumulated block).
    func testThinkingSplitAcrossChunks() {
        let chunks = ["Hello <thin", "king>part1 ", "part2</think", "ing> world"]
        XCTAssertEqual(allThinking(chunks), "part1 part2")
        XCTAssertEqual(allText(chunks), "Hello  world")
        // Emission order: text, thinking, thinking, text (cross-delta split
        // produces two thinking deltas, as pi's event stream does).
        XCTAssertEqual(allEmissions(chunks), [
            .text("Hello "),
            .thinking("part1 "),
            .thinking("part2"),
            .text(" world"),
        ])
    }

    /// "handles open tag split across chunks"
    /// `text <thin` + `king>body</thinking>` → text "text " + thinking "body".
    func testOpenTagSplitAcrossChunks() {
        let emissions = allEmissions([
            "text <thin",
            "king>body</thinking>",
        ])
        XCTAssertEqual(emissions, [
            .text("text "),
            .thinking("body"),
        ])
    }

    // MARK: - Multiple thinking blocks (one-shot behavior)

    /// "handles multiple thinking blocks" — pi only extracts the FIRST block.
    /// After the first block's closer, `thinkingExtracted` is set and the
    /// parser emits remaining text verbatim, so a second `<thinking>` lands in
    /// text, not thinking. ADR 0004 says "parity", so we match the one-shot.
    func testMultipleBlocksOnlyExtractsFirst() {
        let emissions = allEmissions(["<thinking>first</thinking> text <thinking>second</thinking>"])
        XCTAssertEqual(allThinking(["<thinking>first</thinking> text <thinking>second</thinking>"]), "first")
        // The second <thinking>second</thinking> survives as text (one-shot).
        XCTAssertTrue(allText(["<thinking>first</thinking> text <thinking>second</thinking>"])
            .contains("<thinking>second</thinking>"),
            "second block should pass through as text after one-shot extraction")
        // First emission is the first thinking block.
        XCTAssertEqual(emissions.first, .thinking("first"))
    }

    // MARK: - Edge cases

    /// "handles text ending with partial tag prefix"
    /// `Hello <think` (no closer, no finalize trigger mid-stream) then finalize
    /// → the held-back `<think` flushes as text alongside "Hello ".
    func testPartialTagPrefixHeldBackThenFlushed() {
        let emissions = allEmissions(["Hello <think"])
        let text = emissions.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("<think"), "held-back partial prefix must flush on finalize")
    }

    /// "strips trailing newline after closing tag"
    /// `<thinking>thought</thinking>\n\nActual text` → thinking "thought" +
    /// text "Actual text" (the `\n\n` separator is dropped per pi).
    func testStripsTrailingNewlineAfterClosingTag() {
        let emissions = allEmissions(["<thinking>thought</thinking>\n\nActual text"])
        XCTAssertEqual(emissions, [
            .thinking("thought"),
            .text("Actual text"),
        ])
    }

    /// A single trailing `\n` after the closer is also stripped (pi strips one
    /// `\n` when `\n\n` isn't present, in the orphan-closer branch). For the
    /// inside-thinking closer, pi strips `\n\n` only; verify that behavior.
    func testInsideThinkingCloserStripsDoubleNewlineOnly() {
        let emissions = allEmissions(["<thinking>t</thinking>\nkeep"])
        XCTAssertEqual(emissions, [
            .thinking("t"),
            .text("\nkeep"),
        ])
    }

    // MARK: - Orphan closing tags (opener arrived via reasoning_content)

    /// "drops an orphan closing tag at the start of content"
    /// Regression: Qoder's backend splits a `<thinking>...</thinking>` pair
    /// across two SSE fields — opener + reasoning into `reasoning_content`,
    /// closer + answer into `content`. The closer has no opener in the content
    /// stream, so it must be dropped, not leaked into visible text.
    func testDropsOrphanCloserAtStart() {
        let text = allText(["</thinking>\n\n让我查一下这个选项"])
        XCTAssertEqual(text, "让我查一下这个选项")
        XCTAssertFalse(text.contains("</thinking>"))
        XCTAssertEqual(allThinking(["</thinking>\n\n让我查一下这个选项"]), "")
    }

    /// "drops an orphan closer split across stream chunks"
    func testDropsOrphanCloserSplitAcrossChunks() {
        let text = allText(["</think", "ing>\n\nanswer"])
        XCTAssertEqual(text, "answer")
        XCTAssertFalse(text.contains("</think"))
        XCTAssertFalse(text.contains("ing>"))
    }

    /// "drops an orphan closer for the <reasoning> variant too"
    func testDropsOrphanCloserReasoningVariant() {
        let text = allText(["</reasoning>\n\nresult"])
        XCTAssertEqual(text, "result")
        XCTAssertFalse(text.contains("</reasoning>"))
    }

    /// "emits text before an orphan closer, then drops the closer"
    func testEmitsTextBeforeOrphanCloser() {
        let text = allText(["intro</thinking>\n\noutro"])
        XCTAssertFalse(text.contains("</thinking>"))
        XCTAssertTrue(text.contains("intro"))
        XCTAssertTrue(text.contains("outro"))
    }

    // MARK: - Finalize with remaining buffer

    /// "finalize flushes remaining text when not in thinking mode"
    func testFinalizeFlushesRemainingText() {
        XCTAssertEqual(allText(["partial"]), "partial")
    }

    /// "finalize flushes remaining thinking when in thinking mode"
    func testFinalizeFlushesRemainingThinking() {
        XCTAssertEqual(allThinking(["<thinking>unfinished"]), "unfinished")
    }

    // MARK: - stripThinkingTags helper

    /// "stripThinkingTags removes opening and closing tag variants"
    func testStripThinkingTagsRemovesVariants() {
        XCTAssertEqual(qoderStripThinkingTags("<thinking>hello</thinking>"), "hello")
        XCTAssertEqual(qoderStripThinkingTags("<reasoning>deep</reasoning>"), "deep")
        XCTAssertEqual(qoderStripThinkingTags("plain text"), "plain text")
        XCTAssertEqual(qoderStripThinkingTags("<thinking>"), "")
        XCTAssertEqual(qoderStripThinkingTags("</thinking>"), "")
    }

    /// stripThinkingTags handles all four variants and mixed occurrences.
    func testStripThinkingTagsAllVariants() {
        XCTAssertEqual(qoderStripThinkingTags("<think>a</think> <thought>b</thought>"), "a b")
    }

    /// Idempotent: stripping an already-clean string is a no-op.
    func testStripThinkingTagsIdempotent() {
        let cleaned = qoderStripThinkingTags("<thinking>x</thinking>")
        XCTAssertEqual(qoderStripThinkingTags(cleaned), cleaned)
    }

    // MARK: - Emission ordering

    /// Text emitted before the opener must arrive before the thinking emission,
    /// and text after the closer must arrive after — order is load-bearing for
    /// the SSE re-encode (the agent renders deltas in order).
    func testEmissionOrderPreAndPostThinking() {
        let emissions = allEmissions(["before <thinking>mid</thinking> after"])
        XCTAssertEqual(emissions, [
            .text("before "),
            .thinking("mid"),
            .text(" after"),
        ])
    }
}
