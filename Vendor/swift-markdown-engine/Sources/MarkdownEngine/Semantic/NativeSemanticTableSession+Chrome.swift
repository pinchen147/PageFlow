import AppKit

extension NativeSemanticTableSession {
    func hoverChrome(at point: NSPoint) {
        guard isEditable, let grid, let host = presentationHost else { chrome?.removeFromSuperview(); return }
        let layout = TableChromeLayout(cells: grid.geometry.cellRects.map { $0.map { grid.convert($0, to: host) } },
                                       clip: wideOverlay.map { $0.contentView.convert($0.contentView.bounds, to: host) } ?? host.visibleRect, minimumHandleX: host.visibleRect.minX)
        guard layout.wrapper.contains(point) else { chrome?.removeFromSuperview(); return }
        let view = chrome ?? TableChromeView()
        chrome = view
        view.semanticSession = self
        view.layout = layout
        view.hovered = layout.cell(at: point) ?? view.hovered ?? CellCoord(row: 0, column: 0)
        view.showsAddRow = point.y >= layout.table.maxY - 8
        view.showsAddColumn = point.x >= layout.table.maxX - 8
        view.hoveredZone = view.hovered.flatMap { layout.zone(at: point, hovered: $0, showsAddRow: view.showsAddRow, showsAddColumn: view.showsAddColumn) }
        view.resizeColumn = layout.resizeColumn(at: point)
        view.frame = layout.wrapper
        if view.superview !== host { host.addSubview(view, positioned: .above, relativeTo: grid) }
        view.needsDisplay = true
        _ = view.applyCursor(at: point)
    }

    func pressChrome(_ event: NSEvent) {
        guard isEditable, let chrome, let layout = chrome.layout, let hovered = chrome.hovered,
              let host = chrome.superview else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        guard let zone = layout.zone(at: point, hovered: hovered, showsAddRow: chrome.showsAddRow, showsAddColumn: chrome.showsAddColumn) else { return }
        switch zone {
        case .addRow: _ = insertRow(at: topology.identifiedRows.count)
        case .addColumn: _ = insertColumn(at: topology.alignments.count)
        case .resize:
            if let column = layout.resizeColumn(at: point) { trackColumnResize(event, column: column) }
        case .rowGrip, .columnGrip:
            trackGrip(event, rows: zone == .rowGrip, index: zone == .rowGrip ? hovered.row : hovered.column)
        case .handle:
            select(row: 0, column: 0)
            if let last = topology.identifiedRows.last { select(row: topology.identifiedRows.count - 1, column: last.cells.count - 1, extending: true) }
        }
    }

    private func trackGrip(_ event: NSEvent, rows: Bool, index: Int) {
        guard let chrome, let layout = chrome.layout, let host = chrome.superview, let window = host.window,
              !rows || index > 0 else { return }
        var boundary = index
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = host.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged {
                dragged = true
                boundary = layout.nearestBoundary(to: rows ? point.y : point.x, rows: rows)
                chrome.drag = (rows: rows, index: index, boundary: boundary)
                chrome.needsDisplay = true
            }
            if next.type == .leftMouseUp { break }
        }
        chrome.drag = nil
        chrome.needsDisplay = true
        if dragged {
            let destination = boundary > index ? boundary - 1 : boundary
            if rows { _ = moveRow(topology.identifiedRows[index].id, to: destination) }
            else { _ = moveColumn(index, to: destination) }
        } else {
            let start = CellCoord(row: rows ? index : 0, column: rows ? 0 : index)
            let end = CellCoord(row: rows ? index : topology.identifiedRows.count - 1,
                                column: rows ? topology.alignments.count - 1 : index)
            select(row: start.row, column: start.column)
            select(row: end.row, column: end.column, extending: true)
        }
    }
}
