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
        func screen(_ rect: NSRect) -> NSRect { window?.convertToScreen(convert(rect, to: nil)) ?? rect }
        return geometry.cellRects.enumerated().map { row, rects -> NSAccessibilityElement in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.row)
            element.setAccessibilityParent(self)
            element.setAccessibilityIndex(row)
            element.setAccessibilityFrame(screen(rects.reduce(NSRect.null) { $0.union($1) }))
            element.setAccessibilityChildren(rects.enumerated().map { column, rect in
                let cell = NSAccessibilityElement()
                cell.setAccessibilityRole(.cell)
                cell.setAccessibilityParent(element)
                let text = geometry.cells.indices.contains(row) && geometry.cells[row].indices.contains(column)
                    ? geometry.cells[row][column].string.replacingOccurrences(of: "\u{2028}", with: "\n") : ""
                cell.setAccessibilityValue(text)
                cell.setAccessibilityLabel(row == 0 ? "Column header, \(text)" : text)
                cell.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
                cell.setAccessibilityColumnIndexRange(NSRange(location: column, length: 1))
                cell.setAccessibilitySelected(session?.cellSelection?.contains(CellCoord(row: row, column: column)) ?? false)
                cell.setAccessibilityFrame(screen(rect))
                return cell
            })
            return element
        }
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
