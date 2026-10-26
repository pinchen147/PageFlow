import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor final class TableEditorState {
    var text: String
    init(_ text: String) { self.text = text }
    let controller = MarkdownEditorController()
    let undo = UndoManager()
}

/// A real wrapper, coordinator and window around one Markdown source.
@MainActor final class MountedTableEditor {
    let state: TableEditorState
    var wrapper: NativeTextViewWrapper
    let coordinator: NativeTextViewCoordinator
    let scroll: NSScrollView
    let window: NSWindow
    let main: NativeTextView

    init(source: String, configuration: MarkdownEditorConfiguration = .default) throws {
        _ = NSApplication.shared
        let state = TableEditorState(source)
        state.undo.groupsByEvent = false
        self.state = state
        wrapper = NativeTextViewWrapper(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            configuration: configuration,
            fontSize: 16,
            documentId: UUID().uuidString,
            editorController: state.controller,
            forcedAppearanceName: .aqua,
            undoManager: state.undo
        )
        coordinator = wrapper.makeCoordinator()
        scroll = wrapper.makeNativeView(coordinator: coordinator)
        main = try #require(scroll.nativeTextView)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // A close animation can finish on a display-link callback while another
        // async test is suspended; its run-loop stop would end the test host.
        window.animationBehavior = .none
        window.contentView = scroll
        window.orderBack(nil)
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.makeFirstResponder(main)
        main.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func close() {
        NativeTextViewWrapper.dismantleNSView(scroll, coordinator: coordinator)
        window.close()
    }

    func settle() async {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            main.textLayoutManager?.textViewportLayoutController.layoutViewport()
            main.displayIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // Deliver an actual mouse event through the native hit target. The
    // fixture's only body row is at the image's bottom, independent of
    // header wrapping and measured column widths.
    func clickBodyCell(lastColumn: Bool = false) async throws -> NSTextView {
        await settle()
        let overlay = try #require(main.wideTableOverlays.values.min {
            $0.anchorTextLocation < $1.anchorTextLocation
        })
        let canvas = try #require(overlay.documentView)
        let storage = try #require(main.textStorage)
        let image = try #require(storage.attribute(
            .renderedBlockImage, at: overlay.anchorTextLocation, effectiveRange: nil
        ) as? NSImage)
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try #require(pixels.width > 0 && pixels.height > 0)
        try #require(canvas.bounds.width > 20 && canvas.bounds.height > 20)
        let point = NSPoint(
            x: lastColumn ? canvas.bounds.maxX - 10 : canvas.bounds.minX + 10,
            y: canvas.isFlipped ? canvas.bounds.maxY - 10 : canvas.bounds.minY + 10
        )
        canvas.scrollToVisible(NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        let windowPoint = canvas.convert(point, to: nil)
        let root = try #require(window.contentView)
        let hit = try #require(root.hitTest(root.superview?.convert(windowPoint, from: nil) ?? windowPoint))
        try #require(hit !== main, "The rendered grid must receive the click before checking editing behavior")
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        hit.mouseDown(with: event)
        let cell = try #require(window.firstResponder as? NSTextView)
        try #require(cell !== main, "Clicking a rendered cell must focus its native editor instead of unfolding table source")
        try #require(cell.isDescendant(of: scroll), "The cell editor must remain in the document's native hierarchy")
        return cell
    }

    func replaceCell(_ cell: NSTextView, with text: String) {
        cell.setSelectedRange(NSRange(location: 0, length: (cell.string as NSString).length))
        cell.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

extension MountedTableEditor {
    /// Focus a cell through the session's own geometry. Hit testing from real
    /// clicks has its own tests; command tests start from a known cell.
    func focusCell(inTableContaining marker: String, row: Int, column: Int) throws -> NSTextView {
        let location = (main.string as NSString).range(of: marker).location
        let token = try #require(coordinator.parsedDocument(for: main.string).tokens.first {
            $0.kind == .table && NSLocationInRange(location, $0.range)
        })
        let session = coordinator.tableEditingSession
        let table = try #require(MarkdownTableSource(source: main.string, range: token.range))
        let rect = try #require(session.geometry(for: table)?.cellRects[row][column])
        try #require(session.begin(range: token.range, point: NSPoint(x: rect.midX, y: rect.midY), in: main))
        try #require(window.firstResponder === session.editor)
        return session.editor
    }

    /// Route a real mouse-down at a view point through the editor's table
    /// handling (the part of `mouseDown` that runs before text selection).
    @discardableResult
    func routeClick(at point: NSPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> Bool {
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: main.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 77, clickCount: clickCount, pressure: 1
        ))
        return main.routeMouseDownToTables(event)
    }

    /// The view point at the middle of a narrow table's rendered cell.
    func renderedCellPoint(inTableContaining marker: String, row: Int, column: Int) throws -> NSPoint {
        let anchor = (main.string as NSString).range(of: marker).location
        let token = try #require(coordinator.parsedDocument(for: main.string).tokens.first {
            $0.kind == .table && NSLocationInRange(anchor, $0.range)
        })
        let canvas = try #require(main.tableCanvas(forTableAt: token.range))
        let table = try #require(MarkdownTableSource(source: main.string, range: token.range))
        let cell = try #require(coordinator.tableEditingSession.geometry(for: table)?.cellRects[row][column])
        return NSPoint(x: canvas.origin.x + cell.midX, y: canvas.origin.y + cell.midY)
    }

    /// A view point inside the character at `location`.
    func point(atSourceLocation location: Int) throws -> NSPoint {
        let bridge = try #require(main.layoutBridge)
        let container = try #require(bridge.firstTextContainer)
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: location, length: 1), in: container)
        return NSPoint(x: main.textContainerOrigin.x + rect.minX + 1, y: main.textContainerOrigin.y + rect.midY)
    }
}

extension MountedTableEditor {
    /// Click a narrow table's rendered cell the way a user does: through the
    /// image's own anchor payload and drawn rect, not a fresh parse.
    func clickRenderedCell(inTableContaining marker: String, row: Int, column: Int) throws -> NSTextView {
        let anchor = (main.string as NSString).range(of: marker).location
        let storage = try #require(main.textStorage)
        let image = try #require(storage.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage)
        let bridge = try #require(main.layoutBridge)
        let container = try #require(bridge.firstTextContainer)
        let anchorRect = bridge.boundingRect(forCharacterRange: NSRange(location: anchor, length: 1), in: container)
        let origin = NSPoint(x: main.textContainerOrigin.x + anchorRect.minX,
                             y: main.textContainerOrigin.y + anchorRect.midY - image.size.height / 2)
        let token = try #require(coordinator.parsedDocument(for: main.string).tokens.first {
            $0.kind == .table && NSLocationInRange(anchor, $0.range)
        })
        let table = try #require(MarkdownTableSource(source: main.string, range: token.range))
        let cell = try #require(coordinator.tableEditingSession.geometry(for: table)?.cellRects[row][column])
        try #require(try routeClick(at: NSPoint(x: origin.x + cell.midX, y: origin.y + cell.midY)))
        return try #require(window.firstResponder as? NSTextView)
    }
}
