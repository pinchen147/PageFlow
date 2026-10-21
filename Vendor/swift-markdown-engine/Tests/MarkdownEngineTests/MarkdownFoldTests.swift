import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Canonical heading folds")
struct MarkdownFoldTests {
    private func index(_ source: String) -> MarkdownFoldIndex {
        MarkdownFoldIndex(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false))
    }

    @Test func nestedRanksCountsAndDuplicateTitles() {
        let regions = index("# A\na\n### A\nb\n## A\nc\n# A\nd").regions
        #expect(regions.map(\.heading) == [NSRange(location: 0, length: 4), NSRange(location: 6, length: 6), NSRange(location: 14, length: 5), NSRange(location: 21, length: 4)])
        #expect(regions.map(\.body) == [NSRange(location: 4, length: 17), NSRange(location: 12, length: 2), NSRange(location: 19, length: 2), NSRange(location: 25, length: 1)])
        #expect(regions.map(\.level) == [1, 3, 2, 1])
        #expect(regions.map(\.hiddenBlockCount) == [5, 1, 1, 1])
    }

    @Test func emptySectionsCRLFAndUnicode() {
        #expect(index("# Empty\n \t\n# End").regions.isEmpty)
        let regions = index("# 🐱\r\né\r\n\r\n## Z\r\n尾").regions
        #expect(regions.map(\.heading) == [NSRange(location: 0, length: 6), NSRange(location: 11, length: 6)])
        #expect(regions.map(\.body) == [NSRange(location: 6, length: 12), NSRange(location: 17, length: 1)])
        #expect(regions.map(\.hiddenBlockCount) == [3, 1])
    }

    @Test func canonicalOpaqueBlocksAreCountedOnce() {
        let source = "# A\n```\n# code\n```\n\n$$\n# math\n$$\n\n> # quote\n\n| a |\n| --- |\n| # cell |\n\n# B\nx"
        let regions = index(source).regions
        #expect(regions.count == 2)
        #expect(regions.first?.hiddenBlockCount == 4)
        #expect(index("Title\n=====\nbody").regions.isEmpty)
    }

    private func session(_ source: String) -> MarkdownFoldSession {
        let result = MarkdownFoldSession()
        update(result, source)
        return result
    }

    private func update(_ session: MarkdownFoldSession, _ source: String,
                        edit: (range: NSRange, replacementLength: Int)? = nil) {
        session.update(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false), edit: edit)
    }

    @Test func descendantsSurviveParentAndRevealOnlyTargetAncestors() {
        let state = session("# A\na\n## B\nb\n# C\nc")
        state.collapseAll()
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 9), NSRange(location: 17, length: 1)])
        state.toggle(at: 0)
        #expect(state.collapsedHeadings == [6, 13])
        #expect(state.hiddenRanges == [NSRange(location: 11, length: 2), NSRange(location: 17, length: 1)])
        state.toggle(at: 0)
        #expect(state.reveal(NSRange(location: 11, length: 0)))
        #expect(state.collapsedHeadings == [13])
        #expect(!state.reveal(NSRange(location: 13, length: 0)))
        state.expandAll()
        #expect(state.hiddenRanges.isEmpty)
    }

    @Test func preciseEditsMapAnchorsAndRetainTitleEdits() {
        let state = session("# A\na\n# B\nb")
        state.collapseAll()
        update(state, "intro\n# A\na\n# B\nb", edit: (NSRange(location: 0, length: 0), 6))
        #expect(state.collapsedHeadings == [6, 12])
        update(state, "intro\n# Changed\na\n# B\nb", edit: (NSRange(location: 8, length: 1), 7))
        #expect(state.collapsedHeadings == [6, 18])
        update(state, "intro\n# Changed\nmore\n# B\nb", edit: (NSRange(location: 16, length: 1), 4))
        #expect(state.collapsedHeadings == [6, 21])
        #expect(state.index.regions == index("intro\n# Changed\nmore\n# B\nb").regions)
    }

    @Test func replacedOpenersAndUnprovenEditsNeverTransferIdentity() {
        let state = session("# A\na\n# A\nb")
        state.collapseAll()
        update(state, "# A\nx\n# A\nb", edit: (NSRange(location: 0, length: 6), 6))
        #expect(state.collapsedHeadings == [6])
        update(state, "# A\nx\n# A\nb")
        #expect(state.collapsedHeadings == [6])
        update(state, "# A\nx\n# B\nb", edit: (NSRange(location: 4, length: 1), 1))
        #expect(state.collapsedHeadings.isEmpty)
        state.collapseAll()
        update(state, "# A\nx\n# C\nb")
        #expect(state.collapsedHeadings.isEmpty)
    }

    @Test func mappedInsertionsKeepNestedBodiesAndExactReceipt() {
        let state = session("# A\none\n## B\ntwo\n# C\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 6, length: 0), replacement: "XYZ", resultingLength: 27))
        #expect(state.collapsedHeadings == [0, 11, 20])
        #expect(state.index.regions.map(\.body) == [NSRange(location: 4, length: 16), NSRange(location: 16, length: 4), NSRange(location: 24, length: 3)])
        #expect(state.index.regions.map(\.hiddenBlockCount) == [3, 1, 1])
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 16), NSRange(location: 24, length: 3)])
        #expect(state.applyMappedEdit(range: NSRange(location: 27, length: 0), replacement: "尾", resultingLength: 28))
        #expect(state.index.regions.last?.body == NSRange(location: 24, length: 4))
        // A later canonical edit must validate against the advanced exact source receipt.
        update(state, "# A\nonXYZe\n## B\ntwo\n# C\nend尾!", edit: (NSRange(location: 28, length: 0), 1))
        #expect(state.collapsedHeadings == [0, 11, 20])
    }

    @Test func mappedHeadingInsertionGrowsTitleAndShiftsBody() {
        let state = session("# Ab\nx")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 3, length: 0), replacement: "cd", resultingLength: 8))
        #expect(state.index.regions.first?.heading == NSRange(location: 0, length: 7))
        #expect(state.index.regions.first?.body == NSRange(location: 7, length: 1))
        #expect(state.collapsedHeadings == [0])
    }

    @Test(arguments: ["\n", "\r\n", "intro\n", "intro\r"])
    func completeLineInsertionBeforeOpenerPreservesNestedChoices(_ prefix: String) {
        let original = "# A\nx\n## B\ny"
        let state = session(original)
        state.collapseAll()
        let shift = prefix.utf16.count
        #expect(state.applyMappedEdit(range: NSRange(location: 0, length: 0), replacement: prefix,
                                      resultingLength: 12 + shift))
        #expect(state.collapsedHeadings == [shift, 6 + shift])
        #expect(state.hiddenRanges == [NSRange(location: 4 + shift, length: 8)])
        let source = prefix + original
        #expect(state.reindex(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false)))
        state.toggle(at: shift)
        #expect(state.collapsedHeadings == [6 + shift])
        #expect(state.hiddenRanges == [NSRange(location: 11 + shift, length: 1)])
    }

    @Test func invalidMappedEditReceiptsLeaveSessionUntouched() {
        let state = session("# A\nword\n\n# B\nx")
        state.collapseAll()
        let original = state.index.regions
        for (range, length) in [(NSRange(location: -1, length: 0), 16),
                                (NSRange(location: 6, length: -1), 17),
                                (NSRange(location: 14, length: 2), 14),
                                (NSRange(location: 6, length: 0), 999),
                                (NSRange(location: 999, length: 0), 16)] {
            #expect(!state.applyMappedEdit(range: range, replacement: "x", resultingLength: length))
            #expect(state.index.regions == original)
            #expect(state.collapsedHeadings == [0, 10])
        }
    }

    @Test func mappedNewlineEditsReconcileCanonicalCountsForTheSameSource() {
        let state = session("# A\none\n# B\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 7, length: 0), replacement: "\n\nnew", resultingLength: 20))
        #expect(state.collapsedHeadings == [0, 13])
        #expect(state.index.regions.first?.hiddenBlockCount == 1)
        let source = "# A\none\n\nnew\n# B\nend"
        #expect(state.reindex(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false)))
        #expect(state.index.regions.first?.hiddenBlockCount == 2)
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 9), NSRange(location: 17, length: 3)])
    }

    @Test func typingAfterWhitespaceMakesAnEmptySectionFoldableOnReindex() {
        let state = session("# A\n \n# B\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 5, length: 0), replacement: "word", resultingLength: 17))
        #expect(state.index.regions.count == 1)
        #expect(state.collapsedHeadings == [10])
        let source = "# A\n word\n# B\nend"
        #expect(state.reindex(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false)))
        #expect(state.index.regions.map(\.hiddenBlockCount) == [1, 1])
        #expect(state.collapsedHeadings == [10])
        #expect(state.hiddenRanges == [NSRange(location: 14, length: 3)])
    }

    @Test func mappedTableCellEditKeepsAnUnrelatedCollapsedSectionAligned() {
        let state = session("# A\n| x |\n| --- |\n| y |\n# B\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 20, length: 1), replacement: "long", resultingLength: 34))
        #expect(state.collapsedHeadings == [0, 27])
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 23), NSRange(location: 31, length: 3)])
        #expect(state.index.regions.first?.hiddenBlockCount == 1)
    }

    @Test func staleCanonicalResultsCannotReplaceMappedVisibility() {
        let state = session("# A\none\n# B\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 5, length: 0), replacement: " ", resultingLength: 16))
        let stale = "# A\noxne\n# B\nend"
        #expect(!state.reindex(source: stale as NSString, blocks: BlockParser.parse(stale, memoizing: false)))
        #expect(state.collapsedHeadings == [0, 9])
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 5), NSRange(location: 13, length: 3)])
    }

    @Test func mappedDeletionDropsReplacedOpenersAndClampsCrossedBoundaries() {
        let state = session("# A\none\n# B\nend")
        state.collapseAll()
        #expect(state.applyMappedEdit(range: NSRange(location: 6, length: 6), replacement: "X", resultingLength: 10))
        #expect(state.collapsedHeadings == [0])
        #expect(state.index.regions.map(\.body) == [NSRange(location: 4, length: 3)])
        #expect(state.applyMappedEdit(range: NSRange(location: 10, length: 0), replacement: "尾", resultingLength: 11))
        let source = "# A\nonXend尾"
        #expect(state.reindex(source: source as NSString, blocks: BlockParser.parse(source, memoizing: false)))
        #expect(state.hiddenRanges == [NSRange(location: 4, length: 7)])
        #expect(state.applyMappedEdit(range: NSRange(location: 0, length: 0), replacement: "intro", resultingLength: 16))
        #expect(state.collapsedHeadings.isEmpty)
        #expect(state.index.regions.isEmpty)
    }

    @Test func caretAtEOFRevealsLastSection() {
        let state = session("# A\nx")
        state.collapseAll()
        #expect(state.reveal(NSRange(location: 5, length: 0)))
        #expect(state.hiddenRanges.isEmpty)
    }

    @Test func exactUTF16IdentityAndReset() {
        let state = session("# A\né")
        state.collapseAll()
        update(state, "# A\ne\u{301}")
        #expect(state.collapsedHeadings.isEmpty)
        state.collapseAll()
        state.reset()
        #expect(state.collapsedHeadings.isEmpty)
        #expect(state.hiddenRanges.isEmpty)
    }
}
