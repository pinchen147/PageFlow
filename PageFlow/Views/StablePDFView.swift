//
//  StablePDFView.swift
//  PageFlow
//
//  PDFView subclass that preserves vertical scroll position during horizontal resize.
//

import PDFKit
import AppKit

final class StablePDFView: PDFView {
    private let widthChangeTolerance: CGFloat = 0.5
    /// Reading position (a page + a point on that page) captured before a width
    /// change and restored after PDFKit reflows. Anchored to a `PDFDestination`, not a
    /// raw `contentView` scroll offset: when a width change rescales pages (fit-to-width
    /// / Auto-Scale), a saved absolute Y maps to *different* content afterward, and the
    /// drift is proportional to the page's depth in the document — so a raw offset gets
    /// visibly worse on later pages. A destination lands on the same content at any
    /// depth. (Mirrors the Projector's `restoreScrollPosition`.)
    private var pendingScrollRestoreDestination: PDFDestination?
    private var pendingScrollRestore: DispatchWorkItem?
    private weak var cachedDocumentScrollView: NSScrollView?
    private weak var configuredScrollView: NSScrollView?

    // MARK: - Interaction Mode (Pan vs Select)

    var interactionMode: InteractionMode = .select {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    private var lastPanLocation: NSPoint?
    private var isPanning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
    }

    // Reject all drag operations to allow parent SwiftUI view to handle them
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return false
    }

    override func layout() {
        super.layout()

        if let scrollView = documentScrollView {
            if configuredScrollView !== scrollView {
                configureScrollers(scrollView)
                configuredScrollView = scrollView
            } else {
                syncScrollerVisibility(in: scrollView)
            }
        }
    }

    // MARK: - Scrollbar Management

    private enum ScrollerType: String {
        case vertical
        case horizontal
    }

    private var verticalTrackingArea: NSTrackingArea?
    private var horizontalTrackingArea: NSTrackingArea?
    private let verticalHoverZoneSize: CGFloat = 120.0 // 3x the original 40.0
    private let horizontalHoverZoneSize: CGFloat = 40.0
    private var needsTrackingAreaRefreshAfterLiveResize = false

    // State tracking to ensure robustness during layout updates
    private var isHoveringVertical = false
    private var isHoveringHorizontal = false
    private weak var observedContentView: NSClipView?

    // MARK: - Callbacks for Click Handling
    var onAnnotationClick: ((PDFAnnotation) -> Void)?
    var onAnnotationDeselect: (() -> Void)?
    var onAnnotationRemove: ((PDFAnnotation) -> Void)?
    var onAnnotationColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onCommentColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onControlScroll: ((NSEvent) -> Bool)?
    var onLinkNavigation: (() -> Void)?
    var onCopyPageAsMarkdown: (() -> Void)?
    var onCopyDocumentAsMarkdown: (() -> Void)?
    var onToggleBookmark: (() -> Void)?

    private var rightClickMonitor: Any?

    deinit {
        pendingScrollRestore?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setupRightClickMonitor() {
        // Guard against double-registration
        guard rightClickMonitor == nil else { return }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleRightClickEvent(event)
        }
    }

    private func handleRightClickEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window,
              event.window === window else {
            return event
        }

        let windowPoint = event.locationInWindow
        let viewPoint = self.convert(windowPoint, from: nil)

        guard self.bounds.contains(viewPoint) else {
            return event
        }

        // Verify this view is the frontmost at click point (fixes multi-tab bug)
        guard let hitView = window.contentView?.hitTest(windowPoint),
              hitView === self || hitView.isDescendant(of: self) else {
            return event
        }

        let menu = buildContextMenu(for: event, at: viewPoint)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
        return nil
    }

    private func configureScrollers(_ scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if scrollView.scrollerKnobStyle != .default {
            scrollView.scrollerKnobStyle = .default
        }
        if scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = false
        }
        if scrollView.automaticallyAdjustsContentInsets {
            scrollView.automaticallyAdjustsContentInsets = false
        }

        let contentInsets = scrollView.contentInsets
        if contentInsets.top != 0 || contentInsets.left != 0 || contentInsets.bottom != 0 || contentInsets.right != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        let scrollerInsets = scrollView.scrollerInsets
        if scrollerInsets.top != 0 || scrollerInsets.left != 0 || scrollerInsets.bottom != 0 || scrollerInsets.right != 0 {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        // Swap vertical scroller with custom GlassScroller if needed
        if !(scrollView.verticalScroller is GlassScroller) {
            let vScroller = GlassScroller()
            scrollView.verticalScroller = vScroller
        }
        
        // Swap horizontal scroller with custom GlassScroller if needed
        if !(scrollView.horizontalScroller is GlassScroller) {
            let hScroller = GlassScroller()
            scrollView.horizontalScroller = hScroller
        }

        // Enforce visibility state
        syncScrollerVisibility(in: scrollView)
        
        // Observe scrolling to enforce visibility - track contentView to handle document changes
        let contentView = scrollView.contentView
        if observedContentView !== contentView {
            // Remove old observer if contentView changed (e.g., when document changes)
            if let oldView = observedContentView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: oldView
                )
            }

            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
            observedContentView = contentView
        }
    }

    @objc private func handleScrollChanged(_ notification: Notification) {
        guard let scrollView = documentScrollView else { return }
        // Enforce visibility state during scroll to prevent system override
        // We use animator() proxy to match the active animation state if any, 
        // or just set it directly if we want strict enforcement. 
        // Direct set is safer to fight system "flash" logic.
        syncScrollerVisibility(in: scrollView)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if inLiveResize {
            needsTrackingAreaRefreshAfterLiveResize = true
            return
        }

        needsTrackingAreaRefreshAfterLiveResize = false

        if let vArea = verticalTrackingArea { removeTrackingArea(vArea) }
        if let hArea = horizontalTrackingArea { removeTrackingArea(hArea) }

        // Right edge (Vertical Scroller)
        let vWidth = min(verticalHoverZoneSize, bounds.width)
        let vRect = NSRect(x: bounds.maxX - vWidth, y: bounds.minY, width: vWidth, height: bounds.height)
        let vArea = NSTrackingArea(
            rect: vRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self,
            userInfo: ["type": ScrollerType.vertical.rawValue]
        )
        addTrackingArea(vArea)
        verticalTrackingArea = vArea

        // Bottom edge (Horizontal Scroller)
        // Note: PDFView is flipped, so y: bounds.height is the bottom
        let hHeight = min(horizontalHoverZoneSize, bounds.height)
        let hRect = NSRect(x: bounds.minX, y: bounds.maxY - hHeight, width: bounds.width, height: hHeight)
        let hArea = NSTrackingArea(
            rect: hRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self,
            userInfo: ["type": ScrollerType.horizontal.rawValue]
        )
        addTrackingArea(hArea)
        horizontalTrackingArea = hArea

        refreshScrollerHoverState()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverState(isEntering: true, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoverState(isEntering: false, event: event)
    }

    private func updateHoverState(isEntering: Bool, event: NSEvent) {
        guard let scrollView = documentScrollView,
              let userInfo = event.trackingArea?.userInfo as? [String: String],
              let typeString = userInfo["type"],
              let type = ScrollerType(rawValue: typeString) else { return }

        switch type {
        case .vertical:
            setScrollerHover(.vertical, hovering: isEntering, in: scrollView, animated: true)
        case .horizontal:
            setScrollerHover(.horizontal, hovering: isEntering, in: scrollView, animated: true)
        }
    }

    private func refreshScrollerHoverState() {
        guard let window, let scrollView = documentScrollView else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let isInside = bounds.contains(point)
        let hoveringVertical = isInside && point.x >= bounds.width - verticalHoverZoneSize
        let hoveringHorizontal = isInside && point.y >= bounds.height - horizontalHoverZoneSize

        setScrollerHover(.vertical, hovering: hoveringVertical, in: scrollView, animated: false)
        setScrollerHover(.horizontal, hovering: hoveringHorizontal, in: scrollView, animated: false)
    }

    private func setScrollerHover(
        _ type: ScrollerType,
        hovering: Bool,
        in scrollView: NSScrollView,
        animated: Bool
    ) {
        let scroller: NSScroller?

        switch type {
        case .vertical:
            guard isHoveringVertical != hovering else { return }
            isHoveringVertical = hovering
            scroller = scrollView.verticalScroller
        case .horizontal:
            guard isHoveringHorizontal != hovering else { return }
            isHoveringHorizontal = hovering
            scroller = scrollView.horizontalScroller
        }

        guard let scroller else { return }
        let alpha: CGFloat = hovering ? 1.0 : 0.0

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scroller.animator().alphaValue = alpha
            }
        } else {
            scroller.alphaValue = alpha
        }
    }

    private func syncScrollerVisibility(in scrollView: NSScrollView) {
        setScrollerAlpha(scrollView.verticalScroller, to: isHoveringVertical ? 1.0 : 0.0)
        setScrollerAlpha(scrollView.horizontalScroller, to: isHoveringHorizontal ? 1.0 : 0.0)
    }

    private func setScrollerAlpha(_ scroller: NSScroller?, to alpha: CGFloat) {
        guard let scroller, scroller.alphaValue != alpha else { return }
        scroller.alphaValue = alpha
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        let savedDestination = currentDestination
        let widthChanged = oldWidth > 0 && abs(oldWidth - newSize.width) > widthChangeTolerance

        super.setFrameSize(newSize)

        guard widthChanged, let savedDestination else { return }
        scheduleScrollRestore(to: savedDestination)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        let oldWidth = bounds.width
        let savedDestination = currentDestination

        super.resize(withOldSuperviewSize: oldSize)

        let widthChanged = abs(oldWidth - bounds.width) > widthChangeTolerance
        guard widthChanged, let savedDestination else { return }
        scheduleScrollRestore(to: savedDestination)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        pendingScrollRestore?.cancel()
        pendingScrollRestore = nil
        pendingScrollRestoreDestination = currentDestination
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if needsTrackingAreaRefreshAfterLiveResize {
            updateTrackingAreas()
        }
        flushPendingScrollRestore()
    }

    private func scheduleScrollRestore(to destination: PDFDestination) {
        pendingScrollRestoreDestination = destination
        guard !inLiveResize else { return }
        guard pendingScrollRestore == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let destination = self.pendingScrollRestoreDestination else { return }
            self.pendingScrollRestoreDestination = nil
            self.pendingScrollRestore = nil
            self.go(to: destination)
        }

        pendingScrollRestore = work
        DispatchQueue.main.async(execute: work)
    }

    private func flushPendingScrollRestore() {
        pendingScrollRestore?.cancel()
        pendingScrollRestore = nil

        guard let destination = pendingScrollRestoreDestination else { return }
        pendingScrollRestoreDestination = nil
        go(to: destination)
    }

    var documentScrollView: NSScrollView? {
        if let cachedDocumentScrollView,
           cachedDocumentScrollView.superview === self {
            return cachedDocumentScrollView
        }

        let scrollView = subviews.first { $0 is NSScrollView } as? NSScrollView
        cachedDocumentScrollView = scrollView
        return scrollView
    }

    // MARK: - Cursor Management

    override func resetCursorRects() {
        if interactionMode == .pan {
            addCursorRect(bounds, cursor: .openHand)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if interactionMode == .pan {
            (isPanning ? NSCursor.closedHand : NSCursor.openHand).set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        // Pan mode: initiate panning
        if interactionMode == .pan {
            lastPanLocation = convert(event.locationInWindow, from: nil)
            isPanning = true
            NSCursor.closedHand.push()
            return
        }

        // Select mode handling
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }

        let pagePoint = convert(viewPoint, to: page)

        // Check for internal link clicks - push navigation state before PDFKit handles the link
        if let annotation = page.annotation(at: pagePoint),
           annotation.type == "Link",
           let action = annotation.action {
            // Check if this is a GoTo action (internal navigation)
            if action is PDFActionGoTo {
                onLinkNavigation?()
            }
            // Let PDFView handle the actual navigation
            super.mouseDown(with: event)
            return
        }

        switch event.clickCount {
        case 1:
            // Single click: check for annotation
            if let annotation = page.annotation(at: pagePoint) {
                // Only consume click for comment annotations (have userName with UUID)
                // Regular highlights/underlines should allow text selection through them
                let isCommentAnnotation = annotation.userName.flatMap { UUID(uuidString: $0) } != nil
                if isCommentAnnotation {
                    onAnnotationClick?(annotation)
                    return
                }
                // For regular markup annotations, notify but allow text selection
                onAnnotationClick?(annotation)
            } else {
                onAnnotationDeselect?()
            }
            super.mouseDown(with: event)
        case 2:
            // Double click: select word
            if let selection = page.selectionForWord(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        case 3:
            // Triple click: select line
            if let selection = page.selectionForLine(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        default:
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Give control-scroll zoom handler a chance to consume the event
        if event.modifierFlags.contains(.control),
           onControlScroll?(event) == true {
            return
        }

        super.scrollWheel(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionMode == .pan, let lastLocation = lastPanLocation else {
            super.mouseDragged(with: event)
            return
        }

        guard let scrollView = documentScrollView else { return }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let dx = currentLocation.x - lastLocation.x
        let dy = currentLocation.y - lastLocation.y

        var origin = scrollView.contentView.bounds.origin
        origin.x -= dx
        origin.y -= dy

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        lastPanLocation = currentLocation
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionMode == .pan else {
            super.mouseUp(with: event)
            return
        }

        lastPanLocation = nil
        isPanning = false
        NSCursor.pop()
    }

    // MARK: - Context Menu State (used by StablePDFView+ContextMenu)

    var pendingRemovalAnnotation: PDFAnnotation?
    var pendingCommentAnnotation: PDFAnnotation?

    override func rightMouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let menu = buildContextMenu(for: event, at: viewPoint)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
    }
}
