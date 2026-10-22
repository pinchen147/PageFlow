import AppKit

/// Disposable presentation; the session retains the only native input view.
final class MarkdownTableGridView: NSView {
    var geometry: MarkdownTableLayout
    weak var session: MarkdownTableEditingSession?

    init(geometry: MarkdownTableLayout, session: MarkdownTableEditingSession) {
        self.geometry = geometry
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: geometry.size))
        // Offscreen captures draw with dirty rects beyond the grid; without
        // clipping its fill blanked the prose around it.
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        // the reference editor draws no ring around the cell being edited; the caret marks it.
        let editedCell = session.flatMap { session in
            session.isRangeMode ? nil : CellCoord(row: session.row, column: session.column)
        }
        geometry.draw(omittingTextIn: editedCell)
        // A cell range: #2a78d6 at 10 % over each selected cell, no outline, no recolour.
        guard let selection = session?.cellSelection else { return }
        NSColor(srgbRed: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 0.10).setFill()
        for cell in selection.cells where geometry.cellRects.indices.contains(cell.row)
            && geometry.cellRects[cell.row].indices.contains(cell.column) {
            geometry.cellRects[cell.row][cell.column].fill(using: .sourceOver)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is a right-click (the reference editor opens Cell actions on it too).
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        guard let session, let hit = geometry.cell(at: convert(event.locationInWindow, from: nil)) else { return }
        let cell = CellCoord(row: hit.row, column: hit.column)
        if event.modifierFlags.contains(.shift) {
            session.extendRange(to: cell)
            return
        }
        if event.clickCount == 3 {
            session.select(row: cell.row, column: cell.column)
            session.setCellSelection(TableCellSelection(anchor: cell, head: cell))
            return
        }
        if session.row != cell.row || session.column != cell.column || session.isRangeMode {
            session.select(row: cell.row, column: cell.column)
        }
        if event.clickCount >= 2 {
            session.selectText(at: event.locationInWindow, clickCount: event.clickCount)
        } else {
            session.trackSelection(from: event)
        }
    }

    /// A right-click opens Cell actions here; the text view behind must not open its own menu too.
    override func rightMouseDown(with event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session else { return nil }
        return session.contextMenu(for: event) { session.editor.standardMenu(for: event) }
    }
}
