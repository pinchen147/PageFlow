import AppKit

/// the reference editor's column widths (doc 24 §5.4.6, §7.3.6), view-only in PageFlow
/// (deviation a): Set column width and column resize write a width per
/// column to the document's view state, never to the file. Each change is
/// one Undo step; the widths follow the table through its own edits.
extension MarkdownTableEditingSession {
    static let widthPresets: [(title: String, width: CGFloat)] = [
        ("Narrow", 112), ("Medium", 224), ("Wide", 336), ("Extra wide", 672),
    ]

    private var widthsController: MarkdownEditorController? { coordinator?.editorController }

    /// This table's widths, one per column (nil: Auto).
    var columnWidths: [CGFloat?] {
        guard let table else { return [] }
        let stored = widthKey.flatMap { widthsController?.tableWidthsStore.widths[$0] } ?? []
        return (0..<table.columnCount).map { $0 < stored.count ? stored[$0] : nil }
    }

    /// The key the widths are kept under, computed once per table.
    @discardableResult
    func resolveWidthKey() -> String? {
        if widthKey == nil, let table { widthKey = coordinator?.tableKey(forTableAt: table.range) }
        return widthKey
    }

    // MARK: - Set column width

    /// the reference editor's Column width menu replaces Cell actions under the caret's cell.
    func showWidthMenu(fromKeyboard: Bool) {
        guard let host = coordinator?.textView?.enclosingScrollView, let grid, table != nil else { return }
        let target = commandTarget
        resolveWidthKey()
        let widths = target.columns.map { columnWidths[$0] }
        let checked: CGFloat?? = widths.allSatisfy { $0 == nil } ? .some(nil)
            : (widths.allSatisfy { $0 == widths.first! } ? .some(widths.first!) : .none)
        setCellSelection(nil)
        typealias Item = TableMenuView.Item
        var items: [Item] = Self.widthPresets.map { preset in
            Item(preset.title, symbol: nil, checked: checked == .some(preset.width)) { [weak self] in
                self?.setColumnWidth(preset.width, columns: target.columns, announce: fromKeyboard ? preset.title : nil)
            }
        }
        items.append(Item("Auto", symbol: nil, checked: checked == .some(nil)) { [weak self] in
            self?.setColumnWidth(nil, columns: target.columns, announce: fromKeyboard ? "Auto" : nil)
        })
        let cell = CellCoord(row: row, column: column)
        guard grid.geometry.cellRects.indices.contains(cell.row) else { return }
        let rect = grid.convert(grid.geometry.cellRects[cell.row][cell.column], to: host)
        let anchor = host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        let menu = TableMenuView.present(items, family: .object, label: "Column width", placement: .below(anchor, rightAligned: false),
                                         in: host, fromKeyboard: fromKeyboard, returningFocusTo: editor) { [weak self] _ in
            self?.openMenu = nil
        }
        // From the keyboard the checked row has focus, else Auto.
        if fromKeyboard { menu.focus(title: items.first { $0.checked == true }?.title ?? "Auto") }
        openMenu = menu
    }

    /// Writes `width` (nil: Auto) to every target column; the same width again does nothing.
    func setColumnWidth(_ width: CGFloat?, columns: ClosedRange<Int>, announce: String?) {
        guard let table, let key = resolveWidthKey() else { return }
        let clamped = width.map { min(MarkdownTableLayout.maximumSetColumnWidth, max(MarkdownTableLayout.minimumColumnWidth, $0)) }
        var widths = columnWidths
        for column in columns where column < widths.count { widths[column] = clamped }
        guard applyColumnWidths(widths, key: key, tableLocation: table.range.location, actionName: "Column Width") else { return }
        if let announce { Self.announce("Column width set to \(announce)") }
    }

    /// Stores `widths` under `key`, re-renders the table and registers the Undo
    /// step that puts the old widths back. False when nothing changed.
    @discardableResult
    func applyColumnWidths(_ widths: [CGFloat?], key: String, tableLocation: Int, actionName: String) -> Bool {
        guard let coordinator, let controller = widthsController else { return false }
        let new: [CGFloat?]? = widths.allSatisfy { $0 == nil } ? nil : widths
        let old = controller.tableWidthsStore.widths[key]
        guard new != old else { return false }
        storeWidths(new, key: key, tableLocation: tableLocation)
        if let undo = coordinator.textView?.undoManager {
            let ownsGroup = undo.groupingLevel == 0 && !undo.isUndoing && !undo.isRedoing
            if ownsGroup { undo.beginUndoGrouping() }
            registerWidthUndo(restoring: old, replacing: new, key: key, tableLocation: tableLocation, undo: undo)
            undo.setActionName(actionName)
            if ownsGroup { undo.endUndoGrouping() }
        }
        return true
    }

    private func registerWidthUndo(restoring old: [CGFloat?]?, replacing new: [CGFloat?]?, key: String, tableLocation: Int, undo: UndoManager) {
        guard let coordinator else { return }
        undo.registerUndo(withTarget: coordinator) { [weak self] _ in
            guard let self else { return }
            self.storeWidths(old, key: key, tableLocation: tableLocation)
            self.registerWidthUndo(restoring: new, replacing: old, key: key, tableLocation: tableLocation, undo: undo)
        }
    }

    /// Writes the widths and re-renders the table at `tableLocation` in place, pinned.
    private func storeWidths(_ widths: [CGFloat?]?, key: String, tableLocation: Int) {
        guard let coordinator, let controller = widthsController else { return }
        MainActor.assumeIsolated {
            var all = controller.tableColumnWidths
            all[key] = widths
            controller.tableColumnWidths = all
        }
        guard let main = coordinator.textView,
              let token = coordinator.parsedDocument(for: main.string).tokens.first(where: { $0.kind == .table && $0.range.location == tableLocation })
        else { return }
        coordinator.restyleTableNow(token.range)
        if owns(token.range) { remount() }
        // A width can turn a narrow table wide or back: its overlay and the cell editor follow.
        (main as? NativeTextView)?.updateWideTableOverlays()
        coordinator.tableChrome?.invalidate()
        coordinator.tableActions?.update()
    }

    // MARK: - Following the table's edits


    /// After an edit of this table: its widths move to the key its header now
    /// gives (the table keeps its ordinal), reshaped by `transform` for
    /// inserted, deleted or moved columns.
    func followWidths(_ transform: (inout [CGFloat?]) -> Void = { _ in }) {
        guard let table, let key = widthKey, let ordinal = key.split(separator: "-").last,
              let main = coordinator?.textView, let controller = widthsController else { return }
        let text = main.string as NSString
        guard NSMaxRange(table.range) <= text.length else { return }
        let newKey = String(NativeTextViewCoordinator.headerHash(ofTableAt: table.range, in: text), radix: 16) + "-" + ordinal
        MainActor.assumeIsolated {
            var all = controller.tableColumnWidths
            if var widths = all[key] {
                transform(&widths)
                all[key] = nil
                all[newKey] = widths.allSatisfy { $0 == nil } ? nil : widths
                controller.tableColumnWidths = all
            }
        }
        widthKey = newKey
    }
}

extension Array where Element == CGFloat? {
    /// The width at `column` moved to `boundary` (before column `boundary`), as a column move does.
    mutating func moveColumn(_ column: Int, to boundary: Int) {
        let needed = Swift.max(column + 1, boundary)
        while count < needed { append(nil) }
        let width = remove(at: column)
        insert(width, at: boundary > column ? boundary - 1 : boundary)
    }
}
