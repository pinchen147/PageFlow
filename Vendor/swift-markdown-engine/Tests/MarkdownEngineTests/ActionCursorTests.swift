import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor action cursors", .serialized)
struct ActionCursorTests {
    @Test("clickable editor controls handle the pointing-hand cursor")
    func actionCursors() throws {
        _ = NSApplication.shared
        let previous = NSCursor.current
        defer { previous.set() }
        let views: [NSView] = [
            SelectionBarButton(content: .symbol("bold"), tooltip: "Bold"),
            CommentButton(symbol: "xmark", tooltip: "Close"),
            CommentTextButton("Save", style: .primary),
            CommentReactionPill(emoji: "👍", count: 1, isMine: false),
            CommentIconChip(frame: .zero),
            CommentEmojiPicker.EmojiButton(emoji: "👍"),
            TableActionsButton(frame: .zero),
            ActionButton(title: "Save", target: nil, action: nil),
        ]
        let event = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        for view in views {
            NSCursor.arrow.set()
            view.cursorUpdate(with: event)
            #expect(NSCursor.current == NSCursor.pointingHand, "\(type(of: view))")
        }
        let selection = try #require(views[0] as? SelectionBarButton)
        let icon = try #require(views[1] as? CommentButton)
        let text = try #require(views[2] as? CommentTextButton)
        let native = try #require(views.last as? ActionButton)
        selection.isEnabled = false
        icon.isEnabled = false
        text.isEnabled = false
        native.isEnabled = false
        for view in [selection, icon, text, native] as [NSView] {
            NSCursor.pointingHand.set()
            view.cursorUpdate(with: event)
            #expect(NSCursor.current != NSCursor.pointingHand, "disabled \(type(of: view))")
        }
    }
}
