//
//  SelectAllActivationTests.swift
//  MarkdownEngineTests
//
//  ⌘A (and any selection that merely OVERLAPS rendered elements) must not
//  un-render anything — activation is caret-based for every token kind.
//  Math had a selection-intersection special case that made ⌘A reveal every
//  formula in the document and reflow it wholesale (2026-07-04 field report,
//  the same behavior Obsidian users report as "jumpiness").
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Select-all activation")
struct SelectAllActivationTests {

    private let doc = """
    # 标题

    品质因子 $n$ 略大于 1, 串联电阻 $R<0$ 显然与事实不符.

    $$E = mc^2$$

    | a | b |
    | --- | --- |
    | 1 | 2 |

    **bold** and *italic* prose.
    """

    private func activeKinds(selection: NSRange) -> Set<MarkdownTokenKind> {
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: doc)
        let indices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: selection,
            tokens: tokens,
            in: doc as NSString
        )
        return Set(indices.map { tokens[$0].kind })
    }

    @Test("a selection lying entirely inside a table keeps the table revealed")
    func selectionInsideTableKeepsItActive() {
        let text = "intro\n\n| a | b |\n|---|---|\n| one | two |\n\noutro"
        let ns = text as NSString
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let inside = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: ns.range(of: "one"), tokens: tokens, in: ns)
        #expect(inside.contains { tokens[$0].kind == .table })
        // A selection reaching past the table collapses it, as before.
        let across = NSRange(location: 0, length: ns.range(of: "two").location)
        let overlapping = MarkdownDetection.computeActiveTokenIndices(selectionRange: across, tokens: tokens, in: ns)
        #expect(!overlapping.contains { tokens[$0].kind == .table })
    }

    @Test("select-all activates nothing beyond the token at the caret edge")
    func selectAllActivatesNothingInside() {
        let all = NSRange(location: 0, length: (doc as NSString).length)
        let kinds = activeKinds(selection: all)
        #expect(!kinds.contains(.inlineLatex), "⌘A must not reveal inline math")
        #expect(!kinds.contains(.blockLatex), "⌘A must not reveal block math")
        #expect(!kinds.contains(.table), "⌘A must not reveal tables")
    }

    @Test("a drag across a formula does not reveal it; the caret inside does")
    func mathRevealIsCaretBased() {
        let ns = doc as NSString
        let mathStart = ns.range(of: "$n$").location

        // Selection STARTING BEFORE and covering the formula: not active.
        let across = NSRange(location: mathStart - 4, length: 10)
        #expect(!activeKinds(selection: across).contains(.inlineLatex))

        // Caret INSIDE the formula: active.
        let inside = NSRange(location: mathStart + 1, length: 0)
        #expect(activeKinds(selection: inside).contains(.inlineLatex))
    }

    /// Review 2026-07-07: `selectionRange.location` is the selection's LOW
    /// endpoint, so a non-zero selection whose anchor sits inside an element
    /// used to still reveal that one element (⌘A on a doc starting with math,
    /// or a drag anchored inside a formula). A non-zero selection must reveal
    /// NOTHING regardless of where its endpoints land.
    @Test("selection anchored at offset 0 (math-first doc) reveals nothing")
    func selectAllOnElementAtOffsetZeroRevealsNothing() {
        let mathFirst = "$E=mc^2$ and then prose follows here.\n\nMore prose."
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: mathFirst)
        let all = NSRange(location: 0, length: (mathFirst as NSString).length)
        let kinds = Set(
            MarkdownDetection.computeActiveTokenIndices(selectionRange: all, tokens: tokens, in: mathFirst as NSString)
                .map { tokens[$0].kind }
        )
        #expect(kinds.isEmpty, "⌘A on a math-first doc must not reveal the math at offset 0, got \(kinds)")
    }

    @Test("a drag whose low endpoint is inside a formula does not reveal it")
    func dragAnchoredInsideFormulaRevealsNothing() {
        let ns = doc as NSString
        let mathStart = ns.range(of: "$R<0$").location
        // Selection anchored INSIDE the formula, extending past it.
        let anchoredInside = NSRange(location: mathStart + 1, length: 12)
        #expect(!activeKinds(selection: anchoredInside).contains(.inlineLatex),
                "a drag anchored inside a formula must not reveal it")
    }
}
