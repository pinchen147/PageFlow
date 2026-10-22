import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Comment move parking", .serialized)
struct CommentParkingTests {
    @Test("remove and insert in one turn preserves the comment; a later paste stays detached")
    func sameTurn() {
        let store = MarkdownCommentStore()
        let before = "A\n\n![alt](x.png)\n\nB" as NSString
        let range = before.range(of: "![alt](x.png)")
        let thread = MarkdownCommentThread(anchor: MarkdownCommentAnchoring.selector(for: range, in: before),
                                           root: MarkdownComment(body: "Image"))
        store.add(thread, range: range)
        store.textDidChange(MarkdownTextEdit(location: 3, removedLength: 15, insertedLength: 0), text: "A\n\nB" as NSString)
        store.textDidChange(MarkdownTextEdit(location: 4, removedLength: 0, insertedLength: 16), text: "A\n\nB\n\n![alt](x.png)\n" as NSString)
        #expect(store.ranges[thread.id] == NSRange(location: 6, length: 13))
        store.textDidChange(MarkdownTextEdit(location: 6, removedLength: 13, insertedLength: 0), text: "A\n\nB\n\n\n" as NSString)
        store.expireParkedAnchors()
        store.textDidChange(MarkdownTextEdit(location: 6, removedLength: 0, insertedLength: 13), text: "A\n\nB\n\n![alt](x.png)\n" as NSString)
        #expect(store.ranges[thread.id] == nil)
    }
    @Test("duplicate quotes within a moved block use their internal context")
    func duplicateQuotes() {
        let source = "First same\nSecond same\n\nEnd" as NSString
        let store = MarkdownCommentStore()
        let second = source.range(of: "same", options: .backwards)
        let thread = MarkdownCommentThread(anchor: MarkdownCommentAnchoring.selector(for: second, in: source),
                                           root: MarkdownComment(body: "Second occurrence"))
        store.add(thread, range: second)
        store.textDidChange(MarkdownTextEdit(location: 0, removedLength: 24, insertedLength: 0), text: "End" as NSString)
        let moved = "End\n\nFirst same\nSecond same\n" as NSString
        store.textDidChange(MarkdownTextEdit(location: 3, removedLength: 0, insertedLength: moved.length - 3), text: moved)
        #expect(store.ranges[thread.id] == moved.range(of: "same", options: .backwards))
    }

}
