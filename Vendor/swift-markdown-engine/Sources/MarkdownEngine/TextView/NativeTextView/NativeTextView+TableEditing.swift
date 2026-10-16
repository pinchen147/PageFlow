import AppKit

extension NativeTextView {
    /// The table image anchored at `anchor`: its source range and the exact rect
    /// its layout fragment draws, in view coordinates. Wide tables draw in their
    /// own overlay instead and are excluded.
    private func tableImage(at anchor: Int) -> (range: NSRange, rect: NSRect)? {
        guard let storage = textStorage, anchor >= 0, anchor < storage.length,
              let value = storage.attribute(.markdownTableSourceRange, at: anchor, effectiveRange: nil) as? NSValue,
              storage.attribute(.scrollableBlockSourceID, at: anchor, effectiveRange: nil) == nil,
              let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(layout.documentRange.location, offsetBy: anchor),
              let fragment = layout.textLayoutFragment(for: location) as? MarkdownTextLayoutFragment,
              fragment.state == .layoutAvailable,
              let frame = fragment.blockImageFrame(at: anchor) else { return nil }
        let rect = frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return (AnchorRelativeRange.decode(value, anchorLocation: anchor), rect)
    }

    /// The rect a narrow table's image draws in, in view coordinates.
    func tableImageRect(at anchor: Int) -> NSRect? { tableImage(at: anchor)?.rect }

    /// `raster` with the document selection painted on the cells it covers
    /// (doc 24 §7.5.7), or nil when the selection does not reach into the
    /// table or a cell editor owns it.
    func selectionPaintedTable(_ raster: NSImage, tableRange: NSRange) -> NSImage? {
        let selection = selectedRange()
        guard selection.length > 0, NSIntersectionRange(selection, tableRange).length > 0,
              let storage = textStorage, NSMaxRange(tableRange) <= storage.length,
              (delegate as? NativeTextViewCoordinator)?.tableEditingSession.owns(tableRange) != true,
              let table = MarkdownTableSource(source: storage.string, range: tableRange) else { return nil }
        let cells = table.cells(coveredBy: selection)
        guard !cells.isEmpty else { return nil }
        // TextKit greys the band around the table when this view is not the key
        // window's first responder, and keeps the selected text's colour.
        let emphasized = window?.isKeyWindow == true && window?.firstResponder === self
        let attributes = selectedTextAttributes
        var paint = MarkdownTableLayout.SelectionPaint(
            cells: cells,
            background: emphasized ? attributes[.backgroundColor] as? NSColor ?? .selectedTextBackgroundColor
                : .unemphasizedSelectedTextBackgroundColor,
            text: attributes[.foregroundColor] as? NSColor
        )
        // Resolved once, so the variant cache keys on concrete colours.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paint.background = paint.background.usingColorSpace(.sRGB) ?? paint.background
            paint.text = paint.text.map { $0.usingColorSpace(.sRGB) ?? $0 }
        }
        return MarkdownTableLayout.image(painting: paint, of: raster)
    }

    /// Wide tables draw outside TextKit: repaint those the selection reached
    /// into before this change or reaches into now.
    func selectionDidChangeForWideTables() {
        let selection = selectedRange()
        let previous = wideTableSelection
        wideTableSelection = selection
        guard !wideTableOverlays.isEmpty, previous.length > 0 || selection.length > 0 else { return }
        for overlay in wideTableOverlays.values
        where NSIntersectionRange(overlay.sourceRange, selection).length > 0
            || NSIntersectionRange(overlay.sourceRange, previous).length > 0 {
            overlay.documentView?.needsDisplay = true
        }
    }

    /// Repaint the tables the document selection reaches into, whose covered
    /// cells follow the selection's active or inactive colour as the band does.
    func redisplayTablesUnderSelection() {
        let selection = selectedRange()
        guard selection.length > 0, let coordinator = delegate as? NativeTextViewCoordinator else { return }
        let visible = visibleRect
        for token in coordinator.parsedDocument(for: string).tokens
        where token.kind == .table && NSIntersectionRange(token.range, selection).length > 0 {
            guard let rect = tableImageRect(at: token.range.location), rect.intersects(visible) else { continue }
            // TextKit draws each layout fragment in its own view under this one.
            func mark(_ view: NSView) {
                for child in view.subviews where convert(child.bounds, from: child).intersects(rect) {
                    child.needsDisplay = true
                    mark(child)
                }
            }
            mark(self)
        }
        for overlay in wideTableOverlays.values where NSIntersectionRange(overlay.sourceRange, selection).length > 0 {
            overlay.documentView?.needsDisplay = true
        }
    }

    /// Where the table at `range` is presented now: a narrow table on its image
    /// in this view, a wide one in its overlay's canvas. Nil while it is laid out nowhere.
    func tableCanvas(forTableAt range: NSRange) -> (view: NSView, origin: NSPoint)? {
        if let overlay = wideTableOverlays.values.first(where: { $0.sourceRange.location == range.location && !$0.isHidden }),
           let canvas = overlay.documentView {
            return (canvas, .zero)
        }
        guard let storage = textStorage, range.location < storage.length,
              storage.attribute(.markdownTableSourceRange, at: range.location, effectiveRange: nil) != nil,
              let image = tableImage(at: range.location), image.range.location == range.location else { return nil }
        return (self, image.rect.origin)
    }

    /// `rect` in a table's own top-down coordinates (`MarkdownTableLayout`'s
    /// cells) in this view's: a wide table's image view is not flipped.
    func convertTableRect(_ rect: NSRect, canvas: (view: NSView, origin: NSPoint)) -> NSRect {
        var local = rect.offsetBy(dx: canvas.origin.x, dy: canvas.origin.y)
        if !canvas.view.isFlipped { local.origin.y = canvas.view.bounds.height - local.maxY }
        return canvas.view.convert(local, to: self)
    }

    /// The table half of a mouse-down: finish the focused cell's input, then
    /// either focus the rendered table cell under the pointer or end cell
    /// editing. Returns whether a table consumed the click. Shift-click from
    /// prose extends the text selection across tables, which stay rendered.
    func routeMouseDownToTables(_ event: NSEvent) -> Bool {
        guard let session = (delegate as? NativeTextViewCoordinator)?.tableEditingSession else { return false }
        session.finishInput()
        if event.modifierFlags.contains(.shift), !session.isActive { return false }
        if editTableIfHit(event) {
            if event.clickCount >= 2 {
                session.selectText(at: event.locationInWindow, clickCount: event.clickCount)
            } else if event.type == .leftMouseDown {
                // A drag from here selects text in the cell, or a range across cells.
                session.trackSelection(from: event)
            }
            return true
        }
        session.retire()
        return false
    }

    /// Begin cell editing when `event` lands on a rendered narrow table.
    private func editTableIfHit(_ event: NSEvent) -> Bool {
        guard let coordinator = delegate as? NativeTextViewCoordinator,
              let storage = textStorage, let viewport = viewportCharacterRange else { return false }
        let point = convert(event.locationInWindow, from: nil)
        var hit: (range: NSRange, rect: NSRect)?
        storage.enumerateAttribute(.markdownTableSourceRange, in: NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))) { value, range, stop in
            guard value != nil, let image = tableImage(at: range.location), image.rect.contains(point) else { return }
            hit = image
            stop.pointee = true
        }
        guard let hit else { return false }
        return coordinator.tableEditingSession.begin(
            range: hit.range, point: NSPoint(x: point.x - hit.rect.minX, y: point.y - hit.rect.minY),
            in: self, origin: hit.rect.origin
        )
    }

    /// Keep an active narrow-table grid on its drawn image after layout moves it.
    func refreshInlineTableEditor() {
        guard let coordinator = delegate as? NativeTextViewCoordinator,
              let table = coordinator.tableEditingSession.table, let storage = textStorage,
              let viewport = viewportCharacterRange else { return }
        var positioned = false
        let range = NSIntersectionRange(table.range, NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.markdownTableSourceRange, in: range) { value, anchor, stop in
            guard value != nil, NSLocationInRange(anchor.location, viewport), let image = tableImage(at: anchor.location) else { return }
            coordinator.tableEditingSession.mount(in: self, range: image.range, origin: image.rect.origin)
            positioned = true
            stop.pointee = true
        }
        if !positioned, !wideTableOverlays.values.contains(where: { $0.sourceRange.location == table.range.location && !$0.isHidden }) {
            coordinator.tableEditingSession.detachPresentation()
        }
    }
}
