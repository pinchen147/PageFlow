import AppKit

/// One hover grip and native drag source per editor. The viewport index never forces layout.
final class BlockMover: NSObject, NSDraggingSource {
    struct Entry {
        let range: NSRange
        let kind: BlockMovePasteboard.Kind
        let rect: NSRect
        var grip: NSRect { NSRect(x: rect.minX - 44, y: rect.minY, width: 26, height: 26) }
        var hoverRect: NSRect { rect.union(grip) }
    }
    private weak var coordinator: NativeTextViewCoordinator?
    private weak var scroll: NSScrollView?
    private let grip = BlockGripView()
    private var entries: [Entry]?
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
        if grip.superview !== main { main.addSubview(grip, positioned: .above, relativeTo: nil) }
    }
    func invalidate() { entries = nil }

    /// Called by the table chrome's existing tracking area, sharing its hover lifecycle.
    func hover(at point: NSPoint) {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.blockGrip", since: hoverStart) }
#endif
        guard let main, let coordinator, main.isEditable, coordinator.configuration.showsSelectionBar, !isDragging else { hide(); return }
        if entries == nil || viewport != main.viewportCharacterRange || generation != coordinator.nativeSourceGeneration {
            entries = buildEntries()
            viewport = main.viewportCharacterRange
            generation = coordinator.nativeSourceGeneration
        }
        let found = entries?.first { $0.hoverRect.contains(point) }
        guard let found else { hide(); return }
        hovered = found
        grip.frame = found.grip
        grip.isHidden = false
        grip.highlighted = found.grip.contains(point)
        grip.setAccessibilityLabel("Drag to move \(found.kind.title.lowercased())")
        grip.needsDisplay = true
    }
    func hide() {
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
            result.append(Entry(range: range, kind: moveKind, rect: rect))
        }
        // The coordinator owns this snapshot and invalidates it on edits; hover never compares or parses the note.
        let codeTokens = coordinator.cachedParsedDocument?.codeTokens ?? []
        func map(_ offset: Int) -> Int {
            coordinator.plainInsertionsSinceParse.reduce(offset) { value, insertion in
                value >= insertion.location ? value + insertion.length : value
            }
        }
        func rebased(_ token: MarkdownToken) -> MarkdownToken {
            func range(_ range: NSRange) -> NSRange {
                let start = map(range.location)
                return NSRange(location: start, length: map(NSMaxRange(range)) - start)
            }
            return MarkdownToken(kind: token.kind, range: range(token.range), contentRange: range(token.contentRange), markerRanges: token.markerRanges.map(range))
        }
        var lower = 0, upper = codeTokens.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if map(NSMaxRange(codeTokens[middle].range)) <= scope.location { lower = middle + 1 } else { upper = middle }
        }
        for original in codeTokens.dropFirst(lower) {
            let token = rebased(original)
            if token.range.location >= NSMaxRange(scope) { break }
            guard token.kind == .codeBlock else { continue }
            if result.contains(where: { $0.range == token.range }) { continue }
            guard let layout = main.textLayoutManager, let content = layout.textContentManager,
                  let start = content.location(layout.documentRange.location, offsetBy: max(token.range.location, scope.location)) else { continue }
            var rect = NSRect.null
            layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
                guard let element = fragment.textElement?.elementRange else { return false }
                let offset = content.offset(from: content.documentRange.location, to: element.location)
                guard offset < NSMaxRange(token.range), offset < NSMaxRange(scope) else { return false }
                if fragment.state == .layoutAvailable { rect = rect.union(fragment.layoutFragmentFrame) }
                return true
            }
            guard !rect.isNull else { continue }
            rect.origin.x = main.textContainerOrigin.x + (main.textContainer?.lineFragmentPadding ?? 0)
            rect.origin.y += main.textContainerOrigin.y
            rect.size.width = max(1, (main.textContainer?.size.width ?? main.bounds.width) - 2 * (main.textContainer?.lineFragmentPadding ?? 0))
            let language = MarkdownTokenizer.extractLanguage(from: token, in: main.string)?.lowercased()
            result.append(Entry(range: token.range, kind: language == "mermaid" ? .diagram : .code, rect: rect))
        }
        return result.sorted { $0.rect.minY < $1.rect.minY }
    }

    func press(_ event: NSEvent, nextEvent: (() -> NSEvent?)? = nil) {
        guard let entry = hovered, let main, let window = main.window else { return }
        let start = event.locationInWindow
        let events = nextEvent ?? { window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        while let next = events() {
            if next.type == .leftMouseUp { break }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                begin(range: entry.range, kind: entry.kind, event: next, rect: entry.rect, pressPoint: start)
                return
            }
        }
        if entry.kind == .image, let storage = main.textStorage,
           let image = NativeTextViewCoordinator.renderedImage(around: entry.range, in: storage) {
            coordinator?.selectImage(image, in: main)
        } else { main.setSelectedRange(entry.range) }
    }

    func begin(range: NSRange, kind: BlockMovePasteboard.Kind, event: NSEvent, rect supplied: NSRect? = nil, pressPoint: NSPoint? = nil) {
        guard let main, let coordinator, let payload = coordinator.blockMovePayload(range: range, kind: kind) else { return }
        let item = NSPasteboardItem()
        payload.write(to: item)
        let rect = supplied ?? main.renderedImage(at: main.convert(event.locationInWindow, from: nil))?.rect
            ?? hovered?.rect ?? NSRect(x: 0, y: 0, width: 200, height: 80)
        var snapshotRect = rect
        if kind == .code { snapshotRect.size = NSSize(width: min(600, rect.width), height: min(400, rect.height)) }
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
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
