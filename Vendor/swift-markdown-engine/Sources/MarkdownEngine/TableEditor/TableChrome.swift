import AppKit

/// Draws the reference editor's hover chrome for one table (doc 24 §5.3, §5.10.2):
/// grips, the table handle, the add bars, grip tints and a grip drag's dimmed
/// cells and drop bar. It sits over the hovered table's wrapper in the text
/// view and takes clicks only inside a zone; everything else falls through.
final class TableChromeView: NSView {
    weak var controller: TableChromeController?
    var layout: TableChromeLayout?
    var hovered: CellCoord?
    /// The zone under the pointer, and the one pressed or with its menu open.
    var hoveredZone: TableChromeLayout.Zone?
    var activeZone: TableChromeLayout.Zone?
    var showsAddRow = false
    var showsAddColumn = false
    /// A grip drag: what moves and the boundary it would drop on.
    var drag: (rows: Bool, index: Int, boundary: Int)?
    /// The column whose border the pointer is on, or that is being resized.
    var resizeColumn: Int?
    /// A resize in progress: the table drawn at the new width over the old one.
    var resizePreview: (image: NSImage, origin: NSPoint, covers: NSRect)?

    override var isFlipped: Bool { true }

    /// The column-resize cursor (macOS 15), else the left-right one.
    static var columnResizeCursor: NSCursor {
        if #available(macOS 15.0, *) { return .columnResize }
        return .resizeLeftRight
    }

    /// Converts a text-view rect into this view.
    private func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let layout, let hovered else { return nil }
        return layout.zone(at: point, hovered: hovered, showsAddRow: showsAddRow, showsAddColumn: showsAddColumn) != nil ? self : nil
    }

    override func resetCursorRects() {
        guard let layout, let hovered else { return }
        for zone in [TableChromeLayout.Zone.columnGrip, .rowGrip, .handle] {
            addCursorRect(local(rect(of: zone, in: layout, hovered: hovered)), cursor: .openHand)
        }
        if showsAddRow { addCursorRect(local(layout.addRowBar), cursor: .pointingHand) }
        if showsAddColumn, let bar = layout.addColumnBar { addCursorRect(local(bar), cursor: .pointingHand) }
        // the reference editor's tooltips on the grips and add bars.
        removeAllToolTips()
        var zones: [TableChromeLayout.Zone] = [.columnGrip, .rowGrip]
        if showsAddRow { zones.append(.addRow) }
        if showsAddColumn, layout.addColumnBar != nil { zones.append(.addColumn) }
        for zone in zones {
            if let help = Self.accessibilityText(for: zone)?.help {
                addToolTip(local(rect(of: zone, in: layout, hovered: hovered)), owner: help as NSString, userData: nil)
            }
        }
        // The resize band around each column's right border.
        let edges = layout.columnBoundaries
        for edge in edges.dropFirst() {
            addCursorRect(local(NSRect(x: edge - 5, y: layout.table.minY, width: 9, height: layout.table.height)), cursor: Self.columnResizeCursor)
        }
    }

    func rect(of zone: TableChromeLayout.Zone, in layout: TableChromeLayout, hovered: CellCoord) -> NSRect {
        switch zone {
        case .columnGrip: layout.columnGrip(hovered.column)
        case .rowGrip: layout.rowGrip(hovered.row)
        case .handle: layout.handle
        case .addRow: layout.addRowBar
        case .addColumn: layout.addColumnBar ?? .zero
        case .resize: resizeColumn.map { resizeLine($0, in: layout) } ?? .zero
        }
    }

    /// the reference editor's resize line: 2 pt on the column's right border, the table's height.
    func resizeLine(_ column: Int, in layout: TableChromeLayout) -> NSRect {
        let edges = layout.columnBoundaries
        guard edges.indices.contains(column + 1) else { return .zero }
        return NSRect(x: edges[column + 1] - 1.5, y: layout.table.minY - 1, width: 2, height: layout.table.height + 2)
    }

    // MARK: - Drawing

    private func color(_ dark: Bool, _ darkRGB: (CGFloat, CGFloat, CGFloat, CGFloat), _ lightRGB: (CGFloat, CGFloat, CGFloat, CGFloat)) -> NSColor {
        let value = dark ? darkRGB : lightRGB
        return NSColor(srgbRed: value.0 / 255, green: value.1 / 255, blue: value.2 / 255, alpha: value.3)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, let hovered else { return }
        let dark = ChromePalette.isDark(effectiveAppearance)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !layout.clip.isInfinite {
            // A wide table's chrome shows only over its visible span (plus the left gutter and the bands).
            let clip = layout.clip
            NSBezierPath(rect: local(NSRect(x: clip.minX - 48, y: clip.minY - 16, width: clip.width + 48 + 18, height: clip.height + 16 + 18))).addClip()
        }
        if let preview = resizePreview {
            // The table at its new width, over the old raster (it may run over the text below).
            NSColor.textBackgroundColor.setFill()
            local(preview.covers).fill()
            preview.image.draw(in: local(NSRect(origin: preview.origin, size: preview.image.size)), from: .zero,
                               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let column = resizeColumn {
            ChromePalette.accent.withAlphaComponent(0.4).setFill()
            local(resizeLine(column, in: layout)).fill()
        }
        if resizePreview != nil { return }
        drawTint(layout, hovered: hovered, dark: dark)
        drawDrag(layout, dark: dark)
        if drag == nil {
            if showsAddRow { drawAddBar(layout.addRowBar, horizontal: true, layout: layout, zone: .addRow, dark: dark) }
            if showsAddColumn, let bar = layout.addColumnBar { drawAddBar(bar, horizontal: false, layout: layout, zone: .addColumn, dark: dark) }
        }
        let gripsShown: [TableChromeLayout.Zone] = drag.map { [$0.rows ? .rowGrip : .columnGrip] } ?? [.columnGrip, .rowGrip]
        for zone in gripsShown { drawGrip(zone, layout: layout, hovered: hovered, dark: dark) }
        if drag == nil { drawHandle(layout, dark: dark) }
    }

    /// the reference editor washes the column or row whose grip is hovered.
    private func drawTint(_ layout: TableChromeLayout, hovered: CellCoord, dark: Bool) {
        guard drag == nil, let zone = activeZone ?? hoveredZone, zone == .columnGrip || zone == .rowGrip else { return }
        let header = dark ? NSColor(white: 1, alpha: 0.02) : NSColor(white: 0, alpha: 0.023)
        let body = NSColor(srgbRed: 115 / 255, green: 114 / 255, blue: 108 / 255, alpha: zone == .columnGrip ? 0.055 : 0.04)
        let cells: [(Int, Int)] = zone == .columnGrip
            ? layout.cells.indices.map { ($0, hovered.column) }
            : layout.cells[hovered.row].indices.map { (hovered.row, $0) }
        for (row, column) in cells where layout.cells[row].indices.contains(column) {
            (row == 0 ? header : body).setFill()
            local(layout.cells[row][column]).fill(using: .sourceOver)
        }
    }

    private func drawDrag(_ layout: TableChromeLayout, dark: Bool) {
        guard let drag else { return }
        // The dragged cells fade to .4 (a page-colour wash over the raster).
        NSColor.textBackgroundColor.withAlphaComponent(0.6).setFill()
        let cells = drag.rows ? layout.cells[drag.index] : layout.cells.compactMap { $0.indices.contains(drag.index) ? $0[drag.index] : nil }
        for cell in cells { local(cell).fill(using: .sourceOver) }
        // A 4 pt drop bar, accent at 50 %, on the boundary.
        let table = layout.table
        let bar: NSRect
        if drag.rows {
            let y = layout.rowBoundaries[drag.boundary]
            bar = NSRect(x: layout.visibleLeft, y: y - 2, width: layout.visibleRight - layout.visibleLeft, height: 4)
        } else {
            let x = layout.columnBoundaries[drag.boundary]
            bar = NSRect(x: x - 2, y: table.minY, width: 4, height: table.height)
        }
        ChromePalette.accent.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: local(bar), xRadius: 2, yRadius: 2).fill()
    }

    private func drawGrip(_ zone: TableChromeLayout.Zone, layout: TableChromeLayout, hovered: CellCoord, dark: Bool) {
        let box = local(rect(of: zone, in: layout, hovered: hovered))
        let active = hoveredZone == zone || activeZone == zone || drag != nil
        if active {
            color(dark, (250, 249, 245, 0.20), (31, 30, 29, 0.20)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            drawDots(in: box, columns: zone == .columnGrip ? 3 : 2, rows: zone == .columnGrip ? 2 : 3, dark: dark)
        } else {
            // At rest a 24 × 4 capsule (4 × 24 for a row) centred on the border.
            let capsule = zone == .columnGrip
                ? NSRect(x: box.midX - 12, y: box.midY - 2, width: 24, height: 4)
                : NSRect(x: box.midX - 2, y: box.midY - 12, width: 4, height: 24)
            color(dark, (250, 249, 245, 0.28), (31, 30, 29, 0.32)).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawHandle(_ layout: TableChromeLayout, dark: Bool) {
        let box = local(layout.handle)
        if hoveredZone == .handle || activeZone == .handle {
            color(dark, (0x20, 0x20, 0x1F, 1), (0xF5, 0xF4, 0xED, 1)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
        drawDots(in: box, columns: 2, rows: 3, dark: dark)
    }

    /// the reference editor's grip dots: radius 0.75 at a pitch of 4.
    private func drawDots(in box: NSRect, columns: Int, rows: Int, dark: Bool) {
        color(dark, (0x89, 0x87, 0x81, 1), (31, 30, 29, 0.55)).setFill()
        let width = CGFloat(columns - 1) * 4, height = CGFloat(rows - 1) * 4
        for column in 0..<columns {
            for row in 0..<rows {
                let center = NSPoint(x: box.midX - width / 2 + CGFloat(column) * 4, y: box.midY - height / 2 + CGFloat(row) * 4)
                NSBezierPath(ovalIn: NSRect(x: center.x - 0.75, y: center.y - 0.75, width: 1.5, height: 1.5)).fill()
            }
        }
    }

    /// An add bar: a 14 pt pill after a 4 pt gap, with a 12 pt plus in the visible middle.
    private func drawAddBar(_ bar: NSRect, horizontal: Bool, layout: TableChromeLayout, zone: TableChromeLayout.Zone, dark: Bool) {
        let pill = local(horizontal ? NSRect(x: bar.minX, y: bar.minY + 4, width: bar.width, height: 14)
                                    : NSRect(x: bar.minX + 4, y: bar.minY, width: 14, height: bar.height))
        let alpha: CGFloat = activeZone == zone ? 0.20 : hoveredZone == zone ? 0.10 : (dark ? 0.075 : 0.05)
        (dark ? NSColor(white: 1, alpha: alpha) : NSColor(white: 0, alpha: alpha)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        let plus = NSRect(x: pill.midX - 6, y: pill.midY - 6, width: 12, height: 12)
        SelectionBarButton.drawSymbol("plus", size: 12, in: plus,
                                      color: NSColor(srgbRed: 0x89 / 255, green: 0x87 / 255, blue: 0x81 / 255, alpha: 1))
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        guard let controller, let layout, let hovered, let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        guard let zone = layout.zone(at: point, hovered: hovered, showsAddRow: showsAddRow, showsAddColumn: showsAddColumn) else { return }
        switch zone {
        case .columnGrip, .rowGrip: controller.pressGrip(zone, event: event)
        case .handle: controller.pressHandle(event)
        case .addRow, .addColumn:
            activeZone = zone
            needsDisplay = true
            controller.clickAddBar(zone, at: point)
        case .resize:
            if let column = layout.resizeColumn(at: point) { controller.pressResize(column: column, event: event) }
        }
    }
}

/// the reference editor's hover machine for tables (doc 24 §5.7.4, §7.4.1): one
/// tracking area on the editor's scroll view, an index of the visible tables
/// rebuilt only after a scroll or an edit, and binary-search hit tests, so a
/// pointer move never edits the text or lays anything out.
final class TableChromeController: NSResponder, NSDraggingSource {
    /// The pasteboard type of a table handle drag: the table's source location.
    static let tableMoveType = NSPasteboard.PasteboardType("com.pageflow.table-move")
    private weak var coordinator: NativeTextViewCoordinator?
    private weak var scrollView: NSScrollView?
    let view = TableChromeView()
    /// Holds the chrome over the text view and its wide tables, in the text view's coordinates.
    let host = PassThroughView()
    private let trackedOverlays = NSHashTable<WideTableOverlay>.weakObjects()

    private struct Entry {
        let range: NSRange
        let layout: TableChromeLayout
        /// Where the table's raster is anchored in the text.
        let anchor: Int
    }
    /// The visible tables, top to bottom; nil until the next hover rebuilds it.
    private var entries: [Entry]?
    /// The viewport `entries` was built for.
    private var entriesViewport: NSRange?
    private(set) var table: NSRange?
    private var tableAnchor: Int?
    private var tracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []
    private var pressing = false
    private(set) var gripMenu: TableMenuView?
    private var gripMenuZone: TableChromeLayout.Zone?

    init(coordinator: NativeTextViewCoordinator, scrollView: NSScrollView) {
        self.coordinator = coordinator
        self.scrollView = scrollView
        super.init()
        view.controller = self
        view.isHidden = true
        coordinator.textView?.addSubview(view, positioned: .above, relativeTo: nil)
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        scrollView.addTrackingArea(area)
        tracking = area
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.contentDidScroll() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func uninstall() {
        gripMenu?.close(.dismissed)
        if let tracking { scrollView?.removeTrackingArea(tracking) }
        view.removeFromSuperview()
        host.removeFromSuperview()
    }

    private var main: NativeTextView? { coordinator?.textView as? NativeTextView }

    // MARK: - Index

    /// The text, its layout or a wide table's scroll changed: rebuild on the next hover.
    func invalidate() {
        entries = nil
        trackWideTables()
        guard !pressing, gripMenu == nil else { return }
        // Re-place from the same pointer once the change has laid out (the reference editor re-measures the cell).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.hoverAtMouse() }
        }
    }

    /// A wide table is a scroll view of its own: the pointer over it reports
    /// to the chrome through a tracking area on it too.
    private func trackWideTables() {
        guard let main else { return }
        for overlay in main.wideTableOverlays.values where !trackedOverlays.contains(overlay) {
            overlay.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                                   owner: self, userInfo: nil))
            trackedOverlays.add(overlay)
        }
    }

    private func contentDidScroll() {
        entries = nil
        trackWideTables()
        // A scroll the bars did not cause hides them.
        view.showsAddRow = false
        view.showsAddColumn = false
        hoverAtMouse()
    }

    private func buildEntries() -> [Entry] {
        guard let main, let storage = main.textStorage, let viewport = main.viewportCharacterRange else { return [] }
        let scope = NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))
        var result: [Entry] = []
        var seen = Set<Int>()
        storage.enumerateAttribute(.markdownTableSourceRange, in: scope) { value, attributeRange, _ in
            guard let value = value as? NSValue else { return }
            let range = AnchorRelativeRange.decode(value, anchorLocation: attributeRange.location)
            guard seen.insert(range.location).inserted, let layout = chromeLayout(for: range, anchor: attributeRange.location) else { return }
            result.append(Entry(range: range, layout: layout, anchor: attributeRange.location))
        }
        return result.sorted { $0.layout.table.minY < $1.layout.table.minY }
    }

    /// The table's cells in text-view coordinates, from the layout its image was drawn with.
    private func chromeLayout(for range: NSRange, anchor: Int) -> TableChromeLayout? {
        guard let main, let coordinator, let canvas = main.tableCanvas(forTableAt: range) else { return nil }
        let session = coordinator.tableEditingSession
        let geometry: MarkdownTableLayout?
        if session.owns(range), let grid = session.grid {
            geometry = grid.geometry
        } else if let image = main.textStorage?.attribute(.renderedBlockImage, at: anchor, effectiveRange: nil) as? NSImage {
            geometry = MarkdownTableLayout.layout(ofRaster: image) ?? session.geometry(forTableAt: range)
        } else {
            geometry = session.geometry(forTableAt: range)
        }
        guard let geometry else { return nil }
        let cells = geometry.cellRects.map { row in row.map { main.convertTableRect($0, canvas: canvas) } }
        var clip = NSRect.infinite
        if canvas.view !== main, let overlay = canvas.view.enclosingScrollView {
            clip = overlay.contentView.convert(overlay.contentView.bounds, to: main)
        }
        return TableChromeLayout(cells: cells, clip: clip)
    }

    // MARK: - Hover

    override func mouseMoved(with event: NSEvent) {
        guard let main else { return }
        hover(at: main.convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard !pressing, gripMenu == nil else { return }
        remove()
    }

    private func hoverAtMouse() {
        guard let main, let window = main.window else { return }
        let point = main.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard main.visibleRect.contains(point) else { return }
        hover(at: point)
    }

    /// the reference editor's hover machine: a cell shows its table's chrome in the same
    /// frame; the gutter and bands keep it; anywhere else removes it.
    func hover(at point: NSPoint) {
        guard !pressing, gripMenu == nil, let main, main.isEditable else { return }
        if let layout = view.layout, let hovered = view.hovered, !view.isHidden,
           layout.zone(at: point, hovered: hovered, showsAddRow: view.showsAddRow, showsAddColumn: view.showsAddColumn) != nil {
            setHoveredZone(at: point)
            return
        }
        // The index belongs to one laid-out viewport: a scroll can land before
        // TextKit lays the new band out, so a later viewport rebuilds it.
        let viewport = main.viewportCharacterRange
        if entries == nil || viewport != entriesViewport {
            entries = buildEntries()
            entriesViewport = viewport
        }
        if let entry = entries?.first(where: { $0.layout.table.contains(point) }), let cell = entry.layout.cell(at: point) {
            if entry.range != table || cell != view.hovered || view.isHidden { place(entry, cell: cell) }
            setHoveredZone(at: point)
            return
        }
        if let layout = view.layout, !view.isHidden, layout.wrapper.contains(point) {
            setHoveredZone(at: point)
            return
        }
        remove()
    }

    private func place(_ entry: Entry, cell: CellCoord) {
        table = entry.range
        tableAnchor = entry.anchor
        let layout = entry.layout
        view.layout = layout
        view.hovered = cell
        let last = layout.cells.count - 1
        let lastColumn = (layout.cells.first?.count ?? 1) - 1
        let buttonUp = NSEvent.pressedMouseButtons & 1 == 0
        view.showsAddRow = cell.row == last && buttonUp
        view.showsAddColumn = cell.column == lastColumn && buttonUp && layout.addColumnBar != nil
        let frame = layout.wrapper.union(layout.handle).union(layout.addColumnBar ?? layout.wrapper).integral
        if view.frame != frame { view.frame = frame }
        // Grids and wide-table overlays mount later: the chrome stays on top of
        // them. A page-look wide table is the text view's sibling, so the chrome
        // lives in a pass-through host over the text view (same coordinates).
        if let main, let container = main.superview as? NativeTextViewContainer {
            container.keepAboveWideTables(host)
            if host.frame != main.frame { host.frame = main.frame }
            if view.superview !== host { host.addSubview(view) }
        } else if let main, main.subviews.last !== view {
            main.addSubview(view, positioned: .above, relativeTo: nil)
        }
        view.isHidden = false
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
        coordinator?.tableActions?.hoveredTable = entry.range
    }

    private func setHoveredZone(at point: NSPoint) {
        guard let layout = view.layout, let hovered = view.hovered else { return }
        let zone = layout.zone(at: point, hovered: hovered, showsAddRow: view.showsAddRow, showsAddColumn: view.showsAddColumn)
        let resize = zone == .resize ? layout.resizeColumn(at: point) : nil
        if resize != view.resizeColumn {
            view.resizeColumn = resize
            view.needsDisplay = true
        }
        // Hovering one add bar hides the other.
        if zone == .addRow, view.showsAddColumn { view.showsAddColumn = false; view.needsDisplay = true }
        if zone == .addColumn, view.showsAddRow { view.showsAddRow = false; view.needsDisplay = true }
        if zone != view.hoveredZone {
            view.hoveredZone = zone
            view.needsDisplay = true
        }
    }

    func remove() {
        guard !view.isHidden || table != nil else { return }
        view.isHidden = true
        view.hovered = nil
        view.hoveredZone = nil
        view.activeZone = nil
        view.drag = nil
        table = nil
        coordinator?.tableActions?.hoveredTable = nil
    }

    // MARK: - Actions

    /// Put the cell editor on the hovered cell of the hovered table.
    @discardableResult
    private func focusHoveredCell() -> MarkdownTableEditingSession? {
        guard let coordinator, let table, let hovered = view.hovered else { return nil }
        let session = coordinator.tableEditingSession
        if !session.owns(table) {
            guard session.begin(range: table, row: hovered.row, column: hovered.column, selecting: .end) else { return nil }
        }
        return session
    }

    /// A grip press: a click (≤ 5 pt) selects the column or row and opens its
    /// menu; a drag moves it to the nearest boundary (doc 24 §5.7.5).
    /// `nextEvent` replaces the window's event queue in tests.
    func pressGrip(_ zone: TableChromeLayout.Zone, event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) {
        guard let layout = view.layout, let hovered = view.hovered, let window = view.window, let main else { return }
        let rows = zone == .rowGrip
        let index = rows ? hovered.row : hovered.column
        pressing = true
        view.activeZone = zone
        view.needsDisplay = true
        defer {
            pressing = false
            view.drag = nil
            view.activeZone = gripMenuZone
            view.needsDisplay = true
            NSCursor.pop()
        }
        NSCursor.closedHand.push()
        let start = event.locationInWindow
        var dragging = false
        var refused = false
        var boundary = 0
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) }
        while let next = events() {
            if next.type == .keyDown {
                if next.keyCode == 53 { dragging = false; refused = true }   // Escape cancels the drag
                continue
            }
            if next.type == .leftMouseUp { break }
            guard !refused else { continue }
            if !dragging, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 5 {
                if rows, index == 0 {
                    // PageFlow refuses at once what the reference editor only refuses later.
                    MarkdownTableEditingSession.announce("Header rows stay at the top.")
                    refused = true
                    continue
                }
                dragging = true
                gripMenu?.close(.dismissed)
                coordinator?.tableEditingSession.setCellSelection(nil)
            }
            guard dragging else { continue }
            let point = main.convert(next.locationInWindow, from: nil)
            boundary = layout.nearestBoundary(to: rows ? point.y : point.x, rows: rows)
            view.drag = (rows, index, boundary)
            view.needsDisplay = true
        }
        if dragging {
            drop(rows: rows, index: index, boundary: boundary)
        } else if !refused {
            clickGrip(zone, index: index)
        }
    }

    func drop(rows: Bool, index: Int, boundary: Int) {
        guard let session = focusHoveredCell(), let source = session.table else { return }
        let text = rows ? MarkdownTableEditPlan.movingRow(index, to: boundary, in: source)
                        : MarkdownTableEditPlan.movingColumn(index, to: boundary, in: source)
        // A drop on its own boundaries changes nothing and adds no Undo step.
        guard let text, session.rewriteTable(text, actionName: rows ? "Move Row" : "Move Column",
                                             columns: rows ? nil : { $0.moveColumn(index, to: boundary) }) != nil else { return }
        let moved = boundary > index ? boundary - 1 : boundary
        session.select(row: rows ? moved : session.row, column: rows ? session.column : moved)
        session.remount()
        remove()
    }

    func clickGrip(_ zone: TableChromeLayout.Zone, index: Int) {
        if let menu = gripMenu {
            // The same grip again closes its menu and keeps the range.
            let same = gripMenuZone == zone
            menu.close(.dismissed)
            if same { return }
        }
        guard let session = focusHoveredCell(), let table = session.table, let hovered = view.hovered,
              let layout = view.layout, let scrollView, let main else { return }
        let rows = zone == .rowGrip
        let range = rows
            ? TableCellSelection(anchor: CellCoord(row: index, column: 0), head: CellCoord(row: index, column: table.columnCount - 1))
            : TableCellSelection(anchor: CellCoord(row: 0, column: index), head: CellCoord(row: table.rowCount - 1, column: index))
        session.setCellSelection(range)
        let cell = TableCellSelection(anchor: hovered, head: hovered)
        typealias Item = TableMenuView.Item
        let items: [Item] = rows ? [
            Item("Insert row above", symbol: "arrow.up.to.line", disabledReason: hovered.row == 0 ? "Header rows stay at the top." : nil) { [weak session] in
                session?.insertAround(cell, edit: .insertRow(below: false), announce: nil)
            },
            Item("Insert row below", symbol: "arrow.down.to.line") { [weak session] in
                session?.insertAround(cell, edit: .insertRow(below: true), announce: nil)
            },
            Item("Delete row", symbol: "xmark.rectangle") { [weak session] in session?.deleteRows(of: cell, announce: false) },
        ] : [
            Item("Insert column left", symbol: "arrow.left.to.line") { [weak session] in
                session?.insertAround(cell, edit: .insertColumn(right: false), announce: nil)
            },
            Item("Insert column right", symbol: "arrow.right.to.line") { [weak session] in
                session?.insertAround(cell, edit: .insertColumn(right: true), announce: nil)
            },
            Item("Delete column", symbol: "xmark.rectangle.portrait") { [weak session] in session?.deleteColumns(of: cell, announce: false) },
        ]
        let grip = scrollView.convert(view.rect(of: zone, in: layout, hovered: hovered), from: main)
        let anchor = scrollView.isFlipped ? grip : NSRect(x: grip.minX, y: scrollView.bounds.height - grip.maxY, width: grip.width, height: grip.height)
        gripMenuZone = zone
        view.activeZone = zone
        gripMenu = TableMenuView.present(items, family: .float, label: rows ? "Row actions" : "Column actions", minimumWidth: 188,
                                         placement: .below(anchor, rightAligned: false), in: scrollView, fromKeyboard: false,
                                         returningFocusTo: session.editor) { [weak self] _ in
            guard let self else { return }
            self.gripMenu = nil
            self.gripMenuZone = nil
            self.view.activeZone = nil
            self.view.needsDisplay = true
        }
    }

    /// The handle: a click selects every cell; a drag past the slop moves the
    /// table's source block (doc 24 §5.7.6).
    func pressHandle(_ event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) {
        guard let window = view.window else { return }
        let start = event.locationInWindow
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        while let next = events() {
            if next.type == .leftMouseUp { break }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                beginTableDrag(with: next)
                return
            }
        }
        clickHandle()
    }

    private func beginTableDrag(with event: NSEvent) {
        guard let table, let main, let layout = view.layout else { return }
        let session = coordinator?.tableEditingSession
        if session?.owns(table) == true, session?.isRangeMode == true { session?.setCellSelection(nil) }
        let item = NSPasteboardItem()
        item.setString(String(table.location), forType: Self.tableMoveType)
        let text = main.string as NSString
        if NSMaxRange(table) <= text.length { item.setString(text.substring(with: table), forType: .string) }
        let image = tableAnchor.flatMap { main.textStorage?.attribute(.renderedBlockImage, at: $0, effectiveRange: nil) as? NSImage }
            ?? NSImage(size: layout.table.size)
        let pointer = view.convert(event.locationInWindow, from: nil)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // the reference editor holds the snapshot 24 pt in from its top-left corner.
        dragging.setDraggingFrame(NSRect(x: pointer.x - 24, y: pointer.y - 24, width: image.size.width, height: image.size.height), contents: image)
        view.beginDraggingSession(with: [dragging], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        main?.hideTableDropIndicator()
        remove()
    }

    // MARK: - Column resize (doc 24 §5.7.7, §7.4.5)

    /// A drag on a column's right border: the column follows the pointer
    /// (48…4000 pt), previewed without touching the text, and the width is
    /// kept view-only on release as one Undo step. A wide table scrolls with
    /// the reference editor's ramp near its edges.
    func pressResize(column: Int, event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) {
        guard let table, let layout = view.layout, let coordinator, let main, let window = view.window,
              let key = coordinator.tableKey(forTableAt: table), NSMaxRange(table) <= (main.string as NSString).length,
              let model = MarkdownTableModel.parse((main.string as NSString).substring(with: table)) else { return }
        let stored = coordinator.columnWidths(forTableAt: table)
        let columns = layout.cells.first?.count ?? 0
        var widths: [CGFloat?] = (0..<columns).map { $0 < stored.count ? stored[$0] : nil }
        let header = layout.cells[0]
        let startWidth = widths[column] ?? (header[column].width + 1)
        let start = event.locationInWindow.x
        let parsed = MarkdownStyler.parsedTable(from: model)
        let cache = MarkdownTableLayout.CellCache()
        let configuration = coordinator.configuration
        let overlay = main.tableCanvas(forTableAt: table).flatMap { $0.view === main ? nil : $0.view.enclosingScrollView as? WideTableOverlay }
        pressing = true
        view.resizeColumn = column
        TableChromeView.columnResizeCursor.push()
        defer {
            pressing = false
            view.resizePreview = nil
            view.needsDisplay = true
            NSCursor.pop()
        }
        var scrolled: CGFloat = 0
        var last = event
        func preview() {
            let dx = last.locationInWindow.x - start + scrolled
            widths[column] = min(MarkdownTableLayout.maximumSetColumnWidth, max(MarkdownTableLayout.minimumColumnWidth, startWidth + dx))
            let image = MarkdownTableLayout(table: parsed, font: coordinator.baseFontAndStyle().0, theme: configuration.theme,
                                            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
                                            latex: configuration.services.latex, appearance: main.effectiveAppearance,
                                            cache: cache, columnWidths: widths).image()
            let origin = NSPoint(x: header[0].minX - 1, y: layout.table.minY - 1)
            view.resizePreview = (image, origin, layout.table.insetBy(dx: -1, dy: -1))
            let grown = NSRect(origin: origin, size: image.size).union(view.frame)
            if !view.frame.contains(grown) { view.frame = grown.integral }
            view.needsDisplay = true
        }
        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 1.0 / 60)
        defer { NSEvent.stopPeriodicEvents() }
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) }
        while let next = events() {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { last = next; preview(); continue }
            guard next.type == .periodic, let overlay else { continue }
            // Near a wide table's edges: step = round(2 + 14 · min(1, overshoot / 24)), armed after 8 pt.
            let x = main.convert(last.locationInWindow, from: nil).x
            let clip = layout.clip
            let right = clip.maxX - 16, left = clip.minX + 16
            let dx = last.locationInWindow.x - start
            var step: CGFloat = 0
            if x >= right, dx >= 8 { step = (2 + 14 * min(1, (x - right) / 24)).rounded() }
            if x <= left, dx <= -8, overlay.horizontalOffset > 0 { step = -(2 + 14 * min(1, (left - x) / 24)).rounded() }
            guard step != 0 else { continue }
            let before = overlay.horizontalOffset
            overlay.horizontalOffset = before + step
            scrolled += overlay.horizontalOffset - before
            preview()
        }
        guard let width = widths[column], abs(width - startWidth) >= 0.5 else { return }
        coordinator.tableEditingSession.applyColumnWidths(widths, key: key, tableLocation: table.location, actionName: "Column Width")
        remove()
    }

    /// The handle selects every cell.
    func clickHandle() {
        guard let session = focusHoveredCell(), let table = session.table else { return }
        session.setCellSelection(TableCellSelection(anchor: CellCoord(row: 0, column: 0),
                                                    head: CellCoord(row: table.rowCount - 1, column: table.columnCount - 1)))
    }

    /// An add bar appends a row or column; the caret starts the new cell under the pointer.
    func clickAddBar(_ zone: TableChromeLayout.Zone, at point: NSPoint) {
        guard let layout = view.layout, let session = focusHoveredCell(), let table = session.table else { return }
        if zone == .addRow {
            let column = layout.cells.first?.firstIndex { point.x < $0.maxX } ?? table.columnCount - 1
            session.select(row: table.rowCount - 1, column: min(column, table.columnCount - 1))
            session.perform(.insertRow(below: true))
        } else {
            let row = layout.cells.firstIndex { point.y < ($0.first?.maxY ?? 0) } ?? table.rowCount - 1
            session.select(row: min(row, table.rowCount - 1), column: table.columnCount - 1)
            session.perform(.insertColumn(right: true))
        }
        session.place(.start)
        view.activeZone = nil
        view.needsDisplay = true
    }
}

/// A transparent view that only its subviews' zones hit.
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
