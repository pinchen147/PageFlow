import AppKit

extension NativeSemanticTableSession {
    var editedCoordinate: CellCoord? {
        guard cellSelection == nil, let activeCellID else { return nil }
        for (row, value) in topology.identifiedRows.enumerated() {
            if let column = value.cells.firstIndex(where: { $0.id == activeCellID }) {
                return CellCoord(row: row, column: column)
            }
        }
        return nil
    }

    func geometry() -> MarkdownTableLayout {
        let appearance = grid?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        if let geometryCache, geometryCache.appearance.name == appearance.name { return geometryCache }
        let value = snapshot()
        let rows = value.rows.map { row in row.map { inline in
            (try? SemanticInlineCodec.encode(inline)) ?? inline.runs.map(\.text).joined()
        } }
        let alignments: [MarkdownStyler.TableAlignment] = value.alignments.map {
            switch $0 { case .left: return .left; case .center: return .center; case .right: return .right }
        }
        let layout = MarkdownTableLayout(table: .init(header: rows.first ?? [], alignments: alignments,
                                                rows: Array(rows.dropFirst())),
            font: presentationFont, theme: configuration.theme,
            codeBackground: configuration.services.syntaxHighlighter.backgroundColor(),
            latex: configuration.services.latex,
            appearance: appearance, cache: geometryCellCache, columnWidths: columnWidths)
        geometryCache = layout
        return layout
    }

    func mount(in host: NSView, origin: NSPoint, font: NSFont) {
        if presentationFont != font {
            presentationFont = font
            adopt(snapshot())
        }
        let layout = geometry()
        let view = grid ?? MarkdownTableGridView(geometry: layout, semanticSession: self)
        grid = view
        presentationHost = host
        let available = max(120, (host as? NSTextView)?.textContainer?.size.width ?? host.bounds.width)
        if layout.size.width > available {
            let overlay = wideOverlay ?? WideTableOverlay(semanticDocumentView: view)
            let savedOffset = overlay.superview == nil ? horizontalOffset : overlay.horizontalOffset
            wideOverlay = overlay
            if overlay.documentView !== view { overlay.documentView = view }
            if overlay.superview !== host { host.addSubview(overlay) }
            overlay.frame = NSRect(origin: origin, size: NSSize(width: available, height: layout.size.height + 14))
            view.frame = NSRect(origin: .zero, size: layout.size)
            overlay.tile()
            overlay.horizontalOffset = savedOffset
            overlay.onHorizontalScroll = { [weak self, weak overlay] in
                guard let self, let overlay else { return }
                self.horizontalOffset = overlay.horizontalOffset
                if let host = self.presentationHost, let window = host.window {
                    self.hoverChrome(at: host.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                }
                (self.presentationHost as? NativeSemanticTextView)?.semanticTableProxy?.tableDidScroll(overlay)
            }
        } else {
            wideOverlay?.removeFromSuperview()
            if wideOverlay?.documentView === view { wideOverlay?.documentView = nil }
            if view.superview !== host { host.addSubview(view) }
            let frame = NSRect(origin: origin, size: layout.size)
            if view.frame != frame { view.frame = frame }
        }
        refreshPresentation()
    }

    func detachPresentation() {
        // Keep native input alive while IME owns its candidate interaction.
        guard cellScroll?.documentView.flatMap({ $0 as? NSTextView })?.hasMarkedText() != true else { return }
        if let wideOverlay { horizontalOffset = wideOverlay.horizontalOffset }
        wideOverlay?.removeFromSuperview()
        chrome?.removeFromSuperview()
        grid?.removeFromSuperview()
    }

    func select(row: Int, column: Int, extending: Bool = false) {
        guard topology.identifiedRows.indices.contains(row),
              topology.identifiedRows[row].cells.indices.contains(column) else { return }
        let coordinate = CellCoord(row: row, column: column)
        if extending, let anchor = cellSelection?.anchor ?? editedCoordinate {
            cellSelection = TableCellSelection(anchor: anchor, head: coordinate)
            cellScroll?.removeFromSuperview()
            if let grid { onFocus?(grid); grid.window?.makeFirstResponder(grid) }
            grid?.needsDisplay = true
            return
        }
        cellSelection = nil
        focus(topology.identifiedRows[row].cells[column].id)
        refreshPresentation()
        if let activeCellID, let editor = editor(for: activeCellID) {
            grid?.window?.makeFirstResponder(editor)
        }
    }

    func setColumnWidth(_ width: CGFloat?, at column: Int) {
        guard topology.alignments.indices.contains(column) else { return }
        while columnWidths.count < topology.alignments.count { columnWidths.append(nil) }
        columnWidths[column] = width.map { min(MarkdownTableLayout.maximumSetColumnWidth, max(MarkdownTableLayout.minimumColumnWidth, $0)) }
        refreshPresentation()
        onColumnWidthsChange?(columnWidths)
        onChange?()
    }

    func resizeColumn(at point: NSPoint) -> Int? {
        guard let grid, let row = grid.geometry.cellRects.first else { return nil }
        return row.indices.first { abs(row[$0].maxX - point.x) <= 3 }
    }

    func trackColumnResize(_ event: NSEvent, column: Int) {
        guard let grid, let window = grid.window, let row = grid.geometry.cellRects.first,
              row.indices.contains(column) else { return }
        let start = event.locationInWindow.x
        let width = row[column].width
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            setColumnWidth(width + next.locationInWindow.x - start, at: column)
            if next.type == .leftMouseUp { break }
        }
    }

    func navigate(from cellID: UUID, backwards: Bool) -> Bool {
        let cells = topology.identifiedRows.enumerated().flatMap { row, value in
            value.cells.enumerated().map { column, cell in (cell.id, row, column) }
        }
        guard let index = cells.firstIndex(where: { $0.0 == cellID }) else { return false }
        let next = index + (backwards ? -1 : 1)
        guard cells.indices.contains(next) else { return false }
        select(row: cells[next].1, column: cells[next].2)
        return true
    }

    func refreshPresentation() {
        guard let grid else { return }
        let layout = geometry()
        grid.show(layout)
        if grid.frame.size != layout.size { grid.setFrameSize(layout.size) }
        guard let coordinate = editedCoordinate, let activeCellID,
              let editor = editor(for: activeCellID), let rect = layout.rect(of: coordinate) else {
            cellScroll?.removeFromSuperview()
            return
        }
        let scroll = cellScroll ?? NSScrollView()
        cellScroll = scroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        if scroll.documentView !== editor { scroll.documentView = editor }
        if scroll.superview !== grid { grid.addSubview(scroll) }
        scroll.frame = rect.insetBy(dx: MarkdownTableLayout.horizontalPadding,
                                    dy: MarkdownTableLayout.verticalPadding)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        if editor.frame.size != scroll.contentSize { editor.setFrameSize(scroll.contentSize) }
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        grid.needsDisplay = true
    }
}
