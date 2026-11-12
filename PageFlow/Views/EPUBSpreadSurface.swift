//
//  EPUBSpreadSurface.swift
//  PageFlow
//
//  The page-at-a-time EPUB layouts: one page, or an Apple Books–style
//  two-page spread with a center fold, fitted to the viewport on PDF's viewer
//  background. Turns come from arrow/Page/Space keys, a horizontal swipe or a
//  click beside the pages, and slide in from the side they came from. Pages
//  draw fitted to the window or at the reader's scale, like PDF; once they
//  overflow it, scrolling and those keys pan them, and pushing on past an edge
//  turns the page, entering the next at its top, like PDF's single page.
//

import AppKit
import SwiftUI

struct EPUBSpreadSurface: NSViewRepresentable {
    let pagesPerRow: Int
    /// Which pages share the spread (fixed-layout books name their sides).
    let spreads: EPUBSpreadTable
    let pageSize: CGSize
    let currentPage: Int
    let pageCount: Int
    /// A right-to-left book: the first page on the right, turning leftward.
    var rightToLeft = false
    let revision: Int
    let isDisplayed: Bool
    /// The page scale, or nil to fit the spread to the window.
    let zoom: CGFloat?
    let pageContent: (Int) -> EPUBPageContent
    /// Turns a page; returns whether there was one to turn to.
    let onTurn: (Bool) -> Bool
    let onZoom: (CGFloat) -> Void
    let onOpenLink: EPUBLinkHandler
    /// Shows a page at once, recording no jump.
    let onGoToPage: (Int) -> Void
    /// Esc: closes the Notes panel, else the sidebar; returns whether one was open.
    let onEscape: () -> Bool
    /// Active, displayed pages with Find closed request the keyboard. The deferred
    /// native claim rechecks this intent and preserves their own annotation editor.
    let wantsKeyFocus: Bool
    var annotationDocument: (any TabDocument)? = nil
    /// The latest thing asked of the pages: a re-layout's carries where to show.
    var request: EPUBNavigationRequest?
    /// Where a view built afresh opens: a zoomed page's pan.
    var restoring: EPUBReadingSpot?
    /// Hands the view to the book, which reads its place when it saves.
    var onSurface: (any EPUBReadingSurface) -> Void = { _ in }

    func makeCoordinator() -> ReaderFocus { ReaderFocus() }

    func makeNSView(context: Context) -> EPUBSpreadScrollView { EPUBSpreadScrollView() }

    static func dismantleNSView(_ view: EPUBSpreadScrollView, coordinator: ReaderFocus) {
        view.spread.detachBook()
    }

    func updateNSView(_ scrollView: EPUBSpreadScrollView, context: Context) {
        scrollView.setReaderSurfaceHidden(!isDisplayed)
        scrollView.spread.annotationDocument = annotationDocument
        context.coordinator.update(wantsKeyFocus, view: scrollView.spread)
        let view = scrollView.spread
        onSurface(view)
        view.turnHandler = onTurn
        view.escapeHandler = onEscape
        view.linkHandler = onOpenLink
        view.goToPageHandler = onGoToPage
        view.pageCount = pageCount
        view.onZoom = onZoom
        view.rightToLeft = rightToLeft
        let row = spreads.row(holding: currentPage)
        view.loneSlot = row.loneSlot
        view.show(pages: Array(row.pages), slots: pagesPerRow, pageSize: pageSize, revision: revision, content: pageContent)
        view.setZoom(zoom)
        view.take(request, restoring: restoring)
    }
}

/// Pans the spread once zoom makes it larger than the window.
final class EPUBSpreadScrollView: NSScrollView {
    let spread = EPUBSpreadView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = true
        backgroundColor = DesignTokens.viewerBackground
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = spread
        // PDF's scroll bar: Liquid Glass, hidden until the pointer nears the edge.
        GlassScrollerHover.install(on: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func tile() {
        super.tile()
        spread.fitToClip()
    }
}

final class EPUBSpreadView: NSView, EPUBReadingSurface, ReaderFocusSurface {
    var isBeingRead = false
    weak var annotationDocument: (any TabDocument)?
    var onLeaving: ((EPUBReadingPlace?) -> Void)?
    var turnHandler: ((Bool) -> Bool)?
    var escapeHandler: (() -> Bool)?
    /// Shows a page at once, recording no jump.
    var goToPageHandler: ((Int) -> Void)?
    var pageCount = 0
    var linkHandler: EPUBLinkHandler?
    /// Pages sit and turn right to left.
    var rightToLeft = false {
        didSet { if rightToLeft != oldValue { needsLayout = true; needsDisplay = true } }
    }
    /// Where a page without a partner sits in a two-page spread.
    var loneSlot = EPUBSpreadTable.LoneSlot.leading {
        didSet { if loneSlot != oldValue { needsLayout = true } }
    }
    private(set) var pageViews: [EPUBPageView] = []
    private var shownPages: [Int] = []
    private var shownRevision = -1
    /// What any page shows, for keys that read pages not on screen.
    private var pageContent: ((Int) -> EPUBPageContent)?
    private var slots = 1
    private var pageSize = EPUBPageGeometry.standard.pageSize
    var onZoom: ((CGFloat) -> Void)?
    /// The reader's page scale; nil fits the spread to the window.
    private var zoom: CGFloat?
    /// The scale while a pinch is under way.
    private var pinchScale: CGFloat?
    /// Set when the reader turns from this view, so only their turns slide;
    /// pages shifting as the book paginates in the background do not.
    private var pendingTurn: Bool?
    private var swipeDistance: CGFloat = 0
    private var swipeConsumed = false
    /// How far a zoomed page has been pushed past its edge in this gesture.
    private var edgeDistance: CGFloat = 0
    /// Where the next page enters after a scroll carried past a zoomed page's edge.
    private enum Entry { case top, bottom, left, right }
    private var pendingEntry: Entry?
    private var palette = EPUBPagePalette.light
    private let spine = EPUBSpineView()
    /// A pan to come back to, once the pages have their size.
    private var pendingSpot: EPUBReadingSpot?
    private var takenRequest: Int?

    fileprivate func detachBook() {
        onLeaving?(readingPlace)
        onLeaving = nil
        turnHandler = nil
        escapeHandler = nil
        goToPageHandler = nil
        onZoom = nil
        pageContent = nil
        linkHandler = nil
        for page in pageViews { page.linkHandler = nil }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = DesignTokens.viewerBackground.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setUpReaderAccessibility { [weak self] forward in self?.turn(forward) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keys turn pages without a click first.
        claimReaderFocus(overEditing: isBeingRead)
    }

    func show(pages: [Int], slots: Int, pageSize: CGSize, revision: Int, content: @escaping (Int) -> EPUBPageContent) {
        pageContent = content
        // A turn's slide and entry edge wait for its pages, which can land a
        // few updates later when their chapter is still being prepared.
        let turned = pages.first != shownPages.first
        var entry: Entry?
        if turned {
            if let forward = pendingTurn { slide(forward: forward) }
            entry = pendingEntry
            pendingTurn = nil
            pendingEntry = nil
        }
        defer { if let entry { scroll(to: entry) } }
        guard pages != shownPages || revision != shownRevision || slots != self.slots || pageSize != self.pageSize else {
            return
        }
        self.slots = slots
        self.pageSize = pageSize
        while pageViews.count > pages.count { pageViews.removeLast().remove(handingFocusTo: self) }
        while pageViews.count < pages.count {
            let view = EPUBPageView(frame: .zero)
            view.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
            pageViews.append(view)
            addSubview(view)
        }
        for (view, page) in zip(pageViews, pages) {
            view.linkHandler = linkHandler
            let pageContent = content(page)
            palette = pageContent.palette
            view.configure(pageContent)
        }
        addSubview(spine, positioned: .above, relativeTo: nil)
        // A turn to pages that show none of the selection drops it.
        if turned { EPUBPageView.dropSelection(ifNotOn: pageViews) }
        shownPages = pages
        shownRevision = revision
        fitToClip()
        needsLayout = true
        needsDisplay = true
    }

    // PDF's fit padding: the spread fills the window but for a slim margin,
    // with the floating chrome passing over the top edge while revealed.
    private static let margin = EPUBPageGeometry.spreadMargin

    private var clipSize: NSSize { enclosingScrollView?.contentView.bounds.size ?? bounds.size }

    /// The scale the spread fills the window at (PDF's single-page and
    /// two-page Zoom to Fit).
    private var fitScale: CGFloat {
        EPUBPageGeometry.fitScale(pageSize: pageSize, viewport: clipSize, layout: slots == 2 ? .twoUp : .singlePage)
    }

    private var displayedScale: CGFloat { pinchScale ?? zoom ?? fitScale }

    /// The spread at the displayed scale, before centering.
    private var spreadSize: NSSize {
        let page = pageSize
        let scale = displayedScale
        return NSSize(width: (page.width * CGFloat(slots) * scale).rounded(), height: (page.height * scale).rounded())
    }

    /// The spread, centered in the view (which grows past the window to pan).
    private var spreadFrame: NSRect {
        let size = spreadSize
        return NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Whether the zoomed spread is larger than the window, so scrolling pans.
    private var overflows: Bool {
        let clip = clipSize
        return bounds.width > clip.width + 0.5 || bounds.height > clip.height + 0.5
    }

    /// Sizes the view to the window, or to the zoomed spread and its margins
    /// when that is larger, keeping the same point of the spread centered.
    func fitToClip() { fitToClip(keeping: nil) }

    /// With an `anchor` (a pinch), that point of the spread keeps its place
    /// in the window; otherwise the window's centre does.
    private func fitToClip(keeping anchor: Anchor?) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let clip = clipView.bounds
        let visibleCenter = bounds.isEmpty ? NSPoint(x: 0.5, y: 0.5)
            : NSPoint(x: clip.midX / bounds.width, y: clip.midY / bounds.height)
        let spread = spreadSize
        let size = NSSize(width: max(clip.width, spread.width + Self.margin * 2),
                          height: max(clip.height, spread.height + Self.margin * 2))
        // Below the fit the view stays window-sized, but the pages still shrink.
        needsLayout = true
        needsDisplay = true
        guard size != frame.size else { return }
        setFrameSize(size)
        var wanted = NSPoint(x: visibleCenter.x * size.width - clip.width / 2,
                             y: visibleCenter.y * size.height - clip.height / 2)
        if let anchor {
            let spread = spreadFrame
            wanted = NSPoint(x: spread.minX + anchor.onSpread.x * spread.width - anchor.inClip.x,
                             y: spread.minY + anchor.onSpread.y * spread.height - anchor.inClip.y)
        }
        let origin = NSPoint(x: min(max(0, wanted.x), size.width - clip.width),
                             y: min(max(0, wanted.y), size.height - clip.height))
        clipView.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    func setZoom(_ zoom: CGFloat?) {
        guard zoom != self.zoom, pinchScale == nil else { return }
        self.zoom = zoom
        fitToClip()
    }

    override func layout() {
        super.layout()
        let spread = spreadFrame
        let pageWidth = spread.width / CGFloat(slots)
        for (index, view) in pageViews.enumerated() {
            let order = pageViews.count == 1 && slots == 2 ? loneSlot.position : CGFloat(index)
            let slot = rightToLeft ? CGFloat(slots - 1) - order : order
            view.frame = NSRect(x: spread.minX + slot * pageWidth, y: spread.minY,
                                width: pageWidth, height: spread.height)
            // Draw at the paginated page size, scaled, so text wraps as paginated.
            view.setBoundsSize(pageSize)
        }
        // The fold shows only between two facing pages.
        spine.isHidden = pageViews.count < 2
        let foldWidth = max(8, 28 * pageWidth / pageSize.width)
        spine.frame = NSRect(x: spread.minX + pageWidth - foldWidth / 2, y: spread.minY,
                             width: foldWidth, height: spread.height)
        showPendingSpot()
    }

    // MARK: Reading place

    /// Shows this place when the pages next have their size.
    func restore(_ spot: EPUBReadingSpot?) { pendingSpot = spot }

    /// A new view opens at the reader's place, a re-layout at the place it
    /// carries; a jump leaves the pan as it is, entering the page where it does.
    func take(_ request: EPUBNavigationRequest?, restoring: EPUBReadingSpot?) {
        let generation = request?.generation ?? 0
        defer { takenRequest = generation }
        if takenRequest == nil {
            restore(restoring ?? request?.spot)
        } else if generation != takenRequest, let spot = request?.spot {
            restore(spot)
            needsLayout = true
        }
    }

    /// What the top edge of a zoomed spread reads; nil while it fits the
    /// window and nothing pans.
    var readingPlace: EPUBReadingPlace? {
        guard overflows, let clip = enclosingScrollView?.contentView.bounds else { return nil }
        guard let page = pageViews.first(where: { $0.frame.minX <= clip.midX && clip.midX <= $0.frame.maxX }) ?? pageViews.first else {
            return nil
        }
        let top = convert(NSPoint(x: page.frame.midX, y: clip.minY), to: page).y
        guard let anchor = page.readingAnchor(atY: top) else { return nil }
        return EPUBReadingPlace(chapter: anchor.position.chapter, offset: anchor.position.offset,
                                delta: top - anchor.lineTop, x: (clip.minX - spreadFrame.minX) / displayedScale)
    }

    private func showPendingSpot() {
        guard let spot = pendingSpot, let clipView = enclosingScrollView?.contentView, clipView.bounds.width > 0 else { return }
        pendingSpot = nil
        guard overflows, let page = pageViews.first(where: {
            $0.content?.range.map { NSLocationInRange(spot.place.offset, $0) } == true && $0.content?.chapter == spot.place.chapter
        }) else { return }
        let top = convert(NSPoint(x: page.bounds.midX, y: page.lineTop(of: spot.place) + spot.place.delta), from: page).y
        clipView.scroll(to: NSPoint(x: spreadFrame.minX + spot.place.x * displayedScale, y: top))
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !pageViews.isEmpty else { return }
        let paper = pageViews.dropFirst().reduce(pageViews[0].frame) { $0.union($1.frame) }
        EPUBPageSheet.draw([paper], in: dirtyRect, palette: palette)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    /// Remembers the slide and entry edge only for a turn that happens, so a
    /// push at the book's first or last page leaves nothing behind.
    @discardableResult
    private func turn(_ forward: Bool, entering entry: Entry? = nil) -> Bool {
        guard turnHandler?(forward) == true else { return false }
        pendingTurn = forward
        pendingEntry = entry
        return true
    }

    /// Shows a zoomed page from the edge a scroll carried into it.
    private func scroll(to entry: Entry) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        var origin = clipView.bounds.origin
        switch entry {
        case .top: origin.y = 0
        case .bottom: origin.y = max(0, bounds.height - clipView.bounds.height)
        case .left: origin.x = 0
        case .right: origin.x = max(0, bounds.width - clipView.bounds.width)
        }
        clipView.scroll(to: origin)
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    /// A zoomed page pans; pushing on past its edge (a wheel step, or 40 pt
    /// of a gesture, never momentum) turns the page. Returns whether the
    /// event was used here rather than to pan.
    private func scrollPastEdge(_ event: NSEvent) -> Bool {
        guard let clip = enclosingScrollView?.contentView.bounds else { return false }
        if event.phase == .began {
            edgeDistance = 0
            swipeConsumed = false
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        // Fingers moving left or up (or the wheel rolled down) push toward
        // the right or bottom edge: forward, but back sideways in a
        // right-to-left book.
        let towardEnd = delta < 0
        let forward = horizontal && rightToLeft ? !towardEnd : towardEnd
        let atEdge = horizontal
            ? (towardEnd ? clip.maxX >= bounds.width - 1 : clip.minX <= 1)
            : (towardEnd ? clip.maxY >= bounds.height - 1 : clip.minY <= 1)
        guard delta != 0, atEdge else {
            edgeDistance = 0
            return false
        }
        let entry: Entry = horizontal ? (towardEnd ? .left : .right) : (towardEnd ? .top : .bottom)
        guard event.hasPreciseScrollingDeltas else {
            turn(forward, entering: entry)
            return true
        }
        // Held at the edge: no rubber band, and momentum never turns.
        guard event.momentumPhase.isEmpty, !swipeConsumed else { return true }
        edgeDistance += abs(delta)
        if edgeDistance > 40 {
            swipeConsumed = true
            edgeDistance = 0
            turn(forward, entering: entry)
        }
        return true
    }

    private func slide(forward: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .push
        transition.subtype = forward != rightToLeft ? .fromRight : .fromLeft
        transition.duration = 0.22
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(transition, forKey: "pageTurn")
    }

    // MARK: Copy and Select All, with the keyboard here

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if window?.firstResponder === self,
           let requestor = pageViews.first?.servicesRequestor(sending: sendType, receiving: returnType) { return requestor }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc func copy(_ sender: Any?) { EPUBReaderTextCommands.copy(pageViews) }

    override func selectAll(_ sender: Any?) { EPUBReaderTextCommands.selectAll(pageViews) }

    @objc func startSpeaking(_ sender: Any?) { pageViews.first?.content?.readAloud?.start() }

    @objc func stopSpeaking(_ sender: Any?) { pageViews.first?.content?.readAloud?.stop() }

    // MARK: Page turning

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performAnnotationKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKey(event) else { return }
        super.keyDown(with: event)
    }

    /// As in a PDF: the arrows, Space and Page Up/Down turn a page that fits
    /// and pan one that doesn't, turning on past its edge; Home and End reach
    /// the first and last page. Esc closes the reader's panels.
    func handleKey(_ event: NSEvent) -> Bool {
        if EPUBPageView.extendSelection(with: event, among: pageViews,
                                        pageContent: { [pageContent] in pageContent?($0) }) {
            followSelection()
            return true
        }
        switch EPUBReaderKey(event, rightToLeft: rightToLeft) {
        case .screen(let forward):
            panDownOrTurn(forward, by: clipSize.height * 0.9)
        case .line(let forward):
            panDownOrTurn(forward, by: EPUBReaderKey.lineStep)
        case .turn(let forward):
            panSidewaysOrTurn(forward)
        case .end(let forward):
            goToPageHandler?(forward ? pageCount - 1 : 0)
        case .escape:
            return escapeHandler?() ?? false
        case nil:
            return false
        }
        return true
    }

    /// Pans a spread taller than the window; at its edge, or one that fits,
    /// turns, the next page entering at the edge the reader is coming from.
    private func panDownOrTurn(_ forward: Bool, by distance: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.contentView.bounds
        let bottom = bounds.height - visible.height
        guard forward ? visible.minY < bottom - 1 : visible.minY > 1 else {
            turn(forward, entering: forward ? .top : .bottom)
            return
        }
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: min(max(0, visible.minY + (forward ? distance : -distance)), bottom)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Pans a spread wider than the window; at its side, or one that fits,
    /// turns. Forward is to the left in a right-to-left book.
    private func panSidewaysOrTurn(_ forward: Bool) {
        if enclosingScrollView?.panSideways(forward, rightToLeft: rightToLeft) == false {
            turn(forward, entering: forward != rightToLeft ? .left : .right)
        }
    }

    /// Brings the selection's moving end into view: the pages go to it, a
    /// zoomed page pans to it.
    private func followSelection() {
        guard let annotator = pageViews.first?.content?.annotator, let focus = annotator.movingEnd else { return }
        guard let page = pageViews.first(where: { $0.content?.shows(focus) == true }), let range = page.content?.range else {
            guard let target = annotator.pageIndex(focus) else { return }
            pendingEntry = target > shownPages.first ?? 0 ? .top : .bottom
            goToPageHandler?(target)
            return
        }
        let local = min(focus.offset - range.location, page.textView.string.utf16.count - 1)
        guard let line = page.lineRect(atLocal: local) else { return }
        layoutSubtreeIfNeeded()
        enclosingScrollView?.scrollToShow(convert(line, from: page))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let spread = spreadFrame
        if point.x < spread.minX {
            turn(rightToLeft)
        } else if point.x > spread.maxX {
            turn(!rightToLeft)
        }
    }

    override func magnify(with event: NSEvent) {
        let range = EPUBPageGeometry.scaleRange
        let scale = min(max(displayedScale * (1 + event.magnification), range.lowerBound), range.upperBound)
        pinch(to: scale, at: convert(event.locationInWindow, from: nil),
              ended: event.phase == .ended || event.phase == .cancelled)
    }

    override func smartMagnify(with event: NSEvent) {
        pinch(to: EPUBSmartZoom.scale(from: displayedScale, fit: fitScale), at: convert(event.locationInWindow, from: nil),
              ended: true)
    }

    /// A pinch step: the point of the page under the pointer stays under it,
    /// as in PDF and the continuous layouts.
    func pinch(to scale: CGFloat, at point: NSPoint, ended: Bool) {
        let anchor = anchor(at: point)
        if ended {
            pinchScale = nil
            zoom = scale
            fitToClip(keeping: anchor)
            onZoom?(scale)
            return
        }
        pinchScale = scale
        fitToClip(keeping: anchor)
    }

    /// Where `point` falls on the spread (as a fraction of it) and in the window.
    private struct Anchor {
        let onSpread: CGPoint
        let inClip: CGPoint
    }

    private func anchor(at point: NSPoint) -> Anchor? {
        guard let clip = enclosingScrollView?.contentView.bounds else { return nil }
        let spread = spreadFrame
        guard spread.width > 0, spread.height > 0 else { return nil }
        return Anchor(onSpread: CGPoint(x: (point.x - spread.minX) / spread.width,
                                        y: (point.y - spread.minY) / spread.height),
                      inClip: CGPoint(x: point.x - clip.minX, y: point.y - clip.minY))
    }

    override func scrollWheel(with event: NSEvent) {
        if let scale = EPUBControlScroll.scale(after: event, from: displayedScale) {
            pinch(to: scale, at: convert(event.locationInWindow, from: nil), ended: true)
            return
        }
        // Zoomed past the window: scrolling pans the spread, then turns at its edge.
        if overflows {
            if !scrollPastEdge(event) { super.scrollWheel(with: event) }
            return
        }
        guard event.hasPreciseScrollingDeltas else {
            // A mouse wheel steps pages.
            if abs(event.scrollingDeltaY) > 0 { turn(event.scrollingDeltaY < 0) }
            return
        }
        // Momentum after the fingers lift belongs to the gesture that already turned.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            swipeDistance = 0
            swipeConsumed = false
        }
        // Sideways, a right-to-left book's next page is to the left.
        swipeDistance += abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? (rightToLeft ? -event.scrollingDeltaX : event.scrollingDeltaX) : event.scrollingDeltaY
        if !swipeConsumed, abs(swipeDistance) > 40 {
            swipeConsumed = true
            // Fingers moving left or up reveal the next page.
            turn(swipeDistance < 0)
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipeDistance = 0
            swipeConsumed = false
        }
    }
}

extension EPUBSpreadView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        EPUBReaderTextCommands.validate(item, pages: pageViews) ?? true
    }
}
