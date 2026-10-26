import AppKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownClipboardTests {
    @Test
    func aDelayedCopyCannotOverwriteANewerClipboardValue() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let clipboard = MarkdownClipboard(pasteboard: pasteboard)
        try #require(pasteboard.setString("original clipboard", forType: .string))
        let requestedAt = clipboard.beginRequest()
        pasteboard.clearContents()
        try #require(pasteboard.setString("copied elsewhere afterward", forType: .string))
        clipboard.copy("late PDF export", for: requestedAt)
        #expect(pasteboard.string(forType: .string) == "copied elsewhere afterward")
        let current = clipboard.beginRequest()
        clipboard.copy("current PDF export", for: current)
        #expect(pasteboard.string(forType: .string) == "current PDF export")
    }

    @Test
    func aNewerDocumentCopyWinsEvenIfTheOlderConversionFinishesFirst() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try #require(pasteboard.setString("original clipboard", forType: .string))
        let clipboard = MarkdownClipboard(pasteboard: pasteboard)
        let fromDocumentA = clipboard.beginRequest()
        let fromDocumentB = clipboard.beginRequest()
        clipboard.copy("older result from document A", for: fromDocumentA)
        #expect(pasteboard.string(forType: .string) == "original clipboard")
        clipboard.copy("newer result from document B", for: fromDocumentB)
        #expect(pasteboard.string(forType: .string) == "newer result from document B")
    }
}
