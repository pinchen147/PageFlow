//
//  EPUBPageStackSurface.swift
//  PageFlow
//
//  The continuous EPUB layouts: fixed-size pages, one or two per row, stacked
//  vertically on PDF's viewer background and scrolled like PDF's continuous
//  modes. Only rows near the viewport have page views.
//

import AppKit
import SwiftUI

struct EPUBPageStackSurface: NSViewRepresentable {
    let pageCount: Int
    let pagesPerRow: Int
    /// See ``EPUBSpreadSurface/spreads``.
    let spreads: EPUBSpreadTable
    /// See ``EPUBSpreadSurface/rightToLeft``: a row's pages run right to left.
    var rightToLeft = false
    let pageSize: CGSize
    let currentPage: Int
    let request: EPUBNavigationRequest?
    /// Where a view built afresh opens: the reader's place in the page.
    let restoring: EPUBReadingSpot?
    /// Hands the view to the book, which reads its place when it saves.
    let onSurface: (any EPUBReadingSurface) -> Void
    /// The page scale, or nil to fit the page row to the window's width.
    let zoom: CGFloat?
    let revision: Int
    let topInset: CGFloat
    let isDisplayed: Bool
    let pageContent: (Int) -> EPUBPageContent
    let onVisiblePage: (Int) -> Void
    let onZoom: (CGFloat) -> Void
    let onOpenLink: EPUBLinkHandler
    /// Turns a page; returns whether there was one to turn to.
    let onTurn: (Bool) -> Bool
    /// See ``EPUBSpreadSurface/onEscape``.
    let onEscape: () -> Bool
    /// See ``EPUBSpreadSurface/wantsKeyFocus``.
    let wantsKeyFocus: Bool
    var annotationDocument: (any TabDocument)? = nil

    func makeCoordinator() -> ReaderFocus { ReaderFocus() }

    func makeNSView(context: Context) -> EPUBPageStackScrollView {
        EPUBPageStackScrollView()
    }

    func updateNSView(_ view: EPUBPageStackScrollView, context: Context) {
        view.setReaderSurfaceHidden(!isDisplayed)
        view.onTurn = onTurn
        view.onEscape = onEscape
        view.stack.annotationDocument = annotationDocument
        context.coordinator.update(wantsKeyFocus, view: view.stack)
        view.setTopInset(topInset)
        view.stack.pageContent = pageContent
        view.stack.linkHandler = onOpenLink
        view.onVisiblePage = onVisiblePage
        view.onZoom = onZoom
        view.rightToLeft = rightToLeft
        view.update(
            pageCount: pageCount,
            pagesPerRow: pagesPerRow,
            pageSize: pageSize,
            currentPage: currentPage,
            zoom: zoom,
            revision: revision,
            request: request,
            spreads: spreads,
            restoring: restoring
        )
        onSurface(view)
    }

    static func dismantleNSView(_ view: EPUBPageStackScrollView, coordinator: ReaderFocus) {
        view.onLeaving?(view.readingPlace)
        view.onLeaving = nil
        view.onVisiblePage = nil
        view.onTurn = nil
        view.onEscape = nil
        view.onZoom = nil
        view.onFitWidthChanged = nil
        view.stack.detachBook()
    }
}

final class EPUBPageStackScrollView: NSScrollView, EPUBReadingSurface {
    let stack = EPUBPageStackView()
    var onVisiblePage: ((Int) -> Void)?
    var onLeaving: ((EPUBReadingPlace?) -> Void)?
    var onTurn: ((Bool) -> Bool)?
    var onEscape: (() -> Bool)?
    var onZoom: ((CGFloat) -> Void)?
    var onFitWidthChanged: ((Bool) -> Void)? { didSet { lastPublishedFitWidth = nil } }
    private var lastPublishedFitWidth: Bool?
    private var fitWidthPublicationScheduled = false

    /// Coalesces native scale/layout changes without committing zoom or reflow.
    func scheduleFitWidthPublication() {
        guard !fitWidthPublicationScheduled else { return }
        fitWidthPublicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitWidthPublicationScheduled = false
            guard self.window != nil, !self.isHiddenOrHasHiddenAncestor else { return }
            let size = self.contentView.frame.size
            let valid = [size.width, size.height, self.stack.pageSize.width,
                         self.stack.pageSize.height, self.magnification]
                .allSatisfy { $0.isFinite && $0 > 0 }
            let fit = self.fitScale
            let fits = valid && fit.isFinite && fit > 0 && self.magnification <= fit + 1e-9
            guard self.lastPublishedFitWidth != fits else { return }
            self.lastPublishedFitWidth = fits
            self.onFitWidthChanged?(fits)
        }
    }
    var rightToLeft: Bool {
        get { stack.rightToLeft }
        set { stack.rightToLeft = newValue }
    }
    private var zoom: CGFloat?
    private var shownRequest: Int?
    private var revision = -1
    /// Where the reader is inside the current row, kept across re-layouts.
    private var rowFraction: CGFloat = 0
    /// A place to show once the view has its size and scale.
    private var pendingSpot: EPUBReadingSpot?
    private var isRestoring = false
    /// Read Aloud keeping its line in view, for the session it began with.
    private var lineFollow = EPUBReadAloudFollow()
    private var followedSession: Int?
    /// A re-layout or zoom moves the scroll offset without the reader.
    private var followedLayout: (moves: Int, magnification: CGFloat)?
    private var isMagnifying = false
    private var nativeMagnificationDepth = 0
    private var nativeGeometryPending = false
    private var zoomPublicationPending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        drawsBackground = true
        automaticallyAdjustsContentInsets = false
        backgroundColor = DesignTokens.viewerBackground
        allowsMagnification = true
        contentView = EPUBCenteringClipView()
        documentView = stack
        stack.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        setUpReaderAccessibility { [weak self] forward in self?.onTurn?(forward) ?? false }
        // PDF's scroll bar: Liquid Glass, hidden until the pointer nears the edge.
        GlassScrollerHover.install(on: self)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationStarted), name: NSScrollView.willStartLiveMagnifyNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(spokenMoved(_:)), name: .epubPageMarksDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(magnificationEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// AppKit changes the clip bounds several times while anchoring one native
    /// zoom. Only the completed operation describes pages the reader can see.
    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        nativeMagnificationDepth += 1
        defer { finishNativeMagnification() }
        super.setMagnification(magnification, centeredAt: point)
    }

    override func magnify(with event: NSEvent) {
        nativeMagnificationDepth += 1
        defer { finishNativeMagnification() }
        super.magnify(with: event)
    }

    private func finishNativeMagnification() {
        nativeMagnificationDepth -= 1
        guard nativeMagnificationDepth == 0 else { return }
        if nativeGeometryPending {
            nativeGeometryPending = false
            reconcileVisiblePages()
            showPendingSpot()
            scheduleFitWidthPublication()
        }
        // AppKit may end live magnification inside its native operation. The
        // book must receive zoom only after the final reading pages are mounted.
        if zoomPublicationPending {
            zoomPublicationPending = false
            isMagnifying = false
            onZoom?(magnification)
        }
    }

    /// The point of the page under the pointer stays under it, as a pinch's does.
    override func scrollWheel(with event: NSEvent) {
        guard let scale = EPUBControlScroll.scale(after: event, from: magnification) else {
            return super.scrollWheel(with: event)
        }
        zoom = scale
        setMagnification(scale, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        onZoom?(scale)
    }

    /// Told to the book, unlike AppKit's own, so the next update doesn't undo it.
    override func smartMagnify(with event: NSEvent) {
        let scale = EPUBSmartZoom.scale(from: magnification, fit: fitScale)
        zoom = scale
        setMagnification(scale, centeredAt: contentView.convert(event.locationInWindow, from: nil))
        onZoom?(scale)
    }

    /// The first page starts below the floating chrome and scrolls under it.
    func setTopInset(_ inset: CGFloat) {
        guard contentInsets.top != inset else { return }
        contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: 0, right: 0)
    }

    func update(pageCount: Int, pagesPerRow: Int, pageSize: CGSize, currentPage: Int, zoom: CGFloat?,
                revision: Int, request: EPUBNavigationRequest?, spreads: EPUBSpreadTable? = nil,
                restoring: EPUBReadingSpot? = nil) {
        // Scroll changes made here are the model's own, not the reader's:
        // reporting them back would overwrite the reading position.
        isRestoring = true
        defer { isRestoring = false; scheduleFitWidthPublication() }
        let geometryChanged = stack.setPages(count: pageCount, perRow: pagesPerRow, size: pageSize, spreads: spreads,
                                             readerMovedBy: currentPage - stack.currentPage)
        stack.currentPage = currentPage
        self.zoom = zoom
        applyScale()
        var jumped = false
        if let request, request.generation != shownRequest {
            jumped = true
            // A view built fresh (a tab rebuilt after leaving the warm set)
            // opens where the reader is, not at the last jump's page.
            let isFresh = shownRequest == nil
            shownRequest = request.generation
            rowFraction = 0
            scroll(toPage: isFresh ? currentPage : request.page, fraction: 0)
            pendingSpot = isFresh ? restoring ?? request.spot : request.spot
        } else if geometryChanged {
            // Pages filled in above the reader: keep the reader's page in view.
            scroll(toPage: currentPage, fraction: rowFraction)
        }
        if revision != self.revision || geometryChanged {
            self.revision = revision
            stack.reloadVisiblePages()
        }
        stack.tile()
        showPendingSpot()
        // A jump that leaves none of the selection in view drops it.
        if jumped { EPUBPageView.dropSelection(ifNotOn: stack.pagesInView) }
    }

    override func layout() {
        super.layout()
        defer { scheduleFitWidthPublication() }
        guard nativeMagnificationDepth == 0 else {
            nativeGeometryPending = true
            return
        }
        isRestoring = true
        applyScale()
        isRestoring = false
        stack.tile()
        showPendingSpot()
    }

    /// The text at the view's top edge, below the floating chrome.
    var readingPlace: EPUBReadingPlace? {
        let top = contentView.bounds.minY + contentInsets.top / magnification
        guard let anchor = stack.readingAnchor(atY: top) else { return nil }
        return EPUBReadingPlace(chapter: anchor.position.chapter, offset: anchor.position.offset,
                                delta: top - anchor.lineTop, x: contentView.bounds.minX)
    }

    /// Scrolls back to a reading place: its line and how far below it the top
    /// edge was. Waits for a size and scale, which a new view doesn't have yet.
    private func showPendingSpot() {
        guard let spot = pendingSpot, contentView.bounds.width * magnification > EPUBPageGeometry.pageGap * 4 else { return }
        pendingSpot = nil
        let wasRestoring = isRestoring
        isRestoring = true
        defer { isRestoring = wasRestoring }
        scroll(toPage: spot.page, fraction: 0)
        stack.tile()
        let top = stack.lineTop(of: spot.place, onPage: spot.page) + spot.place.delta
        let inset = contentInsets.top / magnification
        scrollToReadingPoint(NSPoint(x: spot.place.x, y: top - inset))
        stack.tile()
        noteRowFraction(atPage: spot.page)
    }

    /// The reader's page scale, or, fitted, the page row (with its gaps)
    /// filling the window's width, like PDF's continuous Zoom to Fit.
    private func applyScale() {
        // Not laid out yet: a zero width would produce a near-zero scale.
        let viewWidth = contentView.bounds.width * magnification
        guard viewWidth > EPUBPageGeometry.pageGap * 4 else { return }
        let range = EPUBPageGeometry.scaleRange
        let target = zoom ?? fitScale
        let lower = range.lowerBound
        let upper = range.upperBound
        // AppKit throws if the minimum ever exceeds the maximum, so widen first.
        if lower > maxMagnification {
            maxMagnification = upper
            minMagnification = lower
        } else {
            minMagnification = lower
            maxMagnification = upper
        }
        if abs(magnification - target) > 0.001, !isMagnifying {
            setMagnification(target, centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.minY))
        }
        stack.fitWidth()
    }

    private var fitScale: CGFloat {
        EPUBPageGeometry.fitScale(
            pageSize: stack.pageSize,
            viewport: CGSize(width: contentView.bounds.width * magnification, height: contentView.bounds.height * magnification),
            layout: stack.pagesPerRow == 2 ? .twoUpContinuous : .singlePageContinuous)
    }

    private func scroll(toPage page: Int, fraction: CGFloat) {
        let wasRestoring = isRestoring
        isRestoring = true
        defer { isRestoring = wasRestoring }
        // The visible area starts below the top content inset.
        let inset = contentInsets.top / magnification
        let y = stack.rowTop(forPage: page) - EPUBPageGeometry.pageGap + fraction * stack.rowHeight - inset
        scrollToReadingPoint(NSPoint(x: contentView.bounds.minX, y: y))
    }

    @objc private func boundsChanged() {
        scheduleFitWidthPublication()
        guard nativeMagnificationDepth == 0 else {
            nativeGeometryPending = true
            return
        }
        reconcileVisiblePages()
    }

    private func reconcileVisiblePages() {
        stack.tile()
        guard !isRestoring, pendingSpot == nil, stack.pageCount > 0 else { return }
        // The page a quarter of the way down the viewport is the one being read.
        let inset = contentInsets.top / magnification
        let visibleTop = contentView.bounds.minY + inset
        let probe = visibleTop + (contentView.bounds.height - inset) * 0.25
        let page = stack.page(atY: probe)
        noteRowFraction(atPage: page)
        onVisiblePage?(page)
    }

    private func noteRowFraction(atPage page: Int) {
        let visibleTop = contentView.bounds.minY + contentInsets.top / magnification
        rowFraction = (visibleTop + EPUBPageGeometry.pageGap - stack.rowTop(forPage: page)) / stack.rowHeight
    }

    // MARK: Reading keys

    /// Space and Page Up/Down scroll a screenful, ←/→ pan pages wider than
    /// the window and otherwise turn a page, ↑/↓ scroll a line, Home/End go
    /// to the top or bottom, Esc closes the reader's panels. Returns whether
    /// the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        if EPUBPageView.extendSelection(with: event, among: stack.tiledPages,
                                        pageContent: { [stack] in stack.pageContent?($0) }) {
            followSelection()
            return true
        }
        let visible = (contentView.bounds.height - contentInsets.top / magnification)
        let screenful = max(40, visible * 0.9)
        func sign(_ forward: Bool) -> CGFloat { forward ? 1 : -1 }
        switch EPUBReaderKey(event, rightToLeft: rightToLeft) {
        case .screen(let forward): scroll(by: sign(forward) * screenful)
        case .line(let forward): scroll(by: sign(forward) * EPUBReaderKey.lineStep / magnification)
        case .turn(let forward): if !panSideways(forward, rightToLeft: rightToLeft) { _ = onTurn?(forward) }
        case .end(let forward): scroll(by: sign(forward) * .greatestFiniteMagnitude)
        case .escape: return onEscape?() ?? false
        case nil: return false
        }
        return true
    }

    /// Scrolls the selection's moving end into view, by the least it takes;
    /// a page with no view yet is gone to first.
    private func followSelection() {
        guard let annotator = stack.tiledPages.first?.content?.annotator, let focus = annotator.movingEnd else { return }
        if stack.line(at: focus) == nil, let page = annotator.pageIndex(focus) {
            scroll(toPage: page, fraction: 0)
            stack.tile()
        }
        guard let line = stack.line(at: focus) else { return }
        scrollToShow(line, topInset: contentInsets.top / magnification)
    }

    private func scroll(by distance: CGFloat) {
        let bounds = contentView.bounds
        let top = -contentInsets.top / magnification
        let bottom = max(top, stack.bounds.maxY - bounds.height + contentInsets.bottom / magnification)
        let y = min(max(top, bounds.minY + distance), bottom)
        scrollToReadingPoint(NSPoint(x: bounds.minX, y: y))
    }

    /// A jump must land where a later native layout can keep it, including
    /// the last row when zooming out makes the viewport taller than a page.
    private func scrollToReadingPoint(_ point: NSPoint) {
        var proposed = contentView.bounds
        proposed.origin = point
        let constrained = contentView.constrainBoundsRect(proposed)
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }

    /// Read Aloud moved: scroll its line into view, unless the reader has
    /// scrolled away from it (then it waits until the line is back in view).
    @objc private func spokenMoved(_ notification: Notification) {
        guard let reader = notification.object as? EPUBReadAloud, reader.isActive, !isHidden,
              let line = stack.spokenLine(of: reader) else { return }
        if followedSession != reader.session || followedLayout?.moves != reader.layoutMoves
            || followedLayout?.magnification != magnification {
            followedSession = reader.session
            followedLayout = (reader.layoutMoves, magnification)
            lineFollow = EPUBReadAloudFollow()
        }
        let visible = contentView.bounds
        let topInset = contentInsets.top / magnification
        let target = EPUBReadAloud.scrollTop(keeping: line, visible: visible, topInset: topInset)
        let targetX = EPUBReadAloud.scrollLeft(keeping: line, visible: visible)
        guard lineFollow.shouldFollow(inView: target == nil && targetX == nil, at: Int(visible.minY.rounded())),
              target != nil || targetX != nil else { return }
        let bottom = max(-topInset, stack.frame.height - visible.height)
        let right = max(0, stack.frame.width - visible.width)
        contentView.scroll(to: NSPoint(x: targetX.map { min(max(0, $0), right) } ?? visible.minX,
                                       y: target.map { min(max(-topInset, $0), bottom) } ?? visible.minY))
        reflectScrolledClipView(contentView)
        lineFollow.followed(to: Int(contentView.bounds.minY.rounded()))
    }

    @objc private func magnificationStarted() {
        isMagnifying = true
    }

    @objc private func magnificationEnded() {
        guard nativeMagnificationDepth == 0 else {
            zoomPublicationPending = true
            return
        }
        isMagnifying = false
        onZoom?(magnification)
    }
}

/// The document view: lays out page rows and keeps page views only for rows
/// near the visible rect.
final class EPUBPageStackView: NSView, ReaderFocusSurface {
    var isBeingRead = false
    weak var annotationDocument: (any TabDocument)?
    private(set) var pageCount = 0
    private(set) var pagesPerRow = 1
    var currentPage = 0
    var pageContent: ((Int) -> EPUBPageContent)?
    var linkHandler: EPUBLinkHandler?
    var keyHandler: ((NSEvent) -> Bool)?
    var rightToLeft = false {
        didSet { if rightToLeft != oldValue { repositionPages() } }
    }
    private var pageViews: [Int: EPUBPageView] = [:]
    private var spare: [EPUBPageView] = []
    private var palette = EPUBPagePalette.light

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keys scroll without a click first.
        claimReaderFocus(overEditing: isBeingRead)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        performAnnotationKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard keyHandler?(event) != true else { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // A click between pages keeps the keyboard on the reader.
        window?.makeFirstResponder(self)
    }

    private(set) var pageSize = EPUBPageGeometry.standard.pageSize
    private var gap: CGFloat { EPUBPageGeometry.pageGap }
    var rowWidth: CGFloat { CGFloat(pagesPerRow) * pageSize.width + CGFloat(pagesPerRow - 1) * gap }
    var rowHeight: CGFloat { pageSize.height + gap }
    private var rowCount: Int { spreads.rowCount }
    private var spreads = EPUBSpreadTable(pagesPerRow: 1, pageCount: 0)

    /// The document is exactly the page row (with its gaps); a window wider
    /// than it centres it (EPUBCenteringClipView), so zooming out never
    /// re-lays the pages out from under the pointer.
    func fitWidth() {
        let width = rowWidth + gap * 2
        let height = gap + CGFloat(rowCount) * rowHeight
        guard abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 else { return }
        setFrameSize(NSSize(width: width, height: height))
        repositionPages()
    }

    func rowTop(forPage page: Int) -> CGFloat {
        gap + CGFloat(spreads.row(ofPage: page)) * rowHeight
    }

    func page(atY y: CGFloat) -> Int {
        let row = max(0, min(rowCount - 1, Int((y - gap) / rowHeight)))
        return spreads.row(at: row).first
    }

    private func pageFrame(_ page: Int) -> NSRect {
        let row = spreads.row(holding: page)
        let position = row.count == 1 && pagesPerRow == 2 ? row.loneSlot.position : CGFloat(page - row.first)
        let column = rightToLeft ? CGFloat(pagesPerRow - 1) - position : position
        let left = (bounds.width - rowWidth) / 2
        return NSRect(
            x: floor(left + column * (pageSize.width + gap)),
            y: rowTop(forPage: page),
            width: pageSize.width,
            height: pageSize.height
        )
    }

    /// Creates views for rows near the visible rect and recycles the rest.
    func tile() {
        guard pageCount > 0, let visible = enclosingScrollView?.contentView.bounds else { return }
        let buffer = rowHeight
        let firstRow = max(0, Int((visible.minY - buffer - gap) / rowHeight))
        let lastRow = min(rowCount - 1, Int((visible.maxY + buffer - gap) / rowHeight))
        guard firstRow <= lastRow else { return }
        let wanted = Set((firstRow...lastRow).flatMap { spreads.row(at: $0).pages })
        for (page, view) in pageViews where !wanted.contains(page) {
            view.remove(handingFocusTo: self)
            pageViews[page] = nil
            spare.append(view)
        }
        for page in wanted where pageViews[page] == nil {
            let view = spare.popLast() ?? EPUBPageView(frame: .zero)
            view.linkHandler = linkHandler
            view.keyHandler = keyHandler
            view.frame = pageFrame(page)
            configure(view, page: page)
            addSubview(view)
            pageViews[page] = view
            needsDisplay = true
        }
    }

    fileprivate func detachBook() {
        pageContent = nil
        linkHandler = nil
        for page in pageViews.values { page.linkHandler = nil }
        for page in spare { page.linkHandler = nil }
    }

    func reloadVisiblePages() {
        for (page, view) in pageViews { configure(view, page: page) }
    }

    /// The pages with views, in and near the window.
    var tiledPages: [EPUBPageView] { Array(pageViews.values) }

    /// The tiled pages the window shows some of.
    var pagesInView: [EPUBPageView] {
        guard let visible = enclosingScrollView?.contentView.bounds else { return [] }
        return pageViews.values.filter { $0.frame.intersects(visible) }
    }

    /// Ordered top to bottom.
    private var orderedPagesInView: [EPUBPageView] {
        pagesInView.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    // MARK: Reading place

    /// The text a height in this view reads, on the row there, and the top of
    /// its line in this view's coordinates.
    func readingAnchor(atY y: CGFloat) -> (position: EPUBTextPosition, lineTop: CGFloat)? {
        guard rowCount > 0 else { return nil }
        let index = max(0, min(rowCount - 1, Int(floor((y - gap) / rowHeight))))
        var row = spreads.row(at: index)
        // In the gap below a row, what's being read is the next: a jump rests there, and a
        // place named by the last character above would land a row back a page at a time.
        if let above = pageViews[row.first], y >= above.frame.maxY, index + 1 < rowCount,
           pageViews[spreads.row(at: index + 1).first] != nil {
            row = spreads.row(at: index + 1)
        }
        guard let view = pageViews[row.first], let anchor = view.readingAnchor(atY: y - view.frame.minY) else { return nil }
        return (anchor.position, view.frame.minY + anchor.lineTop)
    }

    /// The top of a reading place's line, or of its page.
    func lineTop(of place: EPUBReadingPlace, onPage page: Int) -> CGFloat {
        guard let view = pageViews[page] else { return rowTop(forPage: page) }
        return view.frame.minY + view.lineTop(of: place)
    }

    // MARK: Copy and Select All, with the keyboard here

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if window?.firstResponder === self,
           let requestor = orderedPagesInView.first?.servicesRequestor(sending: sendType, receiving: returnType) { return requestor }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc func copy(_ sender: Any?) { EPUBReaderTextCommands.copy(orderedPagesInView) }

    override func selectAll(_ sender: Any?) { EPUBReaderTextCommands.selectAll(orderedPagesInView) }

    @objc func startSpeaking(_ sender: Any?) { orderedPagesInView.first?.content?.readAloud?.start() }

    @objc func stopSpeaking(_ sender: Any?) { orderedPagesInView.first?.content?.readAloud?.stop() }

    /// The page showing where `reader` is, and the line it is on, in this
    /// view's coordinates.
    func spokenLine(of reader: EPUBReadAloud) -> NSRect? {
        guard let spoken = reader.spoken else { return nil }
        for view in pageViews.values {
            guard let content = view.content, content.readAloud === reader, content.chapter == spoken.chapter,
                  let range = content.range, NSLocationInRange(spoken.location, range),
                  let line = view.lineRect(atLocal: spoken.location - range.location) else { continue }
            return convert(line, from: view)
        }
        return nil
    }

    /// The line holding a place in the book on a tiled page, in this view's
    /// coordinates.
    func line(at position: EPUBTextPosition) -> NSRect? {
        for view in pageViews.values {
            guard let content = view.content, content.shows(position), let range = content.range,
                  let line = view.lineRect(atLocal: min(position.offset - range.location, view.textView.string.utf16.count - 1)) else { continue }
            return convert(line, from: view)
        }
        return nil
    }

    private func configure(_ view: EPUBPageView, page: Int) {
        guard let content = pageContent?(page) else { return }
        if content.palette != palette {
            palette = content.palette
            needsDisplay = true
        }
        view.configure(content)
    }

    private func repositionPages() {
        var moved = false
        for (page, view) in pageViews {
            let frame = pageFrame(page)
            if view.frame != frame {
                view.frame = frame
                moved = true
            }
        }
        if moved { needsDisplay = true }
    }

    /// Changes the page count, pages per row or page size once, re-laying
    /// every page. Returns whether anything changed. A book filling in only
    /// changes the count, once a chapter: pages landing after the reader leave the
    /// pages in view as they are. Ones before it number each view `readerMovedBy`
    /// further on, which it reloads for, and two up an odd count moves the views
    /// to the row's other side or the next row, so another page may share the reader's.
    @discardableResult
    func setPages(count: Int, perRow: Int, size: CGSize, spreads: EPUBSpreadTable? = nil, readerMovedBy shift: Int = 0) -> Bool {
        let table = spreads ?? EPUBSpreadTable(pagesPerRow: perRow, pageCount: count)
        guard count != pageCount || perRow != pagesPerRow || size != pageSize || table != self.spreads else { return false }
        let onlyTheCount = perRow == pagesPerRow && size == pageSize
        pageCount = count
        pagesPerRow = perRow
        pageSize = size
        self.spreads = table
        if !onlyTheCount {
            pageViews.values.forEach { $0.remove(handingFocusTo: self); spare.append($0) }
            pageViews.removeAll()
        } else if shift != 0 {
            pageViews = Dictionary(uniqueKeysWithValues: pageViews.map { ($0.key + shift, $0.value) })
        }
        fitWidth()
        repositionPages()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        EPUBPageSheet.draw(pageViews.keys.map(pageFrame), in: dirtyRect, palette: palette)
    }
}

/// Centres a document narrower than the window, as PDF does with pages
/// zoomed out below its width; a wider one scrolls as usual.
final class EPUBCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView, rect.width > document.frame.width {
            rect.origin.x = ((document.frame.width - rect.width) / 2).rounded()
        }
        return rect
    }
}

extension EPUBPageStackView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        EPUBReaderTextCommands.validate(item, pages: orderedPagesInView) ?? true
    }
}

