import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Native Markdown paste", .serialized)
struct NativePasteTests {
    private final class Source { var text = "> replace" }

    @Test("plain paste retains literal source and native undo", arguments: [
        "  indented  \r\n\n\n• literal\n", " \t\n", "[", "", "a\nb",
    ])
    func plainPaste(_ payload: String) {
        _ = NSApplication.shared
        let source = Source()
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { source.text }, set: { source.text = $0 }),
            fontName: "Helvetica", fontSize: 14, isWikiLinkActive: .constant(false),
            onLinkClick: nil, onInlineSelectionChange: nil
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NativeTextView(frame: window.contentView!.bounds)
        window.contentView = view
        view.allowsUndo = true
        view.delegate = coordinator
        coordinator.textView = view
        coordinator.rebuildTextStorageAndStyle(view, from: source.text)
        window.makeFirstResponder(view)
        defer { coordinator.textSyncGeneration &+= 1; window.close() }
        view.setSelectedRange(NSRange(location: 2, length: 7))

        let board = NSPasteboard(name: NSPasteboard.Name("PageFlowPaste-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString(payload, forType: .string)
        board.setString("<table><tr><td>different</td></tr></table>", forType: .html)
        #expect(view.paste(from: board))
        view.breakUndoCoalescing()
        #expect((view.string as NSString).isEqual(to: "> " + payload))
        // A broken source replacement can invalidate NSTextView's undo range.
        guard (view.string as NSString).isEqual(to: "> " + payload) else { return }
        view.undoManager?.undo()
        #expect(view.string == "> replace")
        view.undoManager?.redo()
        #expect((view.string as NSString).isEqual(to: "> " + payload))
    }

    @Test("native paste honors an edit veto")
    func vetoedPaste() {
        final class Veto: NSObject, NSTextViewDelegate {
            func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { false }
        }
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let veto = Veto()
        view.delegate = veto
        view.string = "source"
        view.setSelectedRange(NSRange(location: 0, length: 6))
        let board = NSPasteboard(name: NSPasteboard.Name("PageFlowPaste-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("replacement", forType: .string)
        #expect(view.paste(from: board))
        #expect(view.string == "source")
    }

    @Test("a dropped document the host opens never inserts its path")
    func droppedDocumentGoesToTheHost() {
        let view = NativeTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.string = "note"
        view.setSelectedRange(NSRange(location: 4, length: 0))
        let file = URL(fileURLWithPath: "/tmp/dropped-\(UUID().uuidString).md")
        var opened: [URL] = []
        view.opensDroppedFile = { $0.pathExtension == "md" }
        view.onDropDocuments = { urls in opened = urls; return true }
        let board = NSPasteboard(name: NSPasteboard.Name("PageFlowDrop-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([file as NSURL])
        let info = MockDraggingInfo(pasteboard: board, location: NSPoint(x: 10, y: 10), window: nil)

        #expect(view.draggingEntered(info) == .copy)
        #expect(view.performDragOperation(info))
        view.concludeDragOperation(info)
        #expect(view.string == "note")
        #expect(opened == [file])
    }
}
