import AppKit

/// Disposable presentation; the session retains the only native input view.
final class MarkdownTableGridView: NSView {
    let tableAccessibilityRows = TableAccessibilityRows()
    var geometry: MarkdownTableLayout
    weak var session: MarkdownTableEditingSession?
    weak var semanticSession: NativeSemanticTableSession?

    init(geometry: MarkdownTableLayout, session: MarkdownTableEditingSession) {
        self.geometry = geometry
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: geometry.size))
        // Offscreen captures draw with dirty rects beyond the grid; without
        // clipping its fill blanked the prose around it.
        clipsToBounds = true
    }
    init(geometry: MarkdownTableLayout, semanticSession: NativeSemanticTableSession) {
        self.geometry = geometry
        self.semanticSession = semanticSession
        super.init(frame: NSRect(origin: .zero, size: geometry.size))
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { semanticSession != nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, semanticSession?.handleRangeKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if semanticSession?.handleRangeKey(event) == true { return }
        super.keyDown(with: event)
    }

    /// The cell whose text the editor shows instead of the grid.
    private var editedCell: CellCoord? {
        if let semanticSession { return semanticSession.editedCoordinate }
        return session.flatMap { session in
            session.isRangeMode ? nil : CellCoord(row: session.row, column: session.column)
        }
    }
    private var drawnEditedCell: CellCoord?

    /// Adopts `newGeometry` and marks for display only what changes: a
    /// keystroke redraws the cells whose text it changed, not the whole grid.
    func show(_ newGeometry: MarkdownTableLayout) {
        let old = geometry
        geometry = newGeometry
        var dirty = Self.invalidation(from: old, to: newGeometry)
        if drawnEditedCell != editedCell {
            for cell in [drawnEditedCell, editedCell].compactMap({ $0 }) {
                if let rect = old.rect(of: cell) { dirty = dirty?.union(rect) ?? rect }
            }
        }
        if let dirty { setNeedsDisplay(dirty) }
    }

    /// What differs between two layouts of the grid: the boxes of the cells
    /// whose text changed, or all of it when any geometry or colour did. Nil
    /// when nothing would draw differently.
    static func invalidation(from old: MarkdownTableLayout, to new: MarkdownTableLayout) -> NSRect? {
        let whole = NSRect(origin: .zero, size: NSSize(width: max(old.size.width, new.size.width),
                                                       height: max(old.size.height, new.size.height)))
        guard old.size == new.size, old.cellRects == new.cellRects, old.alignments == new.alignments,
              old.cells.count == new.cells.count, old.border == new.border, old.headerFill == new.headerFill,
              old.appearance.name == new.appearance.name else { return whole }
        var dirty: NSRect?
        for (row, (before, after)) in zip(old.cells, new.cells).enumerated() {
            guard before.count == after.count else { return whole }
            for (column, (a, b)) in zip(before, after).enumerated() where a !== b && !a.isEqual(to: b) {
                guard let rect = new.rect(of: CellCoord(row: row, column: column)) else { return whole }
                dirty = dirty?.union(rect) ?? rect
            }
        }
        return dirty
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        // the reference editor draws no ring around the cell being edited; the caret marks it.
        let editedCell = editedCell
        drawnEditedCell = editedCell
        geometry.draw(omittingTextIn: editedCell)
        // A cell range: #2a78d6 at 10 % over each selected cell, no outline, no recolour.
        guard let selection = semanticSession?.cellSelection ?? session?.cellSelection else { return }
        NSColor(srgbRed: 0x2A / 255, green: 0x78 / 255, blue: 0xD6 / 255, alpha: 0.10).setFill()
        for cell in selection.cells where geometry.cellRects.indices.contains(cell.row)
            && geometry.cellRects[cell.row].indices.contains(cell.column) {
            geometry.cellRects[cell.row][cell.column].fill(using: .sourceOver)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    /// The chrome's cursor on its zones (a column border), a pointing hand
    /// over a link's text in a cell, the I-beam elsewhere (as the text view).
    override func mouseMoved(with event: NSEvent) {
        if let semanticSession {
            if semanticSession.resizeColumn(at: convert(event.locationInWindow, from: nil)) != nil {
                TableChromeView.columnResizeCursor.set()
            } else { NSCursor.iBeam.set() }
            return
        }
        guard let coordinator = session?.coordinator,
              let hit = frontmostCursorHit(for: event) else { return }
        if hit === coordinator.tableChrome?.view {
            _ = coordinator.tableChrome?.applyCursor(for: event)
            return
        }
        guard ownsTextCursorHit(hit) else { return }
        if coordinator.tableChrome?.applyCursor(for: event) != true, !coordinator.applyTableLinkCursor(for: event) {
            NSCursor.iBeam.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // ⌃-click is a right-click (the reference editor opens Cell actions on it too).
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        if let semanticSession, let column = semanticSession.resizeColumn(at: convert(event.locationInWindow, from: nil)) {
            semanticSession.trackColumnResize(event, column: column)
            return
        }
        if let semanticSession, let hit = geometry.cell(at: convert(event.locationInWindow, from: nil)) {
            semanticSession.select(row: hit.row, column: hit.column, extending: event.modifierFlags.contains(.shift))
            return
        }
        guard let session, let hit = geometry.cell(at: convert(event.locationInWindow, from: nil)) else { return }
        // ⌘-click on a cell's link opens it; a plain click edits the cell.
        if session.coordinator?.openTableLink(for: event, editable: true) == true { return }
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
        if let semanticSession { semanticSession.showCellActions(event); return nil }
        guard let session else { return nil }
        return session.contextMenu(for: event) { session.editor.standardMenu(for: event) }
    }
}
