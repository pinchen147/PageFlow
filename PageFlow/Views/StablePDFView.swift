//
//  StablePDFView.swift
//  PageFlow
//
//  PDFView subclass that preserves vertical scroll position during horizontal resize.
//

import PDFKit
import AppKit

final class StablePDFView: PDFView {
    private var lastWidth: CGFloat = 0
    private let widthChangeTolerance: CGFloat = 0.5

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

        // Remove content insets so scroll bar extends to top edge
        if let scrollView = documentScrollView {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.automaticallyAdjustsContentInsets = false
            
            configureScrollers(scrollView)
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

    // State tracking to ensure robustness during layout updates
    private var isHoveringVertical = false
    private var isHoveringHorizontal = false
    private var isObservingScroll = false

    // MARK: - Callbacks for Click Handling
    var onAnnotationClick: ((PDFAnnotation) -> Void)?
    var onAnnotationDeselect: (() -> Void)?
    var onAnnotationRemove: ((PDFAnnotation) -> Void)?
    var onControlScroll: ((NSEvent) -> Bool)?

    private var rightClickMonitor: Any?

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func setupRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleRightClickEvent(event)
        }
    }

    private func handleRightClickEvent(_ event: NSEvent) -> NSEvent? {
        // Check if click is within our view
        guard let window = self.window,
              event.window === window else {
            return event
        }

        let windowPoint = event.locationInWindow
        let viewPoint = self.convert(windowPoint, from: nil)

        guard self.bounds.contains(viewPoint) else {
            return event
        }

        guard let page = self.page(for: viewPoint, nearest: true) else {
            return event
        }

        let pagePoint = self.convert(viewPoint, to: page)

        if let annotation = self.findMarkupAnnotation(at: pagePoint, on: page) {
            self.pendingRemovalAnnotation = annotation

            let isHighlight = self.isHighlightAnnotation(annotation)
            let menu = NSMenu()
            let title = isHighlight ? "Remove Highlight" : "Remove Underline"
            let item = NSMenuItem(title: title, action: #selector(self.removeAnnotationAction(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)

            // Show menu and consume the event
            menu.popUp(positioning: nil, at: viewPoint, in: self)
            return nil  // Consume the event
        }

        return event  // Let PDFView handle it
    }

    private func configureScrollers(_ scrollView: NSScrollView) {
        // Enforce overlay style and manual visibility control
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .default
        scrollView.autohidesScrollers = false
        
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
        scrollView.verticalScroller?.alphaValue = isHoveringVertical ? 1.0 : 0.0
        scrollView.horizontalScroller?.alphaValue = isHoveringHorizontal ? 1.0 : 0.0
        
        // Observe scrolling to enforce visibility
        if !isObservingScroll {
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            isObservingScroll = true
        }
    }

    @objc private func handleScrollChanged(_ notification: Notification) {
        guard let scrollView = documentScrollView else { return }
        // Enforce visibility state during scroll to prevent system override
        // We use animator() proxy to match the active animation state if any, 
        // or just set it directly if we want strict enforcement. 
        // Direct set is safer to fight system "flash" logic.
        scrollView.verticalScroller?.alphaValue = isHoveringVertical ? 1.0 : 0.0
        scrollView.horizontalScroller?.alphaValue = isHoveringHorizontal ? 1.0 : 0.0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let vArea = verticalTrackingArea { removeTrackingArea(vArea) }
        if let hArea = horizontalTrackingArea { removeTrackingArea(hArea) }

        // Right edge (Vertical Scroller)
        let vRect = NSRect(x: bounds.width - verticalHoverZoneSize, y: 0, width: verticalHoverZoneSize, height: bounds.height)
        let vArea = NSTrackingArea(
            rect: vRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .assumeInside],
            owner: self,
            userInfo: ["type": ScrollerType.vertical.rawValue]
        )
        addTrackingArea(vArea)
        verticalTrackingArea = vArea

        // Bottom edge (Horizontal Scroller)
        // Note: PDFView is flipped, so y: bounds.height is the bottom
        let hRect = NSRect(x: 0, y: bounds.height - horizontalHoverZoneSize, width: bounds.width, height: horizontalHoverZoneSize)
        let hArea = NSTrackingArea(
            rect: hRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .assumeInside],
            owner: self,
            userInfo: ["type": ScrollerType.horizontal.rawValue]
        )
        addTrackingArea(hArea)
        horizontalTrackingArea = hArea
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

        let scroller: NSScroller?
        
        switch type {
        case .vertical:
            isHoveringVertical = isEntering
            scroller = scrollView.verticalScroller
        case .horizontal:
            isHoveringHorizontal = isEntering
            scroller = scrollView.horizontalScroller
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scroller?.animator().alphaValue = isEntering ? 1.0 : 0.0
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let widthChanged = lastWidth > 0 && abs(lastWidth - newSize.width) > widthChangeTolerance

        lastWidth = newSize.width
        super.setFrameSize(newSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        let savedY = documentScrollView?.contentView.bounds.origin.y
        let currentWidth = superview?.bounds.width ?? oldSize.width
        let widthChanged = abs(oldSize.width - currentWidth) > widthChangeTolerance

        super.resize(withOldSuperviewSize: oldSize)

        guard widthChanged, let scrollY = savedY else { return }
        restoreVerticalScroll(scrollY)
    }

    private func restoreVerticalScroll(_ y: CGFloat) {
        guard let scrollView = documentScrollView else { return }

        var origin = scrollView.contentView.bounds.origin
        origin.y = y
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var documentScrollView: NSScrollView? {
        subviews.first { $0 is NSScrollView } as? NSScrollView
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

    // MARK: - Right-Click Context Menu for Annotations

    private var pendingRemovalAnnotation: PDFAnnotation?

    override func rightMouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        guard let page = page(for: viewPoint, nearest: true) else {
            super.rightMouseDown(with: event)
            return
        }

        let pagePoint = convert(viewPoint, to: page)

        // Try to find a markup annotation at this point
        if let annotation = findMarkupAnnotation(at: pagePoint, on: page) {
            pendingRemovalAnnotation = annotation

            let isHighlight = isHighlightAnnotation(annotation)
            let menu = NSMenu()
            let title = isHighlight ? "Remove Highlight" : "Remove Underline"
            let item = NSMenuItem(title: title, action: #selector(removeAnnotationAction(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)

            menu.popUp(positioning: nil, at: viewPoint, in: self)
        } else {
            // No annotation found - pass to super for default behavior
            super.rightMouseDown(with: event)
        }
    }

    private func findMarkupAnnotation(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        // Method 1: Use PDFKit's built-in hit testing
        if let annotation = page.annotation(at: point),
           isRemovableMarkup(annotation) {
            return annotation
        }

        // Method 2: Manual search with tolerance for edge cases
        let tolerance: CGFloat = 10.0
        let searchRect = CGRect(
            x: point.x - tolerance,
            y: point.y - tolerance,
            width: tolerance * 2,
            height: tolerance * 2
        )

        for annotation in page.annotations {
            guard isRemovableMarkup(annotation) else { continue }
            if annotation.bounds.intersects(searchRect) {
                return annotation
            }
        }

        return nil
    }

    private func isRemovableMarkup(_ annotation: PDFAnnotation) -> Bool {
        guard let type = annotation.type else { return false }

        // Check for highlight or underline type (case-insensitive, partial match)
        let typeLower = type.lowercased()
        let isMarkup = typeLower.contains("highlight") || typeLower.contains("underline")

        guard isMarkup else { return false }

        // Exclude comment annotations (have UUID in userName)
        if let userName = annotation.userName,
           UUID(uuidString: userName) != nil {
            return false
        }

        return true
    }

    private func isHighlightAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.type?.lowercased().contains("highlight") ?? false
    }

    @objc private func removeAnnotationAction(_ sender: NSMenuItem) {
        guard let annotation = pendingRemovalAnnotation else { return }
        pendingRemovalAnnotation = nil
        onAnnotationRemove?(annotation)
    }
}
