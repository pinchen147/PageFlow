import AppKit

/// the reference editor's table accessibility (doc 24 §5.11): the grid is an AXTable of
/// cells with header flags and indices, every chrome control is a button with
/// the reference editor's label and help, and AXPress always performs it (deviation c).

/// An accessibility element whose press runs a closure.
final class TableAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Bool)?
    override func accessibilityPerformPress() -> Bool { press?() ?? false }
}

// MARK: - Grid

extension MarkdownTableGridView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityLabel() -> String? { "Table" }
    override func accessibilityRowCount() -> Int { geometry.cellRects.count }
    override func accessibilityColumnCount() -> Int { geometry.cellRects.first?.count ?? 0 }

    /// Rows of cells, built when asked so they always match the grid.
    override func accessibilityChildren() -> [Any]? { accessibilityRows() }
    override func accessibilityRows() -> [Any]? {
        let window = self.window
        let selection = session?.cellSelection
        return tableAccessibilityRows.update(geometry, parent: self,
                                      screen: { window?.convertToScreen(self.convert($0, to: nil)) ?? $0 },
                                      isSelected: { selection?.contains($0) ?? false })
    }

    override func accessibilityColumnHeaderUIElements() -> [Any]? {
        (accessibilityRows()?.first as? NSAccessibilityElement)?.accessibilityChildren()
    }

    /// A cell range is exposed as the selected cells (no announcement, as in the reference editor).
    override func accessibilitySelectedCells() -> [Any]? {
        guard session?.cellSelection != nil else { return [] }
        return accessibilityRows()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityChildren() }
            .flatMap { $0 }.filter { ($0 as? NSAccessibilityElement)?.isAccessibilitySelected() == true }
    }
}

/// AppKit gives accessibility clients remote references. Each table owns its
/// virtual rows and cells so those references survive the query that returned them.
final class TableAccessibilityRows {
    private var rows: [NSAccessibilityElement] = []

    /// AXRow elements of AXCell elements (text, header label, indices,
    /// selection, screen frame) for a table's layout; `screen` maps a
    /// top-down table rect to the screen.
    func update(_ geometry: MarkdownTableLayout, parent: Any, screen: (NSRect) -> NSRect,
                isSelected: (CellCoord) -> Bool = { _ in false }) -> [NSAccessibilityElement] {
        rows = geometry.cellRects.enumerated().map { row, rects -> NSAccessibilityElement in
            let element = rows.indices.contains(row) ? rows[row] : NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(parent)
            element.setAccessibilityIndex(row)
            element.setAccessibilityFrame(screen(rects.reduce(NSRect.null) { $0.union($1) }))
            let cells = element.accessibilityChildren() as? [NSAccessibilityElement] ?? []
            element.setAccessibilityChildren(rects.enumerated().map { column, rect in
                let cell = cells.indices.contains(column) ? cells[column] : NSAccessibilityElement()
                cell.setAccessibilityRole(.cell)
                cell.setAccessibilityParent(element)
                let text = geometry.cells.indices.contains(row) && geometry.cells[row].indices.contains(column)
                    ? geometry.cells[row][column].string.replacingOccurrences(of: "\u{2028}", with: "\n") : ""
                cell.setAccessibilityValue(text)
                cell.setAccessibilityLabel(row == 0 ? "Column header, \(text)" : text)
                cell.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
                cell.setAccessibilityColumnIndexRange(NSRange(location: column, length: 1))
                cell.setAccessibilitySelected(isSelected(CellCoord(row: row, column: column)))
                cell.setAccessibilityFrame(screen(rect))
                return cell
            })
            return element
        }
        return rows
    }
}

// MARK: - Rendered tables

/// A table that is not being edited, which draws as an image over its hidden
/// source: VoiceOver still reads it as an AXTable of rows and cells (PR D).
final class RenderedTableAccessibilityElement: NSAccessibilityElement {
    private var geometry: MarkdownTableLayout
    private let tableAccessibilityRows = TableAccessibilityRows()
    /// The table's source range in the note.
    let sourceRange: NSRange
    private var screen: (NSRect) -> NSRect

    /// `screen` maps a top-down rect of `geometry` to the screen.
    init(geometry: MarkdownTableLayout, sourceRange: NSRange, parent: Any, screen: @escaping (NSRect) -> NSRect) {
        self.geometry = geometry
        self.sourceRange = sourceRange
        self.screen = screen
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityFrame(screen(NSRect(origin: .zero, size: geometry.size)))
    }

    func update(geometry: MarkdownTableLayout, screen: @escaping (NSRect) -> NSRect) {
        self.geometry = geometry
        self.screen = screen
        setAccessibilityFrame(screen(NSRect(origin: .zero, size: geometry.size)))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityLabel() -> String? { "Table" }
    override func accessibilityRowCount() -> Int { geometry.cellRects.count }
    override func accessibilityColumnCount() -> Int { geometry.cellRects.first?.count ?? 0 }
    override func accessibilityChildren() -> [Any]? { accessibilityRows() }
    override func accessibilityRows() -> [Any]? {
        tableAccessibilityRows.update(geometry, parent: self, screen: screen)
    }
    override func accessibilityColumnHeaderUIElements() -> [Any]? {
        (accessibilityRows()?.first as? NSAccessibilityElement)?.accessibilityChildren()
    }
}

extension NativeTextView {
    /// The narrow tables drawn in the laid-out viewport that no cell editor
    /// owns, each as an AXTable (a focused table's grid is its own AXTable).
    func renderedTableAccessibilityElements() -> [RenderedTableAccessibilityElement] {
        guard let coordinator = delegate as? NativeTextViewCoordinator, let storage = textStorage else {
            renderedAccessibilityTables.removeAll()
            return []
        }
        let session = coordinator.tableEditingSession
        let tables = renderedTables().compactMap { table -> RenderedTableAccessibilityElement? in
            guard !(session.owns(table.range) && session.grid?.window != nil), table.rect.width > 0, table.rect.height > 0 else { return nil }
            let image = storage.attribute(.renderedBlockImage, at: table.anchor, effectiveRange: nil) as? NSImage
            guard let geometry = image.flatMap(MarkdownTableLayout.layout(ofRaster:)) ?? session.geometry(forTableAt: table.range),
                  geometry.size.width > 0, geometry.size.height > 0 else { return nil }
            let sx = table.rect.width / geometry.size.width, sy = table.rect.height / geometry.size.height
            let screen: (NSRect) -> NSRect = { [weak self] rect in
                let local = NSRect(x: table.rect.minX + rect.minX * sx, y: table.rect.minY + rect.minY * sy,
                                   width: rect.width * sx, height: rect.height * sy)
                guard let self, let window = self.window else { return local }
                return window.convertToScreen(self.convert(local, to: nil))
            }
            if let existing = renderedAccessibilityTables[table.range] {
                existing.update(geometry: geometry, screen: screen)
                return existing
            }
            return RenderedTableAccessibilityElement(geometry: geometry, sourceRange: table.range, parent: self, screen: screen)
        }
        renderedAccessibilityTables = Dictionary(uniqueKeysWithValues: tables.map { ($0.sourceRange, $0) })
        return tables
    }
}

extension WideTableImageView {
    /// Not being edited, a wide table reads as an AXTable of its drawn cells;
    /// being edited, its grid (a subview) is the table.
    private var renderedGeometry: MarkdownTableLayout? {
        guard let image, let layout = MarkdownTableLayout.layout(ofRaster: image) else { return nil }
        return subviews.contains(where: { $0 is MarkdownTableGridView }) ? nil : layout
    }

    override func isAccessibilityElement() -> Bool { renderedGeometry != nil || super.isAccessibilityElement() }
    override func accessibilityRole() -> NSAccessibility.Role? { renderedGeometry != nil ? .table : super.accessibilityRole() }
    override func accessibilityLabel() -> String? { renderedGeometry != nil ? "Table" : super.accessibilityLabel() }
    override func accessibilityRowCount() -> Int { renderedGeometry?.cellRects.count ?? 0 }
    override func accessibilityColumnCount() -> Int { renderedGeometry?.cellRects.first?.count ?? 0 }
    override func accessibilityChildren() -> [Any]? {
        renderedGeometry == nil ? super.accessibilityChildren() : accessibilityRows()
    }
    override func accessibilityRows() -> [Any]? {
        guard let geometry = renderedGeometry, let image else { return [] }
        let top = isFlipped ? 0 : bounds.height - image.size.height
        return tableAccessibilityRows.update(geometry, parent: self) { [weak self] rect in
            guard let self else { return rect }
            let local = NSRect(x: rect.minX, y: self.isFlipped ? top + rect.minY : top + image.size.height - rect.maxY,
                               width: rect.width, height: rect.height)
            return self.window?.convertToScreen(self.convert(local, to: nil)) ?? local
        }
    }
    override func accessibilityColumnHeaderUIElements() -> [Any]? {
        (accessibilityRows()?.first as? NSAccessibilityElement)?.accessibilityChildren()
    }
}

// MARK: - Hover chrome

extension TableChromeView {
    /// the reference editor's labels and help for each chrome control.
    static func accessibilityText(for zone: TableChromeLayout.Zone) -> (label: String, help: String?)? {
        switch zone {
        case .columnGrip: ("Column options", "Click for column options \u{b7} drag to move")
        case .rowGrip: ("Row options", "Click for row options \u{b7} drag to move")
        case .handle: ("Drag to move table", nil)
        case .addRow: ("Add row", "Add row")
        case .addColumn: ("Add column", "Add column")
        case .resize: nil
        }
    }

    override func isAccessibilityElement() -> Bool { false }

    /// The controls showing now, each an AXButton whose press does what a click does.
    override func accessibilityChildren() -> [Any]? {
        guard !isHidden, let layout, let hovered, let controller else { return [] }
        var zones: [TableChromeLayout.Zone] = [.columnGrip, .rowGrip, .handle]
        if showsAddRow { zones.append(.addRow) }
        if showsAddColumn, layout.addColumnBar != nil { zones.append(.addColumn) }
        return zones.compactMap { zone -> TableAccessibilityElement? in
            guard let text = Self.accessibilityText(for: zone), let superview, let window else { return nil }
            let element = TableAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(text.label)
            element.setAccessibilityHelp(text.help)
            let rect = rect(of: zone, in: layout, hovered: hovered)
            element.setAccessibilityFrame(window.convertToScreen(superview.convert(rect, to: nil)))
            element.press = { [weak controller] in
                guard let controller else { return false }
                switch zone {
                case .columnGrip: controller.clickGrip(.columnGrip, index: hovered.column)
                case .rowGrip: controller.clickGrip(.rowGrip, index: hovered.row)
                case .handle: controller.clickHandle()
                case .addRow, .addColumn: controller.clickAddBar(zone, at: NSPoint(x: rect.midX, y: rect.midY))
                case .resize: return false
                }
                return true
            }
            return element
        }
    }
}

// MARK: - Menus

extension TableMenuView {
    /// The rows as AX menu items: disabled ones say why; width rows carry their mark.
    func accessibilityItems() -> [TableAccessibilityElement] {
        let window = self.window
        return titles.indices.compactMap { index -> TableAccessibilityElement? in
            let title = titles[index]
            guard title != "\u{2014}", let frame = rowFrame(at: index) else { return nil }
            let element = TableAccessibilityElement()
            element.setAccessibilityRole(.menuItem)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(title)
            let reason = disabledReason(of: title)
            element.setAccessibilityEnabled(reason == nil)
            element.setAccessibilityHelp(reason)
            if let checked = isChecked(title) { element.setAccessibilityValue(checked ? "\u{2713}" : "") }
            element.setAccessibilitySelected(focused == index)
            element.setAccessibilityFrame(window?.convertToScreen(convert(frame, to: nil)) ?? frame)
            element.press = { [weak self] in
                guard let self, reason == nil else { return false }
                self.activate(title: title)
                return true
            }
            return element
        }
    }

    override func accessibilityChildren() -> [Any]? { accessibilityItems() }
}
