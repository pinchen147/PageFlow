import AppKit

/// Owns transient image UI. Character edits happen only through ImageCommands.
final class ImageControlsController {
    weak var coordinator: NativeTextViewCoordinator?
    weak var textView: NativeTextView?
    weak var scrollView: NSScrollView?
    private let bars = ImageResizeBars(frame: .zero)
    private let accessibilityGroup = ImageResizeAccessibilityView(frame: .zero)
    /// A separate, nonpainting group keeps keyboard access independent of hover chrome.
    var resizeAccessibilityGroup: NSView { accessibilityGroup }
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var isProcessingStorageEdit = false
    private var index: [(ObjectSelection, NSRect)] = []
    private var hover: (ObjectSelection, NSRect)?
    private var lastHoverPoint: NSPoint?
    private var menu: ChromeMenuView?
    private var sizeMenu: TableMenuView?
    private(set) var cropView: ImageCropView?
    private(set) var altPopover: ImageAltTextPopover?
    private(set) var isResizing = false
    var isBlockDragging = false { didSet { refresh() } }
    var isInteracting: Bool { cropView != nil || altPopover != nil || sizeMenu != nil || isResizing || isBlockDragging || coordinator?.blockMover.isDragging == true }

    init(coordinator: NativeTextViewCoordinator, textView: NativeTextView, scrollView: NSScrollView) {
        self.coordinator = coordinator; self.textView = textView; self.scrollView = scrollView
        bars.isHidden = true
        textView.addSubview(bars)
        accessibilityGroup.isHidden = true
        textView.addSubview(accessibilityGroup)
        accessibilityGroup.onAdjust = { [weak self] delta in self?.adjustWidth(by: delta) ?? false }
        let center = NotificationCenter.default
        for (name, object) in [(NSView.boundsDidChangeNotification, scrollView.contentView as AnyObject),
                                (NSView.frameDidChangeNotification, scrollView as AnyObject),
                                (NSTextStorage.didProcessEditingNotification, textView.textStorage as AnyObject)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSTextStorage.didProcessEditingNotification,
                       let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) {
                        self.isProcessingStorageEdit = true
                        self.cancel()
                        self.isProcessingStorageEdit = false
                    }
                    self.setNeedsRefresh()
                }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self, let main = self.textView, event.window === main.window else { return event }
#if DEBUG
            let hoverStart = CFAbsoluteTimeGetCurrent()
            defer { PerfTrace.add("hover.imageMonitor", since: hoverStart) }
#endif
            self.updateHover(main.convert(event.locationInWindow, from: nil))
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.refreshScheduled = false; self.refresh()
        }
    }

    func uninstall() {
        cancel(); menu?.close(restoreFocus: false); sizeMenu?.close(.dismissed)
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        bars.removeFromSuperview()
        accessibilityGroup.removeFromSuperview()
    }

    func refresh() {
        if cropView != nil, coordinator?.objectSelection == nil { cancel() }
        if textView?.isEditable == false { cancel(); bars.isHidden = true; accessibilityGroup.isHidden = true; return }
        guard let main = textView, let storage = main.textStorage, let viewport = main.viewportCharacterRange else {
            accessibilityGroup.isHidden = true; return
        }
        index = []
        lastHoverPoint = nil
        let range = NSIntersectionRange(viewport, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.markdownBlockSourceRange, in: range) { value, at, _ in
            guard let value = value as? NSValue,
                  storage.attribute(.markdownBlockKind, at: at.location, effectiveRange: nil) as? String == MarkdownBlockKind.image.rawValue,
                  let rect = main.renderedImageRect(at: at.location) else { return }
            index.append((ObjectSelection(token: AnchorRelativeRange.decode(value, anchorLocation: at.location), anchor: at.location), rect))
        }
        if let cropView { cropView.reposition() }
        if isResizing { accessibilityGroup.isHidden = true; return }
        if !isInteracting, menu == nil, let selected = coordinator?.objectSelection,
           let rect = main.renderedImageRect(at: selected.anchor), rect.intersects(main.visibleRect), let window = main.window {
            if accessibilityGroup.frame != rect { accessibilityGroup.frame = rect }
            accessibilityGroup.update(width: rect.width, screenRect: window.convertToScreen(main.convert(rect, to: nil)))
            accessibilityGroup.isHidden = false
        } else { accessibilityGroup.isHidden = true }
        guard let window = main.window else { bars.isHidden = true; return }
        updateHover(main.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHover(_ point: NSPoint) {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.imageUpdate", since: hoverStart) }
#endif
        guard let main = textView, main.isEditable, !isInteracting, menu == nil else {
            hover = nil; lastHoverPoint = nil
            if !bars.isHidden { bars.isHidden = true }
            return
        }
        // The local monitor and the native cursor route see the same event.
        // Geometry changes invalidate this receipt when the visible index refreshes.
        guard lastHoverPoint != point else { return }
        lastHoverPoint = point
        let wasHovering = hover != nil
        hover = index.first { $0.1.insetBy(dx: -22, dy: 0).contains(point) }
        guard let (_, rect) = hover else {
            if wasHovering, !bars.isHidden {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { bars.isHidden = true; return }
                NSAnimationContext.runAnimationGroup { context in context.duration = 0.2; bars.animator().alphaValue = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.hover == nil else { return }; self.bars.isHidden = true
                }
            }
            return
        }
        let frame = rect.insetBy(dx: -12, dy: 0)
        let imageRect = NSRect(x: 12, y: 0, width: rect.width, height: rect.height)
        var geometryChanged = false
        if bars.frame != frame { bars.frame = frame; geometryChanged = true }
        if bars.imageRect != imageRect { bars.imageRect = imageRect; geometryChanged = true }
        if bars.isHidden { bars.isHidden = false }
        if bars.alphaValue != 1 { bars.alphaValue = 1 }
        if geometryChanged { bars.needsDisplay = true }
    }

    @discardableResult
    func applyCursor(at point: NSPoint) -> Bool {
#if DEBUG
        let hoverStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("hover.imageCursor", since: hoverStart) }
#endif
        updateHover(point)
        guard textView?.isEditable == true, !isInteracting, menu == nil else { return false }
        // Resize press zones overlap the body, so they always take precedence.
        if let hit = index.first(where: { resizeHit(point, rect: $0.1) != nil }) {
            if NSRect(x: hit.1.maxX - 20, y: hit.1.maxY - 20, width: 20, height: 20).contains(point), #available(macOS 15.0, *) {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
            } else { NSCursor.resizeLeftRight.set() }
            return true
        }
        if let (_, rect) = hover, rect.contains(point) {
            NSCursor.arrow.set()
            return true
        }
        return false
    }

    private func resizeHit(_ point: NSPoint, rect: NSRect) -> Bool? {
        if NSRect(x: rect.maxX - 20, y: rect.maxY - 20, width: 20, height: 20).contains(point) { return false }
        guard abs(point.y - rect.midY) <= 40 else { return nil }
        if abs(point.x - (rect.minX - 6)) <= 16 { return true }
        if abs(point.x - (rect.maxX + 6)) <= 16 { return false }
        return nil
    }

    func routeResizeMouseDown(_ event: NSEvent, nextEvent: (() -> NSEvent?)?) -> Bool {
        guard !isInteracting, menu == nil, let main = textView, main.isEditable, let coordinator, let window = main.window else { return false }
        let point = main.convert(event.locationInWindow, from: nil)
        guard let hit = index.first(where: { resizeHit(point, rect: $0.1) != nil }), let left = resizeHit(point, rect: hit.1),
              let storage = main.textStorage else { return false }
#if DEBUG
        let resizeSetupStart = CFAbsoluteTimeGetCurrent()
#endif
        guard let target = coordinator.imageTarget(for: hit.0) else { return false }
        let source = main.string
        let generation = coordinator.nativeSourceGeneration
        let anchor = hit.0.anchor
        let original = storage.attributes(at: anchor, effectiveRange: nil)
        let line = (source as NSString).paragraphRange(for: hit.0.token)
        let paragraph = storage.attribute(.paragraphStyle, at: anchor, effectiveRange: nil) as? NSParagraphStyle
        let oldKern = (original[.kern] as? NSNumber)?.doubleValue ?? 0
        let start = hit.1.width
        var width = start
        var cancelled = false
        isResizing = true; bars.dragging = true; coordinator.selectionBar?.update()
#if DEBUG
        PerfTrace.add("image.resize.setup", since: resizeSetupStart)
#endif
        let events = nextEvent ?? {
#if DEBUG
            let waitStart = CFAbsoluteTimeGetCurrent()
            defer { PerfTrace.add("image.resize.eventWait", since: waitStart) }
#endif
            return window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown])
        }
        while let next = events() {
            if coordinator.nativeSourceGeneration != generation { cancelled = true; break }
            if next.type == .keyDown {
                if next.keyCode == 53 { cancelled = true; break }
                continue
            }
            if next.type == .leftMouseUp { break }
#if DEBUG
            let resizePreviewStart = CFAbsoluteTimeGetCurrent()
#endif
            let dx = main.convert(next.locationInWindow, from: nil).x - point.x
            width = ImageResizeGeometry.width(start: start, travel: dx, left: left, alignment: target.tokens.alignment, column: coordinator.imageColumnWidth)
            let height = hit.1.height * width / start
            main.preservingViewportAnchor {
                storage.beginEditing()
                storage.addAttribute(.latexBounds, value: NSValue(rect: CGRect(x: 0, y: 0, width: width, height: height)), range: NSRange(location: anchor, length: 1))
                storage.addAttribute(.kern, value: oldKern + Double(width - start), range: NSRange(location: anchor, length: 1))
                if let style = paragraph?.mutableCopy() as? NSMutableParagraphStyle {
                    style.minimumLineHeight = height; style.maximumLineHeight = height
                    storage.addAttribute(.paragraphStyle, value: style, range: line)
                }
                storage.endEditing()
            }
            if let rect = main.renderedImageRect(at: anchor) {
                bars.frame = rect.insetBy(dx: -12, dy: 0); bars.imageRect = NSRect(x: 12, y: 0, width: rect.width, height: rect.height)
                bars.needsDisplay = true
            }
#if DEBUG
            PerfTrace.add("image.resize.preview", since: resizePreviewStart)
#endif
        }
        if coordinator.nativeSourceGeneration == generation {
#if DEBUG
            let resizeRestoreStart = CFAbsoluteTimeGetCurrent()
#endif
            main.preservingViewportAnchor {
                storage.beginEditing()
                storage.setAttributes(original, range: NSRange(location: anchor, length: 1))
                if let paragraph { storage.addAttribute(.paragraphStyle, value: paragraph, range: line) }
                storage.endEditing()
            }
#if DEBUG
            PerfTrace.add("image.resize.restore", since: resizeRestoreStart)
            let resizeCommitStart = CFAbsoluteTimeGetCurrent()
#endif
            if !cancelled, width.rounded() != start.rounded() {
                coordinator.setImageWidth(width, for: target, actionName: "Resize Image", preservingSelection: true)
            }
#if DEBUG
            PerfTrace.add("image.resize.commit", since: resizeCommitStart)
#endif
        }
#if DEBUG
        let resizeRefreshStart = CFAbsoluteTimeGetCurrent()
#endif
        isResizing = false; bars.dragging = false; coordinator.selectionBar?.update(); refresh()
#if DEBUG
        PerfTrace.add("image.resize.refresh", since: resizeRefreshStart)
#endif
        return true
    }

    func showMenu(from button: NSView) {
        guard let coordinator, let main = textView, main.isEditable, let scrollView, let target = coordinator.selectedImageTarget() else { return }
        var rows: [ChromeMenuView.Row] = []
        if coordinator.configuration.services.images.image(for: target.request) != nil {
            rows.append(.init(title: "Copy image", action: { [weak coordinator] in coordinator?.copySelectedImage() }))
        }
        if !target.isEmbed { rows.append(.init(title: "Edit alt text", action: { [weak self] in self?.beginAltText() })) }
        rows.append(.init(title: "Set image size", action: { [weak self, weak button] in if let button { self?.showSizeMenu(from: button) } }))
        rows.append(.separator)
        rows.append(.init(title: "Delete image", isDanger: true, action: { [weak coordinator, weak main] in
            guard let coordinator, let main, let object = coordinator.objectSelection else { return }; coordinator.deleteImage(object, in: main)
        }))
        coordinator.selectionBar?.isMenuOpen = true
        (button as? SelectionBarButton)?.isMenuOpen = true
        menu = ChromeMenuView.present(rows, below: button, in: scrollView) { [weak self, weak button] in
            self?.menu = nil
            (button as? SelectionBarButton)?.isMenuOpen = false
            self?.coordinator?.selectionBar?.isMenuOpen = false
            self?.coordinator?.selectionBar?.update(); self?.refresh()
        }
        menu?.setAccessibilityLabel("More actions")
        coordinator.selectionBar?.update(); bars.isHidden = true; accessibilityGroup.isHidden = true
    }

    private func showSizeMenu(from button: NSView) {
        guard let coordinator, let scrollView, let main = textView, let target = coordinator.selectedImageTarget() else { return }
        let base = coordinator.configuration.readingWidth ?? 900
        let names = ["Small", "Medium", "Large", "Extra large"]
        let widths = [base / 3, base / 2, base * 0.75, base].map { min($0.rounded(), coordinator.imageColumnWidth) }
        let rows = zip(names, widths).map { name, width in
            TableMenuView.Item(name, symbol: nil, checked: target.tokens.width.map { abs($0 - width) <= 1 } ?? false) { [weak coordinator] in
                coordinator?.setImageWidth(width, actionName: "Set Image Size")
                MarkdownTableEditingSession.announce("Image size set to \(name)")
            }
        }
        var anchor = button.convert(button.bounds, to: scrollView)
        if !scrollView.isFlipped { anchor.origin.y = scrollView.bounds.height - anchor.maxY }
        sizeMenu = TableMenuView.present(rows, family: .object, label: "Image size", placement: .below(anchor, rightAligned: false), in: scrollView, fromKeyboard: false, returningFocusTo: main) { [weak self] _ in
            self?.sizeMenu = nil; self?.coordinator?.selectionBar?.update(); self?.refresh()
        }
        coordinator.selectionBar?.update()
    }

    func beginAltText() {
        guard let coordinator, let target = coordinator.selectedImageTarget(), !target.isEmbed,
              let main = textView, main.isEditable, let object = coordinator.objectSelection,
              let rect = main.renderedImageRect(at: object.anchor), let scrollView else { return }
        let source = (main.string as NSString).substring(with: object.token)
        let view = ImageAltTextPopover(text: target.tokens.displayDescription)
        altPopover = view
        view.onSave = { [weak self] text in
            guard let self, let coordinator = self.coordinator, let current = coordinator.selectedImageTarget(),
                  (self.textView?.string as NSString?)?.substring(with: current.token.range) == source else {
                MarkdownTableEditingSession.announce("Couldn't save alt text. The image was deleted."); return
            }
            coordinator.setImageDescription(text)
        }
        view.onClose = { [weak self] in self?.altPopover = nil; self?.transientDidClose() }
        view.present(in: scrollView, imageRect: scrollView.convert(rect, from: main))
        coordinator.selectionBar?.update(); bars.isHidden = true; accessibilityGroup.isHidden = true
    }

    func beginCrop() {
        guard let coordinator, let target = coordinator.selectedImageTarget(), let main = textView, main.isEditable,
              let object = coordinator.objectSelection, let rect = main.renderedImageRect(at: object.anchor), let scrollView,
              let image = coordinator.configuration.services.images.image(for: target.request) else { return }
        let view = ImageCropView(image: image, pixels: coordinator.configuration.services.images.pixelSize(for: target.request) ?? image.size,
                                 crop: target.tokens.crop, imageRect: { [weak main, weak scrollView] in
            guard let main, let scrollView, let rect = main.renderedImageRect(at: object.anchor) else { return nil }
            return scrollView.convert(rect, from: main)
        })
        let fullWidth = rect.width / (target.tokens.crop?.width ?? 1)
        cropView = view
        view.onApply = { [weak coordinator] rect in coordinator?.applyImageCrop(rect, fullWidth: fullWidth) }
        view.onClose = { [weak self] applied in
            self?.cropView = nil
            if !applied { MarkdownTableEditingSession.announce("Crop cancelled") }
            self?.transientDidClose()
        }
        view.present(in: scrollView)
        coordinator.selectionBar?.update(); bars.isHidden = true; accessibilityGroup.isHidden = true
        MarkdownTableEditingSession.announce("Crop mode: drag an edge or a corner of the image to crop it. Enter applies, Escape cancels.")
    }

    private func adjustWidth(by delta: CGFloat) -> Bool {
        guard !isInteracting, menu == nil, !accessibilityGroup.isHiddenOrHasHiddenAncestor,
              let coordinator, let main = textView, main.isEditable,
              let image = coordinator.objectSelection,
              let rect = main.renderedImageRect(at: image.anchor) else { return false }
        coordinator.setImageWidth(rect.width + delta, actionName: "Resize Image")
        refresh()
        return true
    }

    private func transientDidClose() {
        if isProcessingStorageEdit {
            coordinator?.selectionBar?.setNeedsUpdate(); setNeedsRefresh()
        } else {
            coordinator?.selectionBar?.update(); refresh()
        }
    }

    func cancel() { cropView?.close(applied: false); altPopover?.close(restoreFocus: false) }
}

private final class ImageResizeBars: NSView {
    var imageRect = NSRect.zero
    var dragging = false {
        didSet { if oldValue != dragging { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = ChromePalette.isDark(effectiveAppearance)
        let color = dragging ? (dark ? NSColor(calibratedRed: 195/255, green: 194/255, blue: 183/255, alpha: 1)
            : NSColor(calibratedRed: 82/255, green: 81/255, blue: 78/255, alpha: 1))
            : NSColor(calibratedRed: 137/255, green: 135/255, blue: 129/255, alpha: 1)
        color.setFill()
        let height = min(max((imageRect.height * 0.5).rounded(), 16), 48)
        for x in [imageRect.minX - 6, imageRect.maxX + 6] {
            NSBezierPath(roundedRect: NSRect(x: x - 1.5, y: imageRect.midY - height / 2, width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

private final class ImageResizeAccessibilityHandle: NSAccessibilityElement {
    var onAdjust: ((CGFloat) -> Bool)?
    override func accessibilityPerformIncrement() -> Bool { onAdjust?(10) ?? false }
    override func accessibilityPerformDecrement() -> Bool { onAdjust?(-10) ?? false }
}

/// Its view paints nothing and never takes pointer input; it stays visible for a selected image.
private final class ImageResizeAccessibilityView: NSView {
    var onAdjust: ((CGFloat) -> Bool)?
    private let handles = [ImageResizeAccessibilityHandle(), ImageResizeAccessibilityHandle()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Resize image controls")
        for handle in handles {
            handle.setAccessibilityParent(self)
            handle.setAccessibilityRole(.splitter)
            handle.setAccessibilityLabel("Resize image")
            handle.onAdjust = { [weak self] delta in self?.onAdjust?(delta) ?? false }
        }
        setAccessibilityChildren(handles)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(width: CGFloat, screenRect: NSRect) {
        for (index, handle) in handles.enumerated() {
            handle.setAccessibilityValue(NSNumber(value: Double(width)))
            handle.setAccessibilityFrame(NSRect(x: index == 0 ? screenRect.minX - 12 : screenRect.maxX,
                                               y: screenRect.midY - 24, width: 12, height: 48))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
