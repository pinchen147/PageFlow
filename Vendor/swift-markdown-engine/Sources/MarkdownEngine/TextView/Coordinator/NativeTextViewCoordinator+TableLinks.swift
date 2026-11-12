import AppKit

/// Where a link drawn in a table cell goes.
enum TableLinkTarget: Equatable {
    /// A Markdown link, autolink or bare URL.
    case url(URL)
    /// A `[[wiki-link]]`: its target, the text before any `|alias`.
    case wikiLink(String)
}

/// Links drawn in table cells (PR D): a pointing hand over a link's text, and
/// ⌘-click opens it. A plain click still edits the cell; in a read-only note,
/// where nothing edits, a plain click opens it as a link in prose does.
extension NativeTextViewCoordinator {
    /// How web and mail links open (tests replace it).
    nonisolated(unsafe) static var openWebLink: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The link drawn under `windowPoint` in a table: the focused grid's cells
    /// (not the one its editor covers), a wide table's overlay, or a narrow
    /// table's image.
    func tableLink(atWindowPoint windowPoint: NSPoint) -> TableLinkTarget? {
        guard let main = textView as? NativeTextView, !isUpdatingSourceOrStyle else { return nil }
        let session = tableEditingSession
        if let grid = session.grid, grid.window != nil {
            let local = grid.convert(windowPoint, from: nil)
            if grid.visibleRect.contains(local) {
                return grid.geometry.link(at: local, omitting: session.isRangeMode ? nil : CellCoord(row: session.row, column: session.column))
            }
        }
        for overlay in main.wideTableOverlays.values where !overlay.isHidden && overlay.window != nil {
            guard overlay.bounds.contains(overlay.convert(windowPoint, from: nil)),
                  let canvas = overlay.documentView as? WideTableImageView, let image = canvas.image,
                  let layout = MarkdownTableLayout.layout(ofRaster: image) else { continue }
            let local = canvas.convert(windowPoint, from: nil)
            return layout.link(at: NSPoint(x: local.x, y: canvas.isFlipped ? local.y : canvas.bounds.height - local.y))
        }
        let point = main.convert(windowPoint, from: nil)
        guard let hit = main.renderedTable(at: point), hit.rect.width > 0, hit.rect.height > 0 else { return nil }
        let image = main.textStorage?.attribute(.renderedBlockImage, at: hit.anchor, effectiveRange: nil) as? NSImage
        guard let layout = image.flatMap(MarkdownTableLayout.layout(ofRaster:)) ?? session.geometry(forTableAt: hit.range) else { return nil }
        return layout.link(at: NSPoint(x: (point.x - hit.rect.minX) * layout.size.width / hit.rect.width,
                                       y: (point.y - hit.rect.minY) * layout.size.height / hit.rect.height))
    }

    /// A pointing hand over a cell's link. True when it set the cursor.
    func applyTableLinkCursor(for event: NSEvent) -> Bool {
        guard tableLink(atWindowPoint: event.locationInWindow) != nil else { return false }
        NSCursor.pointingHand.set()
        return true
    }

    /// Opens the link under a ⌘-click (or, read-only, any click) in a table.
    /// True when the click opened one and nothing else may handle it.
    func openTableLink(for event: NSEvent, editable: Bool) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.contains(.command) || !editable,
              !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.control),
              let target = tableLink(atWindowPoint: event.locationInWindow) else { return false }
        openTableLink(target)
        return true
    }

    /// A URL opens as below; a wiki-link goes to the host's wiki-link
    /// handler, as one clicked in prose does.
    func openTableLink(_ target: TableLinkTarget) {
        switch target {
        case .url(let url): openTableLink(url)
        case .wikiLink(let name): openWikiLink(name)
        }
    }

    /// Web and mail links open in their app; a local one goes to the host,
    /// which scope-checks it; any other scheme is refused (as in prose).
    func openTableLink(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            Self.openWebLink(url)
        } else if scheme == nil || scheme == "file", let open = onOpenLocalLink {
            DispatchQueue.main.async { open(url) }
        }
    }
}
