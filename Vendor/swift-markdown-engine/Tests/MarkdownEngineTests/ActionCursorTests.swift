import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Editor action cursors", .serialized)
struct ActionCursorTests {
    @Test("native text callbacks preserve drag and table action cursors", arguments: ["paragraph", "heading", "table"])
    func nativeDragCursors(_ kind: String) async throws {
        let previous = NSCursor.current
        defer { previous.set() }
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        configuration.textInsets = TextInsets(horizontal: 30, vertical: 0)
        let source = kind == "table" ? "Lead\n\n| A | B |\n| --- | --- |\n| one | two |\n\nTail"
            : (kind == "heading" ? "## Heading\n\nBody" : "Paragraph\n\nTail")
        let editor = try MountedTableEditor(source: source, configuration: configuration)
        defer { editor.close() }
        await editor.settle()
        var targets: [(NSPoint, NSCursor)] = []
        if kind == "table" {
            let chrome = try #require(editor.coordinator.tableChrome)
            let range = try #require(editor.coordinator.cachedBlockParse?.blocks.first { $0.kind == .table }).range
            let canvas = try #require(editor.main.tableCanvas(forTableAt: range))
            let geometry = try #require(editor.coordinator.tableEditingSession.geometry(forTableAt: range))
            let cell = editor.main.convertTableRect(geometry.cellRects[1][0], canvas: canvas)
            chrome.hover(at: NSPoint(x: cell.midX, y: cell.midY))
            let layout = try #require(chrome.view.layout)
            let hovered = try #require(chrome.view.hovered)
            targets = [
                (NSPoint(x: layout.handle.midX, y: layout.handle.midY), .openHand),
                (NSPoint(x: layout.columnGrip(hovered.column).midX, y: layout.columnGrip(hovered.column).midY), .openHand),
                (NSPoint(x: layout.rowGrip(hovered.row).midX, y: layout.rowGrip(hovered.row).midY), .openHand),
                (NSPoint(x: layout.addRowBar.midX, y: layout.addRowBar.midY), .pointingHand),
                (NSPoint(x: layout.columnBoundaries[1], y: layout.cells[1][0].midY), TableChromeView.columnResizeCursor)
            ]
        } else {
            let origin = editor.main.textContainerOrigin
            editor.coordinator.blockMover.hover(at: NSPoint(x: origin.x + 35, y: origin.y + 8))
            let grip = try #require(editor.coordinator.blockMover.hovered).grip
            targets = [(NSPoint(x: grip.midX, y: grip.midY), .openHand)]
        }
        for (point, expected) in targets {
            let location = editor.main.convert(point, to: nil)
            let update = try #require(NSEvent.enterExitEvent(with: .cursorUpdate, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            let root = try #require(editor.window.contentView)
            let hit = try #require(root.hitTest(root.superview?.convert(location, from: nil) ?? location))
            for recipient in [hit, editor.main] {
                NSCursor.iBeam.set()
                recipient.cursorUpdate(with: update)
                #expect(NSCursor.current == expected, "cursor update over \(kind), \(point), \(type(of: recipient))")
            }
            let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location,
                modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSCursor.iBeam.set()
            editor.main.mouseMoved(with: moved)
            #expect(NSCursor.current == expected, "native mouse movement over \(kind), \(point)")
        }
    }

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
