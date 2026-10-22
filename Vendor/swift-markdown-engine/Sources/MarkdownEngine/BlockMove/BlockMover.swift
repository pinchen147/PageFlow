import AppKit

/// One hover grip and native drag source per editor. The viewport index never forces layout.
final class BlockMover: NSObject, NSDraggingSource {
    struct Entry {
        let range: NSRange
        let kind: BlockMovePasteboard.Kind
        let rect: NSRect
        let grip: NSRect
        let hoverRect: NSRect
    }
    private weak var coordinator: NativeTextViewCoordinator?
    private weak var scroll: NSScrollView?
    private let grip = BlockGripView()
    private let host = PassThroughView()
    private var entries: [Entry]?
    private let dragIndex = BlockDragIndexCache()
    private var viewport: NSRange?
    private var generation = -1
    private(set) var hovered: Entry?
    private(set) var isDragging = false
    var dropSession: BlockDragSession?

    init(coordinator: NativeTextViewCoordinator) {
        self.coordinator = coordinator
        super.init()
        grip.mover = self
        grip.isHidden = true
    }
    private var main: NativeTextView? { coordinator?.textView as? NativeTextView }

    func install(in scrollView: NSScrollView) {
        scroll = scrollView
        if coordinator?.configuration.showsSelectionBar != true { hide() }
        guard let main else { return }
        positionHost(in: main)
        if grip.superview !== host { host.addSubview(grip) }
    }
    func invalidate() {
        entries = nil
        hide()
    }

    func cancelIndexPreparation() {
        dragIndex.cancel()
        invalidate()
        hide()
    }

    func prepareIndex() {
        cancelIndexPreparation()
        guard let coordinator, let snapshot = coordinator.cachedBlockParse,
              let revision = coordinator.cachedBlockParseRevision else { return }
        dragIndex.prepare(snapshot: snapshot,
                          revision: .init(source: revision.source, document: revision.document),
                          isCurrent: { [weak coordinator] in
            guard let coordinator,
                  coordinator.nativeSourceGeneration == revision.source,
                  coordinator.documentGeneration == revision.document,
                  coordinator.cachedBlockParseRevision?.source == revision.source,
                  coordinator.cachedBlockParseRevision?.document == revision.document else { return false }
            return coordinator.textView?.textStorage?.length == snapshot.characters.count
        }, onReady: { [weak self] in
            self?.invalidate()
            self?.dropSession?.generation = -1
        })
    }

    func uninstall() {
        cancelIndexPreparation()
        dropSession?.indicator.removeFromSuperview()
        dropSession = nil
        host.removeFromSuperview()
    }

    private func positionHost(in main: NativeTextView) {
        if let container = main.superview as? NativeTextViewContainer {
            container.keepAboveWideTables(host)
            if host.frame != main.frame { host.frame = main.frame }
        } else {
            if host.superview !== main { main.addSubview(host, positioned: .above, relativeTo: nil) }
            if host.frame != main.bounds { host.frame = main.bounds }
        }
    }

    /// Called by the table chrome's existing tracking area, sharing its hover lifecycle.
    func hover(at point: NSPoint) {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.blockGrip", since: hoverStart) }
#endif
        guard let main, let coordinator, main.isEditable, coordinator.configuration.showsSelectionBar, !isDragging,
              !coordinator.isUpdatingSourceOrStyle, !coordinator.isComposing(in: main), !coordinator.isWritingToolsActive else { hide(); return }
        if entries == nil || viewport != main.viewportCharacterRange || generation != coordinator.nativeSourceGeneration {
            entries = buildEntries()
            viewport = main.viewportCharacterRange
            generation = coordinator.nativeSourceGeneration
        }
        let found = entries?.first { entry in
            var region = entry.hoverRect
            if entry.kind == .heading,
               let chevron = coordinator.foldControls?.chevronFrame(for: entry.range.location) {
                region = region.union(chevron)
            }
            return region.contains(point)
        }
        guard let found else { hide(); return }
        hovered = found
        coordinator.foldControls?.setHoveredHeading(found.kind == .heading ? found.range.location : nil)
        positionHost(in: main)
        grip.frame = found.grip
        grip.isHidden = false
        grip.highlighted = found.grip.contains(point)
        grip.setAccessibilityLabel("Drag to move \(found.kind.title.lowercased())")
        grip.needsDisplay = true
    }
    /// Cursor rectangles can be superseded by the underlying text view's callbacks.
    @discardableResult
    func applyCursor(for event: NSEvent) -> Bool {
        guard let main, let coordinator, main.isEditable,
              coordinator.configuration.showsSelectionBar, !grip.isHiddenOrHasHiddenAncestor,
              generation == coordinator.nativeSourceGeneration,
              let storage = main.textStorage, currentBlocks(in: storage.mutableString) != nil,
              grip.frame.contains(main.convert(event.locationInWindow, from: nil)) else { return false }
        NSCursor.openHand.set()
        return true
    }

    func hide() {
        coordinator?.foldControls?.setHoveredHeading(nil)
        hovered = nil
        grip.isHidden = true
    }
    private func buildEntries() -> [Entry] {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.blockIndex", since: hoverStart) }
#endif
        guard let main, let coordinator, let storage = main.textStorage,
              let viewport = main.viewportCharacterRange else { return [] }
        let scope = NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))
        var result: [Entry] = []
        storage.enumerateAttribute(.markdownBlockSourceRange, in: scope) { value, anchor, _ in
            guard let value = value as? NSValue,
                  let kind = storage.attribute(.markdownBlockKind, at: anchor.location, effectiveRange: nil) as? String,
                  let rect = main.renderedImageRect(at: anchor.location) else { return }
            let moveKind: BlockMovePasteboard.Kind
            switch kind {
            case MarkdownBlockKind.image.rawValue: moveKind = .image
            case MarkdownBlockKind.math.rawValue: moveKind = .equation
            case MarkdownBlockKind.diagram.rawValue: moveKind = .diagram
            default: return
            }
            let range = AnchorRelativeRange.decode(value, anchorLocation: anchor.location)
            guard coordinator.foldLayout.hiddenRange(containing: range.location) == nil else { return }
            let row = moveKind == .diagram ? columnRect(for: rect, main: main).union(rect) : rect
            if let entry = entry(range: range, kind: moveKind, rect: rect, row: row) { result.append(entry) }
        }
        let text = storage.mutableString
        // A slot parser may stop inside a long container. Only a current,
        // complete canonical index can authorize a movable source range.
        guard let blocks = currentBlocks(in: text) else { return [] }
        result.removeAll { object in
            var low = 0, high = blocks.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(blocks[middle].range) <= object.range.location { low = middle + 1 }
                else { high = middle }
            }
            guard low < blocks.count else { return false }
            let block = blocks[low]
            return (block.kind == .list || block.kind == .blockquote)
                && NSIntersectionRange(block.range, object.range) == object.range
        }
        var lower = 0, upper = blocks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if NSMaxRange(blocks[middle].range) <= scope.location { lower = middle + 1 } else { upper = middle }
        }
        for block in blocks.dropFirst(lower) {
            if block.range.location >= NSMaxRange(scope) { break }
            guard block.kind != .blank, block.kind != .table,
                  coordinator.foldLayout.hiddenRange(containing: block.range.location) == nil else { continue }
            let end = NativeTextViewCoordinator.contentEnd(of: block.range, in: text)
            let headingSection = block.kind == .heading
                ? coordinator.foldSession.collapsedSection(at: block.range.location, in: text) : nil
            let range = headingSection ?? NSRange(location: block.range.location, length: end - block.range.location)
            guard range.length > 0, !result.contains(where: { $0.range == range }),
                  let geometry = layoutGeometry(for: block.range, in: scope, main: main) else { continue }
            let kind: BlockMovePasteboard.Kind
            switch block.kind {
            case .paragraph: kind = .paragraph
            case .heading: kind = .heading
            case .blockquote: kind = .quote
            case .list: kind = .list
            case .thematicBreak: kind = .divider
            case .blockLatex: kind = .equation
            case .fencedCode:
                let opening = text.substring(with: text.lineRange(for: NSRange(location: range.location, length: 0))) as NSString
                let language = FencedCode.scan(in: opening, range: NSRange(location: 0, length: opening.length))?.language(in: opening)
                kind = language?.lowercased() == "mermaid" ? .diagram : .code
            case .table, .blank: continue
            }
            if let entry = entry(range: range, kind: kind, rect: geometry.rect,
                                 centerY: kind == .heading ? geometry.firstLineCenterY : nil) { result.append(entry) }
        }
        // Rendered objects retain priority inside a prose paragraph. Otherwise
        // the paragraph's larger rectangle would swallow the existing image grip.
        return result
    }

    func currentBlocks(in text: NSString) -> [Block]? {
        guard let coordinator, let main, !coordinator.isUpdatingSourceOrStyle,
              !coordinator.isComposing(in: main), !coordinator.isWritingToolsActive,
              let snapshot = coordinator.cachedBlockParse, snapshot.characters.count == text.length,
              let revision = coordinator.cachedBlockParseRevision,
              revision.source == coordinator.nativeSourceGeneration,
              revision.document == coordinator.documentGeneration else { return nil }
        return dragIndex.blocks(for: .init(source: revision.source, document: revision.document))
    }

    private func layoutGeometry(for range: NSRange, in scope: NSRange, main: NativeTextView)
        -> (rect: NSRect, firstLineCenterY: CGFloat?)? {
        guard let layout = main.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(layout.documentRange.location, offsetBy: max(range.location, scope.location)) else { return nil }
        var rect = NSRect.null
        var firstLineCenterY: CGFloat?
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard let element = fragment.textElement?.elementRange else { return false }
            let offset = content.offset(from: content.documentRange.location, to: element.location)
            guard offset < NSMaxRange(range), offset < NSMaxRange(scope) else { return false }
            if fragment.state == .layoutAvailable {
                if firstLineCenterY == nil, let line = fragment.textLineFragments.first {
                    firstLineCenterY = main.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
                }
                rect = rect.union(fragment.layoutFragmentFrame)
            }
            return true
        }
        guard !rect.isNull else { return nil }
        rect.origin.y += main.textContainerOrigin.y
        return (columnRect(for: rect, main: main), firstLineCenterY)
    }

    private func columnRect(for rect: NSRect, main: NativeTextView) -> NSRect {
        var row = rect
        let padding = main.textContainer?.lineFragmentPadding ?? 0
        row.origin.x = main.textContainerOrigin.x + padding
        row.size.width = max(1, (main.textContainer?.size.width ?? main.bounds.width) - 2 * padding)
        return row
    }

    private func entry(range: NSRange, kind: BlockMovePasteboard.Kind, rect: NSRect,
                       row: NSRect? = nil, centerY: CGFloat? = nil) -> Entry? {
        // Centered diagrams use the document gutter; their preview keeps the image bounds.
        let row = row ?? rect
        let visible = scroll.flatMap { scroll in main.map { scroll.contentView.convert(scroll.contentView.bounds, to: $0) } }
            ?? main?.visibleRect ?? rect
        var rightEdge = visible.maxX
        // Overlay scrollers stay above document subviews and can steal a drag
        // even while fading. Their strip is unavailable to grip hit targets.
        if let main, let scroll, scroll.hasVerticalScroller, let scroller = scroll.verticalScroller {
            let strip = scroller.convert(scroller.bounds, to: main)
            if strip.width > 0, strip.height > 0, strip.minX > visible.midX {
                rightEdge = min(rightEdge, strip.minX)
            }
        }
        var x = max(row.minX - (kind == .heading ? 62 : 44), visible.minX)
        // Keep the heading fold button separate. If panning has hidden both
        // gutters, omit this grip until space is visible instead of covering ink.
        let leftLimit = row.minX - (kind == .heading ? 36 : 0)
        if x + 26 > leftLimit { x = max(row.maxX + 4, visible.minX) }
        guard x + 26 <= rightEdge,
              x + 26 <= leftLimit || x >= row.maxX + 4 else { return nil }
        // Headings follow their chevron even when its first line is partly clipped.
        let y = centerY.map { $0 - 13 } ?? max(row.minY, visible.minY)
        let grip = NSRect(x: x, y: y, width: 26, height: 26)
        return Entry(range: range, kind: kind, rect: rect, grip: grip, hoverRect: row.union(rect).union(grip))
    }

    func press(_ event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) {
        guard let entry = hovered, let main, let coordinator, let storage = main.textStorage,
              main.isEditable, coordinator.configuration.showsSelectionBar,
              generation == coordinator.nativeSourceGeneration,
              currentBlocks(in: storage.mutableString) != nil,
              let window = main.window else { hide(); return }
        let pressedGeneration = coordinator.nativeSourceGeneration
        let pressedDocument = coordinator.documentGeneration
        let start = event.locationInWindow
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        while let next = events() {
            // Native event tracking can run source callbacks before the pointer moves.
            // A payload built at an old range would otherwise hash the replacement bytes.
            guard coordinator.nativeSourceGeneration == pressedGeneration,
                  coordinator.documentGeneration == pressedDocument,
                  currentBlocks(in: storage.mutableString) != nil else { hide(); return }
            if next.type == .leftMouseUp { break }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                begin(range: entry.range, kind: entry.kind, event: next, rect: entry.rect, pressPoint: start)
                return
            }
        }
        guard coordinator.nativeSourceGeneration == pressedGeneration,
              coordinator.documentGeneration == pressedDocument,
              currentBlocks(in: storage.mutableString) != nil else { hide(); return }
        if entry.kind == .image, let storage = main.textStorage,
           let image = NativeTextViewCoordinator.renderedImage(around: entry.range, in: storage) {
            coordinator.selectImage(image, in: main)
        } else { main.setSelectedRange(entry.range) }
    }

    func begin(range: NSRange, kind: BlockMovePasteboard.Kind, event: NSEvent, rect supplied: NSRect? = nil, pressPoint: NSPoint? = nil) {
        guard let main, let coordinator, let payload = coordinator.blockMovePayload(range: range, kind: kind) else { return }
        let item = NSPasteboardItem()
        payload.write(to: item)
        let rect = supplied ?? main.renderedImage(at: main.convert(event.locationInWindow, from: nil))?.rect
            ?? hovered?.rect ?? NSRect(x: 0, y: 0, width: 200, height: 80)
        var snapshotRect = rect.intersection(main.visibleRect)
        if snapshotRect.isNull || snapshotRect.isEmpty { snapshotRect = rect }
        snapshotRect.size = NSSize(width: min(600, snapshotRect.width), height: min(400, snapshotRect.height))
        let image = NSImage(size: snapshotRect.size)
        if let rep = main.bitmapImageRepForCachingDisplay(in: snapshotRect) {
            main.cacheDisplay(in: snapshotRect, to: rep)
            image.lockFocus()
            NSImage(size: snapshotRect.size, flipped: false) { target in rep.draw(in: target); return true }.draw(in: NSRect(origin: .zero, size: snapshotRect.size),
                                                                       from: .zero, operation: .sourceOver, fraction: 0.6)
            image.unlockFocus()
        }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        var draggingFrame = snapshotRect
        let pointer = main.convert(event.locationInWindow, from: nil)
        if kind == .table {
            draggingFrame.origin = NSPoint(x: pointer.x - 24, y: pointer.y - 24)
        } else if let pressPoint {
            let press = main.convert(pressPoint, from: nil)
            draggingFrame.origin.x += pointer.x - press.x
            draggingFrame.origin.y += pointer.y - press.y
        }
        dragging.setDraggingFrame(draggingFrame, contents: image)
        isDragging = true
        coordinator.imageControls?.isBlockDragging = true
        coordinator.tableChrome?.remove()
        hide()
        coordinator.selectionBar?.isDragSelecting = true
        coordinator.selectionBar?.update()
        coordinator.imageChrome?.ring.isHidden = true
        main.beginDraggingSession(with: [dragging], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        coordinator?.imageControls?.isBlockDragging = false
        main?.hideTableDropIndicator()
        invalidate()
        coordinator?.selectionBar?.isDragSelecting = false
        coordinator?.selectionBar?.setNeedsUpdate()
        coordinator?.imageChrome?.selectionDidChange(from: nil)
    }
}

private final class BlockGripView: NSView {
    weak var mover: BlockMover?
    var highlighted = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func cursorUpdate(with event: NSEvent) {
        if mover?.applyCursor(for: event) != true { super.cursorUpdate(with: event) }
    }
    override func mouseDown(with event: NSEvent) { mover?.press(event) }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        NSColor.secondaryLabelColor.setFill()
        for x in [-2.0, 2.0] {
            for y in [-4.0, 0.0, 4.0] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 0.75, y: bounds.midY + y - 0.75, width: 1.5, height: 1.5)).fill()
            }
        }
    }
}
