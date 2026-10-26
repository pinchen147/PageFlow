//
//  GlassScrollerHover.swift
//  PageFlow
//
//  Applies the PDF tabs' scroller treatment to any NSScrollView: the Liquid
//  Glass knob (`GlassScroller`), overlay style, and hidden-until-hover reveal
//  (the scroller fades in when the cursor nears the trailing edge, exactly
//  like `StablePDFView`'s vertical zone) — so the Markdown editor's scroll
//  bar is indistinguishable from a PDF tab's.
//

import AppKit
import ObjectiveC

enum GlassScrollerHover {
    private static var associationKey: UInt8 = 0

    /// Install on the editor's scroll view (vertical scroller only — the
    /// horizontal strips inside wide tables keep the engine's subtle
    /// in-table scroller).
    @MainActor
    static func install(on scrollView: NSScrollView) {
        let controller = GlassScrollerHoverController(scrollView: scrollView)
        objc_setAssociatedObject(scrollView, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Owns the tracking area + fade for one scroll view. Retained via associated
/// object so it lives exactly as long as the scroll view.
@MainActor
private final class GlassScrollerHoverController: NSObject {
    /// Same reveal band as `StablePDFView.verticalHoverZoneSize`.
    private static let hoverZoneWidth: CGFloat = 120

    private weak var scrollView: NSScrollView?
    private var trackingArea: NSTrackingArea?
    private var frameObserver: NSObjectProtocol?
    private var styleObserver: NSObjectProtocol?

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        scrollView.scrollerStyle = .overlay
        let scroller = GlassScroller()
        scroller.alphaValue = 0
        scrollView.verticalScroller = scroller
        refreshTrackingArea()
        // The scroll view already posts frame changes (the engine relies on it);
        // re-fit the hover band whenever the viewport resizes.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrackingArea() }
        }
        // AppKit re-applies the system scroller style when it changes (a mouse
        // plugged in under "Automatically"); a legacy-style scroller at alpha 0
        // would leave an invisible gutter that eats clicks.
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollView?.scrollerStyle = .overlay }
        }
    }

    deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let styleObserver { NotificationCenter.default.removeObserver(styleObserver) }
    }

    private func refreshTrackingArea() {
        guard let scrollView else { return }
        if let trackingArea { scrollView.removeTrackingArea(trackingArea) }
        let width = min(Self.hoverZoneWidth, scrollView.bounds.width)
        let rect = NSRect(
            x: scrollView.bounds.maxX - width,
            y: scrollView.bounds.minY,
            width: width,
            height: scrollView.bounds.height
        )
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        scrollView.addTrackingArea(area)
        trackingArea = area
    }

    // Explicit selectors: a tracking-area owner is sent literal `mouseEntered:`
    // / `mouseExited:` (the NSResponder selectors). On a plain NSObject, plain
    // `@objc func mouseEntered(with:)` exports `mouseEnteredWith:` — every edge
    // hover then threw unrecognized-selector (field crash log).
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { setRevealed(true) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { setRevealed(false) }

    private func setRevealed(_ revealed: Bool) {
        guard let scroller = scrollView?.verticalScroller else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            scroller.animator().alphaValue = revealed ? 1 : 0
        }
    }
}
