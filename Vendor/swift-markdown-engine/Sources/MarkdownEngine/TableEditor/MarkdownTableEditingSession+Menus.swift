import AppKit

/// the reference editor's Cell actions and its Move row or column replacement menu
/// (doc 24 §5.4.3–§5.4.5), drawn by `TableMenuView`. A right-click on a
/// glyph or inside the cell's text selection keeps the native text menu.
extension MarkdownTableEditingSession {

    /// The cells a table command acts on: the range, else the caret's cell.
    var commandTarget: TableCellSelection {
        cellSelection ?? TableCellSelection(anchor: CellCoord(row: row, column: column), head: CellCoord(row: row, column: column))
    }

    private var menuHost: NSView? { coordinator?.textView?.enclosingScrollView }

    // MARK: - Opening

    /// A right-click (or ⌃-click) on a focused table: the native menu (from
    /// `standard`) over a glyph or the text selection, otherwise Cell actions.
    func contextMenu(for event: NSEvent, standard: () -> NSMenu?) -> NSMenu? {
        // A right-click in a table is what the hint teaches: it never shows again.
        coordinator?.tableHint?.latch()
        guard isActive, let grid, let table else { return standard() }
        let clicked = grid.geometry.cell(at: grid.convert(event.locationInWindow, from: nil)).map { CellCoord(row: $0.row, column: $0.column) }
        if let selection = cellSelection, let clicked, selection.contains(clicked) {
            // A right-click inside the range acts on the whole range.
            showCellActions(at: event.locationInWindow, fromKeyboard: false)
            return nil
        }
        if let clicked, clicked.row < table.rowCount, clicked.column < table.columnCount {
            if clicked.row != row || clicked.column != column { select(row: clicked.row, column: clicked.column) }
            if isOnGlyphOrSelection(event.locationInWindow) { return standard() }
            let local = editor.convert(event.locationInWindow, from: nil)
            if editor.bounds.contains(local) {
                editor.setSelectedRange(NSRange(location: editor.characterIndexForInsertion(at: local), length: 0))
            }
        }
        showCellActions(at: event.locationInWindow, fromKeyboard: false)
        return nil
    }

    /// the reference editor keeps the browser's menu within ±1 pt of a glyph (vertical
    /// slack max(2, line height / 4)) or inside the text selection.
    private func isOnGlyphOrSelection(_ windowPoint: NSPoint) -> Bool {
        let local = editor.convert(windowPoint, from: nil)
        guard editor.bounds.contains(local), let window = editor.window else { return false }
        let text = editor.string as NSString
        let index = editor.characterIndexForInsertion(at: local)
        let selection = editor.selectedRange()
        if selection.length > 0, index >= selection.location, index <= NSMaxRange(selection) { return true }
        let slack = max(2, MarkdownTableLayout.cellFont(for: coordinator?.baseFontAndStyle().0 ?? .systemFont(ofSize: 16)).pointSize
                           * MarkdownTableLayout.lineHeightMultiple / 4)
        for candidate in [index - 1, index] where candidate >= 0 && candidate < text.length {
            guard let scalar = UnicodeScalar(text.character(at: candidate)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let screen = editor.firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            guard !screen.isNull, screen.width > 0 else { continue }
            let rect = editor.convert(window.convertFromScreen(screen), from: nil)
            if local.x >= rect.minX - 1, local.x <= rect.maxX + 1, local.y >= rect.minY - slack, local.y <= rect.maxY + slack { return true }
        }
        return false
    }

    /// Opens Cell actions at a window point, or at the caret from the keyboard (⇧F10).
    func showCellActions(at windowPoint: NSPoint?, fromKeyboard: Bool) {
        coordinator?.tableHint?.latch()
        guard let host = menuHost, table != nil else { return }
        let point: NSPoint
        if let windowPoint {
            point = topDown(host.convert(windowPoint, from: nil), in: host)
        } else {
            // From the keyboard: at the caret, by its left and bottom.
            let screen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let caret = editor.window.map { host.convert($0.convertFromScreen(screen), from: nil) } ?? .zero
            point = topDown(NSPoint(x: caret.minX, y: host.isFlipped ? caret.maxY : caret.minY), in: host)
        }
        coordinator?.selectionBar?.rightClickSuppressed = true
        let menu = TableMenuView.present(cellActionItems(fromKeyboard: fromKeyboard), family: .float, label: "Cell actions",
                                         placement: .at(point), in: host, fromKeyboard: fromKeyboard,
                                         returningFocusTo: editor) { [weak self] _ in self?.openMenu = nil }
        menu.closesOnScroll = false
        menu.closesOnTyping = true
        openMenu = menu
    }

    private func topDown(_ point: NSPoint, in host: NSView) -> NSPoint {
        host.isFlipped ? point : NSPoint(x: point.x, y: host.bounds.height - point.y)
    }

    // MARK: - Cell actions

    func cellActionItems(fromKeyboard: Bool) -> [TableMenuView.Item] {
        guard let table else { return [] }
        let target = commandTarget
        let headerReason = "Header rows stay at the top."
        typealias Item = TableMenuView.Item
        var items: [Item] = [
            Item("Insert Row Above", symbol: "arrow.up.to.line", disabledReason: target.rows.lowerBound == 0 ? headerReason : nil) { [weak self] in
                self?.insertAround(target, edit: .insertRow(below: false), announce: fromKeyboard ? "Row inserted above" : nil)
            },
            Item("Insert Row Below", symbol: "arrow.down.to.line") { [weak self] in
                self?.insertAround(target, edit: .insertRow(below: true), announce: fromKeyboard ? "Row inserted below" : nil)
            },
            Item("Insert Column Left", symbol: "arrow.left.to.line") { [weak self] in
                self?.insertAround(target, edit: .insertColumn(right: false), announce: fromKeyboard ? "Column inserted left" : nil)
            },
            Item("Insert Column Right", symbol: "arrow.right.to.line") { [weak self] in
                self?.insertAround(target, edit: .insertColumn(right: true), announce: fromKeyboard ? "Column inserted right" : nil)
            },
            Item("Move Row or Column", symbol: "arrow.up.and.down.and.arrow.left.and.right") { [weak self] in
                self?.showMoveMenu(fromKeyboard: fromKeyboard)
            },
            Item("Set Column Width", symbol: "arrow.left.and.right") { [weak self] in
                self?.showWidthMenu(fromKeyboard: fromKeyboard)
            },
            .separator,
            Item("Delete Row", symbol: "xmark.rectangle", disabledReason: deleteRowsDisabledReason(target)) { [weak self] in
                self?.deleteRows(of: target, announce: fromKeyboard)
            },
            Item("Delete Column", symbol: "xmark.rectangle.portrait", disabledReason: deleteColumnsDisabledReason(target)) { [weak self] in
                self?.deleteColumns(of: target, announce: fromKeyboard)
            },
            Item("Delete Table", symbol: nil, isDanger: true) { [weak self] in
                guard let self else { return }
                self.setCellSelection(nil)
                if self.deleteTable(), fromKeyboard { Self.announce("Table deleted") }
            },
        ]
        if table.rowCount - 1 >= 2 {
            items += [
                .separator,
                Item("Sort Column Ascending", symbol: "arrow.up") { [weak self] in
                    self?.sortColumn(target.columns.lowerBound, ascending: true, announce: fromKeyboard)
                },
                Item("Sort Column Descending", symbol: "arrow.down") { [weak self] in
                    self?.sortColumn(target.columns.lowerBound, ascending: false, announce: fromKeyboard)
                },
            ]
        }
        items += [
            .separator,
            Item("Align Column Left", symbol: "text.alignleft") { [weak self] in self?.align(target.columns, .left, announce: fromKeyboard) },
            Item("Align Column Center", symbol: "text.aligncenter") { [weak self] in self?.align(target.columns, .center, announce: fromKeyboard) },
            Item("Align Column Right", symbol: "text.alignright") { [weak self] in self?.align(target.columns, .right, announce: fromKeyboard) },
        ]
        return items
    }

    // MARK: - Host commands (Format ▸ Table)

    /// Whether `command` can act now: a table is being edited and its Cell
    /// actions row would be enabled.
    func canPerform(_ command: MarkdownTableCommand) -> Bool {
        guard isActive, coordinator?.textView?.isEditable == true, !isComposing else { return false }
        let target = commandTarget
        switch command {
        case .insertRowAbove: return target.rows.lowerBound > 0
        case .deleteRow: return deleteRowsDisabledReason(target) == nil
        case .deleteColumn: return deleteColumnsDisabledReason(target) == nil
        default: return true
        }
    }

    /// Runs `command` as its Cell actions row does. False when it cannot act.
    @discardableResult
    func performCommand(_ command: MarkdownTableCommand) -> Bool {
        guard canPerform(command) else { return false }
        openMenu?.close(.dismissed)
        let target = commandTarget
        switch command {
        case .insertRowAbove: insertAround(target, edit: .insertRow(below: false), announce: nil)
        case .insertRowBelow: insertAround(target, edit: .insertRow(below: true), announce: nil)
        case .insertColumnLeft: insertAround(target, edit: .insertColumn(right: false), announce: nil)
        case .insertColumnRight: insertAround(target, edit: .insertColumn(right: true), announce: nil)
        case .deleteRow: deleteRows(of: target, announce: false)
        case .deleteColumn: deleteColumns(of: target, announce: false)
        case .deleteTable:
            setCellSelection(nil)
            return deleteTable()
        case .alignColumnLeft: return alignColumns(.left)
        case .alignColumnCenter: return alignColumns(.center)
        case .alignColumnRight: return alignColumns(.right)
        case .editTableSource: editTableSource(nil)
        }
        return true
    }

    /// Insert one row or column at the target's edge (the reference editor: the
    /// range's top or bottom row, left or right column).
    func insertAround(_ target: TableCellSelection, edit: MarkdownTableEdit, announce: String?) {
        setCellSelection(nil)
        switch edit {
        case .insertRow(let below): select(row: below ? target.rows.upperBound : target.rows.lowerBound, column: target.columns.lowerBound)
        case .insertColumn(let right): select(row: target.rows.lowerBound, column: right ? target.columns.upperBound : target.columns.lowerBound)
        default: break
        }
        if perform(edit), let announce { Self.announce(announce) }
    }

    /// Every row or every column cannot go: that is Delete table (doc 24 §5.9.4).
    func deleteRowsDisabledReason(_ target: TableCellSelection) -> String? {
        guard let table, target.isFullColumns(rowCount: table.rowCount) else { return nil }
        return "Use Delete Table to remove every row."
    }

    func deleteColumnsDisabledReason(_ target: TableCellSelection) -> String? {
        guard let table, target.isFullRows(columnCount: table.columnCount) else { return nil }
        return "Use Delete Table to remove every column."
    }

    func deleteRows(of target: TableCellSelection, announce: Bool) {
        guard let table, deleteRowsDisabledReason(target) == nil else { return }
        setCellSelection(nil)
        guard let text = MarkdownTableEditPlan.deletingRows(target.rows, in: table),
              let refreshed = rewriteTable(text, actionName: target.rows.count > 1 ? "Delete Rows" : "Delete Row") else { return }
        select(row: min(target.rows.lowerBound, refreshed.rowCount - 1), column: min(column, refreshed.columnCount - 1))
        place(.start)
        remount()
        if announce { Self.announce(target.rows.count > 1 ? "Rows deleted" : "Row deleted") }
    }

    func deleteColumns(of target: TableCellSelection, announce: Bool) {
        guard let table, deleteColumnsDisabledReason(target) == nil else { return }
        setCellSelection(nil)
        guard let text = MarkdownTableEditPlan.deletingColumns(target.columns, in: table),
              let refreshed = rewriteTable(text, actionName: target.columns.count > 1 ? "Delete Columns" : "Delete Column", columns: { widths in
                  widths.removeSubrange(min(target.columns.lowerBound, widths.count)..<min(target.columns.upperBound + 1, widths.count))
              }) else { return }
        select(row: min(row, refreshed.rowCount - 1), column: min(target.columns.lowerBound, refreshed.columnCount - 1))
        place(.start)
        remount()
        if announce { Self.announce(target.columns.count > 1 ? "Columns deleted" : "Column deleted") }
    }

    /// Sort the body rows by the column's displayed text, number-aware (doc 24 §5.9.4).
    private func sortColumn(_ column: Int, ascending: Bool, announce: Bool) {
        guard let table, let coordinator else { return }
        setCellSelection(nil)
        let configuration = coordinator.configuration
        let keys = (1..<table.rowCount).map { row -> String in
            let source = cellSource(CellCoord(row: row, column: column), in: table) ?? ""
            return MarkdownStyler.formattedCellString(source, baseFont: .systemFont(ofSize: 13), header: false, theme: configuration.theme,
                                                      codeBackgroundColor: .clear, latex: configuration.services.latex)
                .string.trimmingCharacters(in: .whitespaces)
        }
        guard let text = MarkdownTableEditPlan.sortingRows(by: keys, ascending: ascending, in: table),
              rewriteTable(text, actionName: "Sort Column") != nil else { return }
        select(row: row, column: column)
        remount()
        if announce { Self.announce(ascending ? "Column sorted ascending" : "Column sorted descending") }
    }

    /// ⌘L, ⌘E, ⌘R and Format ▸ Align in a cell: the target columns take the
    /// alignment. GFM has no justified column, so Justify does nothing.
    @discardableResult
    func alignColumns(_ alignment: MarkdownTextAlignment, announce: Bool = false) -> Bool {
        let column: MarkdownTableAlignment
        switch alignment {
        case .left: column = .left
        case .center: column = .center
        case .right: column = .right
        case .justify: return false
        }
        guard isActive else { return false }
        return align(commandTarget.columns, column, announce: announce)
    }

    /// The undo name of Align Column Left, Center or Right.
    static func alignActionName(_ alignment: MarkdownTableAlignment) -> String {
        switch alignment {
        case .left: "Align Column Left"
        case .center: "Align Column Center"
        case .right: "Align Column Right"
        }
    }

    /// Align every target column (Align Column Left writes plain dashes).
    @discardableResult
    private func align(_ columns: ClosedRange<Int>, _ alignment: MarkdownTableAlignment, announce: Bool) -> Bool {
        guard var current = table else { return false }
        setCellSelection(nil)
        var text = (current.source as NSString).substring(with: current.range)
        for column in columns {
            guard let plan = MarkdownTableEditPlan(.align(alignment), table: current, row: 0, column: column),
                  let next = MarkdownTableSource(source: plan.replacement, range: NSRange(location: 0, length: (plan.replacement as NSString).length))
            else { return false }
            text = plan.replacement
            current = next
        }
        guard rewriteTable(text, actionName: Self.alignActionName(alignment)) != nil else { return false }
        remount()
        if announce { Self.announce("Aligned \(alignment)") }
        return true
    }

    // MARK: - Move row or column

    /// the reference editor's Move menu replaces Cell actions under the caret's cell.
    func showMoveMenu(fromKeyboard: Bool) {
        guard let host = menuHost, let table, let grid else { return }
        setCellSelection(nil)
        let cell = CellCoord(row: row, column: column)
        let last = table.rowCount - 1
        let header = "Header rows stay at the top."
        typealias Item = TableMenuView.Item
        let items: [Item] = [
            Item("Move Row Up", symbol: "arrow.up", disabledReason: cell.row <= 1 ? header : nil) { [weak self] in
                self?.moveRow(by: -1, announce: fromKeyboard)
            },
            Item("Move Row Down", symbol: "arrow.down",
                 disabledReason: cell.row == 0 ? header : cell.row == last ? "This row is already at the bottom." : nil) { [weak self] in
                self?.moveRow(by: 1, announce: fromKeyboard)
            },
            Item("Move Column Left", symbol: "arrow.left",
                 disabledReason: cell.column == 0 ? "This column is already at the far left." : nil) { [weak self] in
                self?.moveColumn(by: -1, announce: fromKeyboard)
            },
            Item("Move Column Right", symbol: "arrow.right",
                 disabledReason: cell.column == table.columnCount - 1 ? "This column is already at the far right." : nil) { [weak self] in
                self?.moveColumn(by: 1, announce: fromKeyboard)
            },
        ]
        guard grid.geometry.cellRects.indices.contains(cell.row) else { return }
        let rect = grid.convert(grid.geometry.cellRects[cell.row][cell.column], to: host)
        let anchor = host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        openMenu = TableMenuView.present(items, family: .object, label: "Move row or column", placement: .below(anchor, rightAligned: false),
                                         in: host, fromKeyboard: fromKeyboard, returningFocusTo: editor) { [weak self] _ in
            self?.openMenu = nil
        }
    }

    /// One step up or down; the caret keeps its place in the moved cell.
    func moveRow(by step: Int, announce: Bool) {
        guard let table else { return }
        let boundary = step < 0 ? row - 1 : row + 2
        let caret = editor.selectedRange()
        guard let text = MarkdownTableEditPlan.movingRow(row, to: boundary, in: table),
              let refreshed = rewriteTable(text, actionName: "Move Row") else { return }
        let moved = row + step
        select(row: moved, column: column)
        editor.setSelectedRange(caret)
        remount()
        if announce { Self.announce("Row moved \(step < 0 ? "up" : "down"), \(moved + 1) of \(refreshed.rowCount)") }
    }

    /// One step left or right; the caret keeps its place in the moved cell.
    func moveColumn(by step: Int, announce: Bool) {
        guard let table else { return }
        let boundary = step < 0 ? column - 1 : column + 2
        let caret = editor.selectedRange()
        let from = column
        guard let text = MarkdownTableEditPlan.movingColumn(column, to: boundary, in: table),
              let refreshed = rewriteTable(text, actionName: "Move Column", columns: { $0.moveColumn(from, to: boundary) }) else { return }
        let moved = column + step
        select(row: row, column: moved)
        editor.setSelectedRange(caret)
        remount()
        if announce { Self.announce("Column moved \(step < 0 ? "left" : "right"), \(moved + 1) of \(refreshed.columnCount)") }
    }

    /// The first entry into a cell shows the reference editor's table hint (doc 24 §5.3.7).
    func showTableHintIfNeeded() {
        guard !TableHintView.latched, let hint = coordinator?.tableHint, let host = coordinator?.textView?.enclosingScrollView, let grid,
              grid.geometry.cellRects.indices.contains(row), grid.geometry.cellRects[row].indices.contains(column) else { return }
        func topDown(_ rect: NSRect) -> NSRect {
            host.isFlipped ? rect : NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let full = topDown(grid.convert(grid.bounds, to: host))
        let visible = topDown(grid.convert(grid.visibleRect, to: host))
        let table = NSRect(x: visible.minX, y: full.minY, width: visible.width, height: full.height)
        hint.show(table: table, cell: topDown(grid.convert(grid.geometry.cellRects[row][column], to: host)), in: host)
    }

    /// Announces `text` at medium priority; messages within 150 ms coalesce to the last (the reference editor's announcer).
    static func announce(_ text: String) {
        pendingAnnouncement.text = text
        pendingAnnouncement.work?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let text = pendingAnnouncement.text else { return }
                pendingAnnouncement.text = nil
                lastAnnouncement = text
                let element: Any = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp as Any
                NSAccessibility.post(element: element, notification: .announcementRequested,
                                     userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        pendingAnnouncement.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    nonisolated(unsafe) private static var pendingAnnouncement: (text: String?, work: DispatchWorkItem?) = (nil, nil)
    /// The message waiting out the 150 ms coalescing window (tests).
    static var pendingAnnouncementText: String? { pendingAnnouncement.text }
    /// The last message posted (tests).
    nonisolated(unsafe) static var lastAnnouncement: String?
}
