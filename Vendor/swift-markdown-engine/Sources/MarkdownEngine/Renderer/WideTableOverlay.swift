//
//  WideTableOverlay.swift
//  MarkdownEngine
//
//  NSScrollView subview of NativeTextView hosting a wide-table image with
//  native horizontal scrolling. Sidesteps TextKit 2's fragment surface
//  cache that defeats in-fragment custom scrolling.
//

import AppKit

// MARK: - Table scroller

/// the reference editor's table scroller (doc 24 §5.2.3, §5.10.2): a classic 14 pt
/// strip that never fades while the table overflows, a 6 pt fully rounded
/// thumb inside a 4 pt clear border, white (dark) or ink (light) at .20, .35
/// under the pointer, and the arrow cursor. The track draws nothing.
final class SubtleScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 14 }

    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func drawKnobSlot(in slot: NSRect, highlight: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let pill = knob.insetBy(dx: 4, dy: max(0, (knob.height - 6) / 2))
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha: CGFloat = isHovered ? 0.35 : 0.20
        (dark ? NSColor(white: 1, alpha: alpha) : NSColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0B / 255, alpha: alpha)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - Overlay view

final class WideTableOverlay: NSScrollView {

    /// Hash of table source; key for offset persistence + reconcile lookup.
    let sourceID: Int

    /// Document index of the table anchor; click on image moves caret here.
    var anchorTextLocation: Int

    /// Weak parent ref for offset persistence + caret forwarding.
    weak var ownerTextView: NativeTextView?

    private(set) var model: MarkdownTableModel?
    private(set) var sourceRange: NSRange

    /// Table's left-edge offset (breakout: text-column left); scrollable space.
    var leftContentInset: CGFloat = 0 {
        didSet {
            guard abs(contentInsets.left - leftContentInset) > 0.5 else { return }
            contentInsets = NSEdgeInsets(top: 0, left: leftContentInset, bottom: 0, right: 0)
        }
    }

    private let tableImageView: WideTableImageView

    convenience init(sourceID: Int, image: NSImage, ownerTextView: NativeTextView, anchorLocation: Int) {
        self.init(
            sourceID: sourceID,
            image: image,
            model: nil,
            sourceRange: NSRange(location: anchorLocation, length: 0),
            ownerTextView: ownerTextView,
            anchorLocation: anchorLocation
        )
    }

    private init(
        sourceID: Int,
        image: NSImage,
        model: MarkdownTableModel?,
        sourceRange: NSRange,
        ownerTextView: NativeTextView,
        anchorLocation: Int
    ) {
        self.sourceID = sourceID
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.model = model
        self.sourceRange = sourceRange
        self.tableImageView = WideTableImageView(frame: CGRect(origin: .zero, size: image.size))
        tableImageView.image = image
        tableImageView.imageScaling = .scaleNone
        tableImageView.imageAlignment = .alignTopLeft

        super.init(frame: .zero)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        // Auto-hide: only show the scroller when the table actually overflows.
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // the reference editor's classic table scroller (see SubtleScroller).
        scrollerStyle = .legacy
        let subtleScroller = SubtleScroller()
        subtleScroller.scrollerStyle = .legacy
        horizontalScroller = subtleScroller
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        horizontalScroller?.controlSize = .small
        automaticallyAdjustsContentInsets = false

        documentView = tableImageView
        tableImageView.ownerOverlay = self

        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Clamp vertical scroll to 0 on every layout — kills sub-pixel wobble.
    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    /// Forward everything except clearly-horizontal events to the outer
    /// document scroll. Zero-delta phase/momentum lifecycle events count
    /// as "not horizontal" so the outer scroll view still receives the
    /// gesture-ended notifications it needs to stop cleanly.
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }


    /// Swap the rendered image after a restyle regenerated it.
    func updateImage(_ image: NSImage) {
        if tableImageView.image !== image {
            tableImageView.image = image
            tableImageView.frame = CGRect(origin: .zero, size: image.size)
        }
    }

    func updateSource(model: MarkdownTableModel?, sourceRange: NSRange) {
        self.model = model
        self.sourceRange = sourceRange
        self.anchorTextLocation = sourceRange.location
        (ownerTextView?.delegate as? NativeTextViewCoordinator)?.tableEditingSession.mount(in: tableImageView, range: sourceRange)
    }

    var horizontalOffset: CGFloat {
        get { contentView.bounds.origin.x }
        set {
            contentView.scroll(to: NSPoint(x: max(0, newValue), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    @objc private func scrollOffsetDidChange() {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = horizontalOffset
        // The chrome and the "…" button follow the table's horizontal scroll.
        let coordinator = ownerTextView?.delegate as? NativeTextViewCoordinator
        coordinator?.tableChrome?.invalidate()
        coordinator?.tableActions?.update()
        coordinator?.tableProxy?.tableDidScroll(self)
    }

}

// MARK: - Document view inside the overlay

/// A click edits the cell under it; where that is impossible (read-only) it
/// places the caret in the table, which reveals its source.
final class WideTableImageView: NSImageView {

    weak var ownerOverlay: WideTableOverlay?

    /// Focus the cell under `event` in this table's native cell editor.
    private func beginCellEditing(_ event: NSEvent) -> MarkdownTableEditingSession? {
        guard let overlay = ownerOverlay,
              let coordinator = overlay.ownerTextView?.delegate as? NativeTextViewCoordinator else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        let session = coordinator.tableEditingSession
        return session.begin(range: overlay.sourceRange, point: point, in: self) ? session : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let session = beginCellEditing(event) else { return super.menu(for: event) }
        return session.contextMenu(for: event) { session.editor.standardMenu(for: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let overlay = ownerOverlay, let textView = overlay.ownerTextView as? NativeTextView,
              let painted = textView.selectionPaintedTable(image, tableRange: overlay.sourceRange) else {
            super.draw(dirtyRect)
            return
        }
        // As in the text: the page colour hides the selection band, then the covered cells.
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        painted.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let overlay = ownerOverlay,
              let textView = overlay.ownerTextView else {
            super.mouseDown(with: event)
            return
        }
        if let session = beginCellEditing(event) {
            // A drag from here selects cells, as in a narrow table.
            if event.clickCount == 1, !event.modifierFlags.contains(.shift) { session.trackSelection(from: event) }
            return
        }
        let location = overlay.anchorTextLocation
        let docLen = (textView.textStorage?.length ?? 0)
        guard location >= 0, location <= docLen else {
            super.mouseDown(with: event)
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
}

// MARK: - NativeTextView reconcile extension

extension NativeTextView {

    /// Coalesced reconcile request (resize fires bursts). ALWAYS deferred to the next runloop turn:
    /// the reconcile runs a viewport layout pass, which must never fire
    /// synchronously inside a restyle (it can shift the scroll position under
    /// the caret-pin).
    func updateWideTableOverlays() {
        if pendingWideTableOverlayUpdate { return }
        pendingWideTableOverlayUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingWideTableOverlayUpdate = false
            self.performWideTableOverlayUpdate()
        }
    }

    /// Cheap per-frame overlay shift when the container moves the text view
    /// vertically (header band growing/collapsing). Breakout overlays are
    /// SIBLINGS in the container whose frames bake in the text view's offset
    /// at update time; non-breakout overlays are text-view subviews and move
    /// with it automatically.
    func shiftWideTableOverlays(byY deltaY: CGFloat) {
        guard wideTableBreakoutActive, !wideTableOverlays.isEmpty else { return }
        for (_, overlay) in wideTableOverlays {
            var f = overlay.frame
            f.origin.y += deltaY
            overlay.frame = f
        }
    }

    /// Cheap per-frame overlay reposition on width change (no layout) — keeps tables glued to the text during resize.
    func repositionWideTableOverlaysForWidthChange(insetDelta: CGFloat) {
        guard configuration.readingWidth != nil, !wideTableOverlays.isEmpty else { return }
        // Overlays live in the full-width reading-column container; use its width.
        var stripsStale = false
        for (sourceID, overlay) in wideTableOverlays {
            var f = overlay.frame
            f.origin.x = 0
            f.size.width = wideTableRightEdge(sourceID: sourceID)
            overlay.frame = f
            overlay.leftContentInset = max(0, overlay.leftContentInset + insetDelta)
            // A table that crossed the lane's edge needs its scroller strip added or
            // dropped: the full reconcile (coalesced) restyles it.
            if let document = overlay.documentView {
                let reservesStrip = overlay.frame.height - document.frame.height > 0.5
                if reservesStrip == wideTableLaneFits(width: document.frame.width) { stripsStale = true }
            }
        }
        if stripsStale { updateWideTableOverlays() }
    }

    /// The character range TextKit 2 currently lays out for real — the
    /// viewport plus its over-scroll margin (`viewportRange`). Geometry
    /// outside it is ESTIMATED and mutually inconsistent (WWDC21: "layout
    /// information for elements outside the viewport might not be accurate"),
    /// so overlay frames are only ever DERIVED inside this band. nil = no
    /// viewport yet (mount / re-parent transition). Internal for the test
    /// oracles, which assert the same band rule.
    var viewportCharacterRange: NSRange? {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return nil }
        let location = tcs.offset(from: tcs.documentRange.location, to: viewport.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: viewport.endLocation)
        guard location != NSNotFound, end != NSNotFound, end > location else { return nil }
        return NSRange(location: location, length: end - location)
    }

    /// Reconcile overlays to the ONE invariant: a grid exists iff its table's
    /// anchor attribute lies inside the laid-out viewport band and its anchor
    /// line is measurable. No document-wide ensureLayout, no offscreen grids —
    /// there is nothing to position out there but estimates. Tables scrolling
    /// into the band get their grid from the draw-time glue below, which
    /// re-requests this reconcile the moment their fragment first draws.
    ///
    /// Viewport-pinned: the body's per-anchor ensureLayout can REVISE estimated
    /// heights of visible paragraphs, which would pan the view one async turn
    /// after the interaction (field: +55pt "view still jumps on select") — the
    /// shared pin keeps the on-screen anchor stationary. No `settle` closure:
    /// the body already ensures the layout it depends on.
    func performWideTableOverlayUpdate() {
        guard !isHiddenOrHasHiddenAncestor else {
            pendingDeferredWideTableOverlayUpdate = true
            return
        }
        pendingDeferredWideTableOverlayUpdate = false
        // Mid-zoom the reconcile's per-anchor ensureLayout revises estimated
        // heights and its viewport pin restores by SCROLLING — per magnify
        // frame that is visible jitter (ADR-0019). Defer past the zoom: retry
        // after the settle debounce (bounded cadence, no runloop spin).
        if let clamped = enclosingScrollView as? ClampedScrollView, clamped.isZoomInProgress {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                self?.updateWideTableOverlays()
            }
            return
        }
        preservingViewportAnchor { performWideTableOverlayUpdateBody() }
    }

    private func performWideTableOverlayUpdateBody() {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager else {
            removeAllWideTableOverlays()
            return
        }

        // Zoom-aware (ADR-0019): under magnification the display band targets
        // the effective width, same as the styler's fit width.
        let containerWidth = zoomedBlockFitWidth ?? container.size.width
        guard containerWidth.isFinite, containerWidth > 0,
              let band = viewportCharacterRange else {
            // Mid-transition pass (pane collapse, re-parent, pre-first-layout):
            // nothing is measurable, so nothing may stay painted. The next
            // successful pass (any restyle/resize/scroll trigger) restores.
            for (_, overlay) in wideTableOverlays { overlay.isHidden = true }
            return
        }
        let viewport = NSIntersectionRange(band, NSRange(location: 0, length: storage.length))
        // Breakout: tables span full width, flush with the text column's left.
        // Active in reading-column mode AND when zoom-out grew the container
        // past the prose column (ADR-0019).
        let breakout = wideTableBreakoutActive
        // Breakout host: the full-width container, else the text view itself.
        let host: NSView = breakout ? (superview ?? self) : self

        // NOTE: no layoutViewport() here — a viewport pass can RELOCATE the
        // viewport (adjust the scroll position), and this reconcile runs
        // asynchronously, outside any caret-pin: it must never move the view
        // (field: 55pt post-settle drift). The band is the one from the last
        // display pass — at most one turn stale, self-correcting — and each
        // in-band anchor gets a bounded ensureLayout below, which never
        // touches the scroll position.
        let tcs = tlm.textContentManager as? NSTextContentStorage
        var seenSourceIDs: Set<Int> = []
        var staleStrips: [NSRange] = []
        storage.enumerateAttribute(.scrollableBlockSourceID, in: viewport, options: []) { value, attrRange, _ in
            guard (self.delegate as? NativeTextViewCoordinator)?.foldLayout.hiddenRange(containing: attrRange.location) == nil,
                  let sourceID = value as? Int,
                  let image = storage.attribute(.renderedBlockImage, at: attrRange.location, effectiveRange: nil) as? NSImage else { return }
            if let tcs,
               let start = tcs.location(tcs.documentRange.location, offsetBy: attrRange.location),
               let end = tcs.location(start, offsetBy: attrRange.length),
               let textRange = NSTextRange(location: start, end: end) {
                tlm.ensureLayout(for: textRange)
            }
            // ANCHOR-RELATIVE payload (see AnchorRelativeRange): rebased against
            // the attribute's CURRENT location, so edits above the table can't
            // corrupt the derived source range / anchor bookkeeping.
            let sourceRange = (storage.attribute(.markdownTableSourceRange, at: attrRange.location, effectiveRange: nil) as? NSValue)
                .map { AnchorRelativeRange.decode($0, anchorLocation: attrRange.location) }
                ?? attrRange
            let sourceModel: MarkdownTableModel?
            if sourceRange.location >= 0,
               sourceRange.length >= 0,
               NSMaxRange(sourceRange) <= (textStorage?.length ?? 0) {
                sourceModel = MarkdownTableModel.parse((textStorage?.mutableString ?? "").substring(with: sourceRange))
            } else {
                sourceModel = nil
            }

            let anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            // An unmeasurable anchor is deliberately NOT marked as seen: the
            // removal sweep below then drops any stale overlay for it, and the
            // draw-time glue re-creates the overlay as soon as the anchor
            // becomes drawable — a missing grid beats a misplaced one.
            guard !anchorRect.isEmpty else { return }
            seenSourceIDs.insert(sourceID)

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat) ?? image.size.height
            // The window changed width since the table was styled: a strip reserved
            // for a table that now fits the lane, or missing for one that no longer
            // does, is fixed by restyling the table once this pass is done.
            let reservesStrip = totalHeight - image.size.height > 0.5
            if reservesStrip == wideTableLaneFits(width: image.size.width) { staleStrips.append(sourceRange) }
            let (overlayFrame, leftContentInset) = wideTableOverlayGeometry(
                anchorRect: anchorRect,
                totalHeight: totalHeight,
                containerWidth: containerWidth,
                sourceID: sourceID
            )

            if let existing = wideTableOverlays[sourceID] {
                existing.isHidden = false   // undo a transition-pass hide
                // A zoom settle can flip the breakout mode (container grows past
                // the column ⟺ shrinks back) — the overlay must live in the
                // host whose coordinate space its frame is derived in, or it
                // could neither draw nor hit-test where the geometry puts it.
                if existing.superview !== host {
                    guard detachTableEditor(from: existing) else { return }
                    existing.superview?.setNeedsDisplay(existing.frame)
                    host.addSubview(existing)
                }
                // Exact gate (tolerance 0): the reconcile is the authoritative
                // placement pass, so any drift repositions and the inset is set
                // unconditionally, as before.
                applyOverlayGeometry(existing, frame: overlayFrame, leftContentInset: leftContentInset, host: host, tolerance: 0)
                existing.updateImage(image)
                existing.updateSource(model: sourceModel, sourceRange: sourceRange)
                // The anchor must be where the ANCHOR ATTRIBUTE lives, not the
                // source range's start: realign validates (and measures) at this
                // location. They coincide for tables, but a diagram fence's
                // sourceRange starts at the ``` while its anchor sits inside the
                // content — the mismatch made every scroll tick hide the overlay
                // as unvalidatable and the reconcile re-show it (scroll flicker).
                existing.anchorTextLocation = attrRange.location
            } else {
                let overlay = WideTableOverlay(
                    sourceID: sourceID, image: image,
                    ownerTextView: self, anchorLocation: attrRange.location
                )
                overlay.anchorTextLocation = attrRange.location   // see above
                overlay.frame = overlayFrame
                overlay.leftContentInset = leftContentInset
                // In the window before the cell session mounts on it: a narrow
                // table that turned wide mid-edit gives its focused cell the
                // keyboard back only from a canvas that has a window.
                host.addSubview(overlay)
                overlay.updateSource(model: sourceModel, sourceRange: sourceRange)
                wideTableOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        // TOTAL sweep: anything not positioned this pass — out of the band,
        // orphaned by an edit, or unmeasurable — is deleted. Scroll-in
        // recreation is the draw glue's job, and the positional sourceID keeps
        // a re-created table's horizontal offset (tableHorizontalScrollOffsets
        // outlives the view).
        for (sourceID, overlay) in wideTableOverlays where !seenSourceIDs.contains(sourceID) {
            guard detachTableEditor(from: overlay) else { continue }
            host.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
        refreshInlineTableEditor()
        if !staleStrips.isEmpty, let coordinator = delegate as? NativeTextViewCoordinator {
            DispatchQueue.main.async { [weak coordinator] in
                MainActor.assumeIsolated { for range in staleStrips { coordinator?.restyleTableNow(range) } }
            }
        }
    }

    /// Whether a wide table of `width` fits the reference editor's lane: from the text
    /// column to the editor's right edge (breakout only), so nothing scrolls.
    func wideTableLaneFits(width: CGFloat) -> Bool {
        guard wideTableBreakoutActive, superview != nil else { return false }
        let columnLeft = frame.origin.x + textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        // The comment rail's keepout counts even for a freed table, so its strip never flips.
        return width <= wideTableRightEdge(sourceID: nil) - columnLeft + 0.5
    }

    /// Where a breakout table may reach: the editor's right edge, or short of
    /// the comment lane (doc 25 §0) unless the comments freed it into the lane.
    func wideTableRightEdge(sourceID: Int?) -> CGFloat {
        let full = (superview ?? self).bounds.width
        guard commentTableKeepout > 0, !(sourceID.map { tablesFreedIntoCommentLane.contains($0) } ?? false) else { return full }
        return max(0, full - commentTableKeepout)
    }

    /// Before removing or reparenting a disposable overlay, move its input to
    /// the stable document view. Protected input defers this teardown.
    private func detachTableEditor(from overlay: WideTableOverlay) -> Bool {
        guard let session = (delegate as? NativeTextViewCoordinator)?.tableEditingSession,
              session.grid?.isDescendant(of: overlay) == true else { return true }
        return session.detachPresentation()
    }

    /// Drop overlays synchronously after the file-switch path retires its input.
    func removeAllWideTableOverlays() {
        for (sourceID, overlay) in wideTableOverlays {
            guard detachTableEditor(from: overlay) else { continue }
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
    }

    /// Overlay frame + left inset from the anchor line's rect (text-container
    /// coordinates). The ONE formula shared by the reconcile walk above and the
    /// draw-time glue below, so the two can't disagree about where a table sits.
    func wideTableOverlayGeometry(
        anchorRect: CGRect,
        totalHeight: CGFloat,
        containerWidth: CGFloat,
        sourceID: Int? = nil
    ) -> (frame: NSRect, leftContentInset: CGFloat) {
        let breakout = wideTableBreakoutActive
        let host: NSView = breakout ? (superview ?? self) : self
        let viewWidth = breakout ? wideTableRightEdge(sourceID: sourceID) : host.bounds.width
        // In breakout the overlay lives in the container, so add the column's X
        // offset and the text view's Y offset (the scroll-away header band).
        let columnLeft = (breakout ? frame.origin.x : 0) + textContainerOrigin.x + anchorRect.minX
        let breakoutTop = frame.origin.y + textContainerOrigin.y + anchorRect.minY
        let overlayFrame: NSRect = breakout
            ? NSRect(x: 0, y: breakoutTop, width: viewWidth, height: totalHeight)
            : NSRect(x: columnLeft, y: textContainerOrigin.y + anchorRect.minY, width: containerWidth, height: totalHeight)
        // Breakout: table starts at the text column's left edge; the left margin is scrollable space.
        return (overlayFrame, breakout ? max(0, columnLeft) : 0)
    }

    /// Shared "track the anchor" apply for a wide-table overlay (was copy-pasted
    /// at the reconcile and realign sites): move `overlay` to `frame` —
    /// invalidating BOTH the vacated and the new rect in `host` so each redraws —
    /// when it has drifted past `tolerance`, then apply the left content inset
    /// under the same `tolerance`. `tolerance` 0 is the reconcile's exact gate
    /// (any drift repositions — identical to `!frame.equalTo`, and the inset
    /// guard collapses to "set on any change", i.e. the old unconditional set,
    /// since the setter self-guards at 0.5); 0.5 is the realign glue's sub-pixel
    /// deadband.
    private func applyOverlayGeometry(
        _ overlay: WideTableOverlay,
        frame: NSRect,
        leftContentInset: CGFloat,
        host: NSView?,
        tolerance: CGFloat
    ) {
        if overlay.frame.differs(from: frame, tolerance: tolerance) {
            // Invalidate both old + new region so the vacated area redraws.
            host?.setNeedsDisplay(overlay.frame)
            overlay.frame = frame
            host?.setNeedsDisplay(frame)
        }
        if abs(overlay.leftContentInset - leftContentInset) > tolerance {
            overlay.leftContentInset = leftContentInset
        }
    }

    /// Scroll-path glue: re-derive each overlay's frame from its anchor's
    /// CURRENT layout rect. Runs on each clip-view bounds change (cheap —
    /// O(#overlays), no layout forced). Frames are only ever derived inside
    /// the laid-out viewport band — outside it TextKit 2 has nothing but
    /// estimates, so a parked overlay is left untouched there and repositions
    /// the moment its anchor re-enters the band (which extends past the
    /// visible area, so it happens before the grid is seen). An overlay whose
    /// anchor can't be validated is hidden and handed to the reconcile —
    /// a missing grid beats a misplaced one.
    /// Where the table `sourceID`'s anchor attribute lives now, or nil when it
    /// is gone. The stored location is checked first, then windows widening
    /// around it: an edit above the table moved it by about its own length,
    /// and walking the attribute over a styled multi-megabyte note visits
    /// every run (100 ms a keystroke at 4.6 MB).
    private func currentAnchorLocation(of sourceID: Int, storedAt stored: Int, in storage: NSTextStorage) -> Int? {
        let length = storage.length
        if stored >= 0, stored < length,
           (storage.attribute(.scrollableBlockSourceID, at: stored, effectiveRange: nil) as? Int) == sourceID {
            return stored
        }
        for radius in [1_024, 65_536, length] {
            let start = max(0, min(stored, length) - radius)
            let window = NSRange(location: start, length: min(length, min(stored, length) + radius) - start)
            var found: Int?
            storage.enumerateAttribute(.scrollableBlockSourceID, in: window) { value, range, stop in
                guard (value as? Int) == sourceID else { return }
                found = range.location
                stop.pointee = true
            }
            if let found { return found }
            if window.length == length { break }
        }
        return nil
    }

    func realignWideTableOverlays() {
        refreshInlineTableEditor()
        // Frozen mid-zoom: anchor rects are estimate-churn then, and chasing
        // them repositions grids per magnify frame (ADR-0019). The settle's
        // reconcile re-derives every frame cleanly afterwards.
        if let clamped = enclosingScrollView as? ClampedScrollView, clamped.isZoomInProgress { return }
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              container.size.width.isFinite, container.size.width > 0 else { return }
        // Read the band as-is — realign runs synchronously inside restyle
        // paths (under the caret-pin) and on scroll ticks; forcing a viewport
        // pass here can shift the scroll position mid-pin. A band at most one
        // tick stale self-corrects on the next tick or via the reconcile.
        guard let band = viewportCharacterRange else { return }
        let viewport = NSIntersectionRange(band, NSRange(location: 0, length: storage.length))
        var needsReconcile = false

        // Tables that scrolled INTO the band (pure scrolling triggers no
        // restyle): request the coalesced reconcile that creates their grids.
        // Cheap — one attribute enumeration over the band, stops on first hit.
        storage.enumerateAttribute(.scrollableBlockSourceID, in: viewport, options: []) { value, _, stop in
            if let id = value as? Int, wideTableOverlays[id] == nil {
                needsReconcile = true
                stop.pointee = true
            }
        }
        for (sourceID, overlay) in wideTableOverlays {
            if (delegate as? NativeTextViewCoordinator)?.foldLayout.hiddenRange(containing: overlay.anchorTextLocation) != nil {
                overlay.isHidden = true
                continue
            }
            // An edit above the table shifts the text under the stored
            // location; follow the attribute to where it lives now rather than
            // hide a grid that is still right (the table blinked off and on
            // for a frame on every ⌘A format and undo).
            guard let loc = currentAnchorLocation(of: sourceID, storedAt: overlay.anchorTextLocation, in: storage) else {
                // The attribute is gone (edit inside the table, reveal, narrow
                // re-classification): this frame is unvalidatable. Hide it and
                // let the reconcile re-derive or delete it.
                if !overlay.isHidden {
                    overlay.superview?.setNeedsDisplay(overlay.frame)
                    overlay.isHidden = true
                }
                needsReconcile = true
                continue
            }
            overlay.anchorTextLocation = loc
            guard NSLocationInRange(loc, viewport) else {
                // Anchor scrolled OUT of the band. Pure scroll-out fires no
                // restyle, so without this the reconcile that sweeps
                // out-of-band overlays is never scheduled — the overlay
                // lingers in the hierarchy (and in breakout mode, where it is
                // a container sibling that does NOT scroll with the text, it
                // stays visibly parked over prose). Request the sweep.
                needsReconcile = true
                continue
            }
            let anchorRect = bridge.boundingRect(forCharacterRange: NSRange(location: loc, length: 1), in: container)
            guard !anchorRect.isEmpty else {
                // Fragment invalidated mid-reflow — unmeasurable, so the
                // current frame is unvalidatable too.
                if !overlay.isHidden {
                    overlay.superview?.setNeedsDisplay(overlay.frame)
                    overlay.isHidden = true
                }
                needsReconcile = true
                continue
            }
            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: loc, effectiveRange: nil) as? CGFloat)
                ?? overlay.frame.height
            let (overlayFrame, leftContentInset) = wideTableOverlayGeometry(
                anchorRect: anchorRect,
                totalHeight: totalHeight,
                containerWidth: zoomedBlockFitWidth ?? container.size.width,
                sourceID: sourceID
            )
            if overlay.isHidden {
                overlay.isHidden = false
                overlay.superview?.setNeedsDisplay(overlayFrame)
            }
            // Sub-pixel deadband (tolerance 0.5): realign runs on every scroll
            // tick, so layout noise must not re-lay the grid.
            applyOverlayGeometry(overlay, frame: overlayFrame, leftContentInset: leftContentInset, host: overlay.superview, tolerance: 0.5)
        }
        if needsReconcile {
            DispatchQueue.main.async { [weak self] in self?.updateWideTableOverlays() }
        }
    }

    /// Draw-time glue: when a table's anchor fragment draws — TextKit 2's own
    /// signal that the table is inside the laid-out band — a MISSING overlay
    /// re-requests the (coalesced) reconcile, which creates it. This is how
    /// grids materialize on scroll-in; the reconcile's total sweep is how they
    /// leave. A PRESENT overlay whose frame drifted from the drawn anchor rect
    /// gets a realign pass scheduled off the paint pass — realign re-derives
    /// from the then-current geometry rather than applying this (already aged)
    /// snapshot, so a mid-draw reflow can't park a stale frame.
    func syncWideTableOverlay(sourceID: Int, anchorRect: CGRect, totalHeight: CGFloat?) {
        guard let overlay = wideTableOverlays[sourceID] else {
            DispatchQueue.main.async { [weak self] in self?.updateWideTableOverlays() }
            return
        }
        guard let rawWidth = layoutBridge?.firstTextContainer?.size.width,
              rawWidth.isFinite, rawWidth > 0 else { return }
        let (overlayFrame, leftContentInset) = wideTableOverlayGeometry(
            anchorRect: anchorRect,
            totalHeight: totalHeight ?? overlay.frame.height,
            containerWidth: zoomedBlockFitWidth ?? rawWidth,
            sourceID: sourceID
        )
        let drifted = overlay.frame.differs(from: overlayFrame, tolerance: 0.5)
        guard drifted || abs(overlay.leftContentInset - leftContentInset) > 0.5 else { return }
        // Called mid-draw — defer the hierarchy mutation off the paint pass.
        DispatchQueue.main.async { [weak self] in self?.realignWideTableOverlays() }
    }
}

// MARK: - Geometry drift helper

private extension CGRect {
    /// True when any of the four axes differs from `other` by more than
    /// `tolerance` — the sub-pixel deadband the overlay glue uses so layout
    /// noise doesn't re-lay a grid. `tolerance` 0 ⟺ `!equalTo(other)`.
    func differs(from other: CGRect, tolerance: CGFloat) -> Bool {
        abs(origin.x - other.origin.x) > tolerance
            || abs(origin.y - other.origin.y) > tolerance
            || abs(size.width - other.size.width) > tolerance
            || abs(size.height - other.size.height) > tolerance
    }
}
