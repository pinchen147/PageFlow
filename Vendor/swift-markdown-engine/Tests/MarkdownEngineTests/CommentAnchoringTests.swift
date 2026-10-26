import Foundation
import Testing
@testable import MarkdownEngine

/// the reference editor's comment anchors (doc 25 §3): quote selectors, re-anchoring
/// and the way anchors follow edits.
@Suite("Comment anchoring")
struct CommentAnchoringTests {

    @Test("a selector keeps 32 characters either side and the exact text")
    func selectorWindows() {
        let text = String(repeating: "a", count: 40) + "TARGET" + String(repeating: "b", count: 40) as NSString
        let made = MarkdownCommentAnchoring.anchor(for: NSRange(location: 40, length: 6), in: text)
        #expect(made.anchor.exact == "TARGET")
        #expect(made.anchor.prefix == String(repeating: "a", count: 32))
        #expect(made.anchor.suffix == String(repeating: "b", count: 32))
        #expect(made.range == NSRange(location: 40, length: 6))
        #expect(!made.clamped)
    }

    @Test("context is shorter at the note's edges")
    func selectorAtEdges() {
        let made = MarkdownCommentAnchoring.anchor(for: NSRange(location: 0, length: 5), in: "Hello world")
        #expect(made.anchor.prefix == "")
        #expect(made.anchor.suffix == " world")
    }

    @Test("a selection past 4096 characters anchors to its first 4096")
    func clampsToBudget() {
        let text = String(repeating: "x", count: 5000) as NSString
        let made = MarkdownCommentAnchoring.anchor(for: NSRange(location: 0, length: 5000), in: text)
        #expect(made.clamped)
        #expect(made.range == NSRange(location: 0, length: 4096))
        #expect((made.anchor.exact as NSString).length == 4096)
    }

    @Test("windows never split an emoji")
    func composedCharacters() {
        // 31 a's then 👍 (two UTF-16 units) puts the 32-unit window inside the emoji.
        let text = "👍" + String(repeating: "a", count: 31) + "X" as NSString
        let made = MarkdownCommentAnchoring.anchor(for: NSRange(location: 33, length: 1), in: text)
        #expect(made.anchor.prefix == String(repeating: "a", count: 31))
    }

    @Test("re-anchoring picks the repeat whose context matches, else the first")
    func resolveRepeats() {
        let text = "one apple here. two apple there." as NSString
        let second = MarkdownCommentAnchoring.selector(for: NSRange(location: 20, length: 5), in: text)
        #expect(MarkdownCommentAnchoring.resolve(second, in: text) == NSRange(location: 20, length: 5))
        let noContext = MarkdownCommentAnchor(prefix: "", exact: "apple", suffix: "")
        #expect(MarkdownCommentAnchoring.resolve(noContext, in: text) == NSRange(location: 4, length: 5))
        let gone = MarkdownCommentAnchor(prefix: "", exact: "pear", suffix: "")
        #expect(MarkdownCommentAnchoring.resolve(gone, in: text) == nil)
    }

    @Test("re-anchoring survives edits around the quote")
    func resolveAfterEdits() {
        let before = "Intro.\n\nThe quick brown fox jumps.\n" as NSString
        let anchor = MarkdownCommentAnchoring.selector(for: before.range(of: "brown fox"), in: before)
        let after = "A new first line.\n\nIntro.\n\nThe quick brown fox jumps.\n" as NSString
        #expect(MarkdownCommentAnchoring.resolve(anchor, in: after) == after.range(of: "brown fox"))
    }

    // MARK: - Following edits

    private func map(_ range: NSRange, at location: Int, removing removed: Int, inserting inserted: Int) -> NSRange? {
        MarkdownTextEdit(location: location, removedLength: removed, insertedLength: inserted).map(range)
    }

    @Test("typing at either edge does not grow the anchor")
    func edgesDoNotGrow() {
        let anchor = NSRange(location: 10, length: 5)
        #expect(map(anchor, at: 10, removing: 0, inserting: 3) == NSRange(location: 13, length: 5))
        #expect(map(anchor, at: 15, removing: 0, inserting: 3) == anchor)
    }

    @Test("typing inside grows it; edits before move it; edits after leave it")
    func insideBeforeAfter() {
        let anchor = NSRange(location: 10, length: 5)
        #expect(map(anchor, at: 12, removing: 0, inserting: 4) == NSRange(location: 10, length: 9))
        #expect(map(anchor, at: 2, removing: 3, inserting: 1) == NSRange(location: 8, length: 5))
        #expect(map(anchor, at: 20, removing: 3, inserting: 0) == anchor)
    }

    @Test("deleting part of it shrinks it; deleting all of it removes it")
    func deletions() {
        let anchor = NSRange(location: 10, length: 5)
        #expect(map(anchor, at: 8, removing: 4, inserting: 0) == NSRange(location: 8, length: 3))
        #expect(map(anchor, at: 13, removing: 5, inserting: 0) == NSRange(location: 10, length: 3))
        #expect(map(anchor, at: 10, removing: 5, inserting: 0) == nil)
        #expect(map(anchor, at: 5, removing: 20, inserting: 7) == nil)
    }

    @Test("an edit's NSTextStorage numbers become removed and inserted lengths")
    func fromTextStorage() {
        let edit = MarkdownTextEdit(editedRange: NSRange(location: 4, length: 3), changeInLength: -2)
        #expect(edit == MarkdownTextEdit(location: 4, removedLength: 5, insertedLength: 3))
        #expect(edit.swallows(NSRange(location: 5, length: 2)))
        #expect(!edit.swallows(NSRange(location: 5, length: 9)))
    }

    // MARK: - The block in the note

    private func thread(_ body: String) -> MarkdownCommentThread {
        let date = Date(timeIntervalSince1970: 1_760_400_000)
        return MarkdownCommentThread(
            anchor: MarkdownCommentAnchor(prefix: "a ", exact: "word", suffix: " b"),
            root: MarkdownComment(body: body, createdAt: date, reactions: ["👍"]),
            replies: [MarkdownComment(body: "Because.", createdAt: date, edited: true)]
        )
    }

    @Test("the block round-trips its threads and tolerates missing optional fields")
    func blockRoundTrip() throws {
        let why = thread("Why?")
        let block = MarkdownCommentBlock.block(for: [why])
        #expect(block.hasPrefix("<!-- pageflow-comments\n") && block.hasSuffix("\n-->\n"))
        #expect(MarkdownCommentBlock.threads(in: block) == [why])
        #expect(MarkdownCommentBlock.block(for: []).isEmpty)
        let minimal = """
        <!-- pageflow-comments
        {"version":1,"threads":[{"id":"t","anchor":{"prefix":"","exact":"x","suffix":""},
        "root":{"id":"c","body":"hi","createdAt":"2025-10-14T00:00:00Z"}}]}
        -->
        """
        let decoded = MarkdownCommentBlock.threads(in: minimal)
        #expect(decoded.first?.resolved == false && decoded.first?.replies.isEmpty == true)
        #expect(decoded.first?.root.reactions.isEmpty == true)
    }

    @Test("a comment that says --> cannot end the block early")
    func closerInsideAComment() {
        let block = MarkdownCommentBlock.block(for: [thread("a --> b")])
        #expect(block.components(separatedBy: "-->").count == 2, "only the block's own closer")
        #expect(MarkdownCommentBlock.threads(in: block).first?.root.body == "a --> b")
    }

    @Test("split and join give back the note: the text, then the block after a blank line")
    func splitAndJoin() {
        let block = MarkdownCommentBlock.block(for: [thread("Why?")])
        for body in ["# Plan\n\nShip it.\n", "", "Ends with a blank line\n\n", "\n"] {
            let source = MarkdownCommentBlock.join(body: body, block: block)
            let parts = MarkdownCommentBlock.split(source)
            #expect(parts.body == body && parts.block == block, "\(body.debugDescription)")
        }
        #expect(MarkdownCommentBlock.join(body: "No final break", block: block) == "No final break\n\n" + block)
        #expect(MarkdownCommentBlock.join(body: "Plain\n", block: "") == "Plain\n", "no comments: the note as it is")
        let trailing = MarkdownCommentBlock.split("Text\n\n" + block + "\n  \n")
        #expect(trailing.body == "Text\n" && MarkdownCommentBlock.threads(in: trailing.block).count == 1)
    }

    @Test("only a readable block at the very end is comments; anything else stays text")
    func notABlock() {
        let block = MarkdownCommentBlock.block(for: [thread("Why?")])
        for source in ["Text\n\n<!-- a note to self -->\n",
                       "Text\n\n" + block + "More text\n",
                       "Text\n\n<!-- pageflow-comments\nnot json\n-->\n",
                       "Text <!-- pageflow-comments\n{}\n-->\n"] {
            let parts = MarkdownCommentBlock.split(source)
            #expect(parts.body == source && parts.block.isEmpty, "\(source.debugDescription)")
        }
    }
}
