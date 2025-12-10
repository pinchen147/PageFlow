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

    private var verticalTrackingArea: NSTrackingArea?
    private var horizontalTrackingArea: NSTrackingArea?
    private let verticalHoverZoneSize: CGFloat = 120.0 // 3x the original 40.0
    private let horizontalHoverZoneSize: CGFloat = 40.0

    // State tracking to ensure robustness during layout updates
    private var isHoveringVertical = false
    private var isHoveringHorizontal = false
    private var isObservingScroll = false

    deinit {
        NotificationCenter.default.removeObserver(self)
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
            userInfo: ["type": "vertical"]
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
            userInfo: ["type": "horizontal"]
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
              let type = userInfo["type"] else { return }

        let scroller: NSScroller?
        
        if type == "vertical" {
            isHoveringVertical = isEntering
            scroller = scrollView.verticalScroller
        } else {
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
}
