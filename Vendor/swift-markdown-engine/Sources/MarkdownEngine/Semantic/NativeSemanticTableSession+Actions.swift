import AppKit

extension NativeSemanticTableSession {
    @discardableResult
    func insertRow(at index: Int) -> Bool {
        guard index > 0, index <= topology.identifiedRows.count else { return false }
        var next = snapshot()
        next.identifiedRows.insert(.init(cells: next.alignments.map { _ in .init(text: .init(text: "")) }), at: index)
        return replaceTopology(next, name: "Insert Row")
    }

    @discardableResult
    func insertColumn(at index: Int) -> Bool {
        guard index >= 0, index <= topology.alignments.count else { return false }
        var next = snapshot()
        next.alignments.insert(.left, at: index)
        for row in next.identifiedRows.indices {
            next.identifiedRows[row].cells.insert(.init(text: .init(text: "")), at: index)
        }
        return replaceTopology(next, name: "Insert Column")
    }

    @discardableResult
    func deleteColumn(at index: Int) -> Bool {
        guard topology.alignments.count > 1, topology.alignments.indices.contains(index) else { return false }
        var next = snapshot()
        next.alignments.remove(at: index)
        for row in next.identifiedRows.indices { next.identifiedRows[row].cells.remove(at: index) }
        return replaceTopology(next, name: "Delete Column")
    }

    @discardableResult
    func alignColumn(_ alignment: MarkdownTableAlignment, at index: Int) -> Bool {
        guard topology.alignments.indices.contains(index) else { return false }
        var next = snapshot()
        next.alignments[index] = alignment
        return replaceTopology(next, name: "Align Column")
    }

    @discardableResult
    func moveColumn(_ index: Int, to destination: Int) -> Bool {
        guard topology.alignments.indices.contains(index), topology.alignments.indices.contains(destination), index != destination else { return false }
        var next = snapshot()
        let alignment = next.alignments.remove(at: index)
        next.alignments.insert(alignment, at: destination)
        for row in next.identifiedRows.indices {
            let cell = next.identifiedRows[row].cells.remove(at: index)
            next.identifiedRows[row].cells.insert(cell, at: destination)
        }
        return replaceTopology(next, name: "Move Column")
    }

    func showCellActions(_ event: NSEvent) {
        guard let grid, let host = grid.enclosingScrollView ?? grid.superview,
              let clicked = grid.geometry.cell(at: grid.convert(event.locationInWindow, from: nil)) else { return }
        select(row: clicked.row, column: clicked.column)
        typealias Item = TableMenuView.Item
        let rowID = topology.identifiedRows[clicked.row].id
        let items: [Item] = [
            Item("Insert Row Above", symbol: "arrow.up.to.line", disabledReason: clicked.row == 0 ? "Header rows stay at the top." : nil) { [weak self] in self?.insertRow(at: clicked.row) },
            Item("Insert Row Below", symbol: "arrow.down.to.line") { [weak self] in self?.insertRow(at: clicked.row + 1) },
            Item("Insert Column Left", symbol: "arrow.left.to.line") { [weak self] in self?.insertColumn(at: clicked.column) },
            Item("Insert Column Right", symbol: "arrow.right.to.line") { [weak self] in self?.insertColumn(at: clicked.column + 1) },
            .separator,
            Item("Delete Row", symbol: "xmark.rectangle", disabledReason: clicked.row == 0 ? "Header rows stay at the top." : nil) { [weak self] in self?.deleteRow(rowID) },
            Item("Delete Column", symbol: "xmark.rectangle.portrait", disabledReason: topology.alignments.count == 1 ? "Keep at least one column." : nil) { [weak self] in self?.deleteColumn(at: clicked.column) },
        ]
        var point = host.convert(event.locationInWindow, from: nil)
        if !host.isFlipped { point.y = host.bounds.height - point.y }
        let menu = TableMenuView.present(items, family: .float, label: "Cell actions", placement: .at(point),
            in: host, fromKeyboard: false, returningFocusTo: activeCellID.flatMap { editor(for: $0) }) { _ in }
        menu.closesOnScroll = false
        menu.closesOnTyping = true
    }
}

extension NativeSemanticTableSession {
    var commandTarget: TableCellSelection? {
        cellSelection ?? editedCoordinate.map { .init(anchor: $0, head: $0) }
    }

    func canPerform(_ command: MarkdownTableCommand) -> Bool {
        guard isEditable, !hasActiveComposition else { return false }
        guard let target = commandTarget else { return command == .deleteTable || command == .editTableSource }
        if let activeCellID, editor(for: activeCellID)?.hasMarkedText() == true { return false }
        switch command {
        case .insertRowAbove, .deleteRow: return target.rows.lowerBound > 0
        case .deleteColumn: return target.columns.count < topology.alignments.count
        case .editTableSource: return true
        default: return true
        }
    }

    @discardableResult
    func perform(_ command: MarkdownTableCommand) -> Bool {
        guard canPerform(command), let target = commandTarget else { return false }
        switch command {
        case .insertRowAbove: return insertRow(at: target.rows.lowerBound)
        case .insertRowBelow: return insertRow(at: target.rows.upperBound + 1)
        case .insertColumnLeft: return insertColumn(at: target.columns.lowerBound)
        case .insertColumnRight: return insertColumn(at: target.columns.upperBound + 1)
        case .deleteRow:
            var next = snapshot()
            next.identifiedRows.removeSubrange(target.rows)
            return replaceTopology(next, name: command.title)
        case .deleteColumn:
            var next = snapshot()
            next.alignments.removeSubrange(target.columns)
            for row in next.identifiedRows.indices { next.identifiedRows[row].cells.removeSubrange(target.columns) }
            return replaceTopology(next, name: command.title)
        case .alignColumnLeft, .alignColumnCenter, .alignColumnRight:
            var next = snapshot()
            for column in target.columns { next.alignments[column] = command == .alignColumnLeft ? .left : command == .alignColumnCenter ? .center : .right }
            return replaceTopology(next, name: command.title)
        case .deleteTable, .editTableSource: return false
        }
    }

    @discardableResult
    func toggle(_ mark: SemanticInlineMarks) -> Bool {
        guard isEditable, !hasActiveComposition else { return false }
        if let selection = cellSelection {
            var next = snapshot()
            let runs = selection.cells.flatMap { next.identifiedRows[$0.row].cells[$0.column].text.runs }
            let allOn = !runs.isEmpty && runs.allSatisfy { $0.marks.contains(mark) }
            for cell in selection.cells {
                let value = next.identifiedRows[cell.row].cells[cell.column].text
                next.identifiedRows[cell.row].cells[cell.column].text = .init(runs: value.runs.map {
                    .init(payload: $0.payload, marks: allOn ? $0.marks.subtracting(mark) : $0.marks.union(mark), link: $0.link)
                })
            }
            return replaceTopology(next, name: "Format Cells")
        }
        guard let activeCellID, let editor = editor(for: activeCellID) else { return false }
        let changed = NativeSemanticInlineEditor(textView: editor).toggle(mark)
        if changed { textDidChange(Notification(name: NSText.didChangeNotification, object: editor)) }
        return changed
    }

    func applyFormat(_ format: MarkdownFormat) -> Bool {
        switch format {
        case .bold: return toggle(.bold)
        case .italic: return toggle(.italic)
        case .underline: return toggle(.underline)
        case .highlight: return toggle(.highlight)
        case .strikethrough: return toggle(.strikethrough)
        default: return false
        }
    }
}
