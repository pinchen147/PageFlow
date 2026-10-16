//
//  NativeTextViewContainer.swift
//  MarkdownEngine
//
//  Document view of the editor's scroll view. Hosts the `NativeTextView` plus two
//  optional siblings: the scroll-away header (a top band, stacked ABOVE the text view
//  with a disjoint frame) and, in reading-column mode, the full-width wide-table
//  overlays around the centered fixed-width column.
//
//  The header is a sibling rather than a subview of the text view because a subview
//  (reserving space via a `textContainerOrigin` shift) cannot be composited reliably:
//  during a responsive-scroll blit the cached body bitmap and the header's own
//  `NSHostingView` layer advance against slightly different origins, so the body
//  drifts up over the header's lower rows. No compositing fix can unify them
//  (NSHostingView always forces its own layer); with disjoint sibling frames the
//  overlap is geometrically impossible.
//

import AppKit

final class NativeTextViewContainer: NSView {
    /// Puts `view` above every wide-table overlay (adding it if needed),
    /// moving it only when an overlay is above it.
    func keepAboveWideTables(_ view: NSView) {
        guard let index = subviews.firstIndex(where: { $0 === view }) else {
            addSubview(view, positioned: .above, relativeTo: nil)
            return
        }
        if subviews[(index + 1)...].contains(where: { $0 is WideTableOverlay }) {
            addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    /// The body. Sizes its OWN height (content + overscroll); the container only moves
    /// it below the header band and sizes itself to the sum.
    weak var textView: NativeTextView?

    /// Reserved header band height (mirrors the clip's resolved height). Sole driver of
    /// the vertical stack: the text view sits at `y = headerHeight`.
    var headerHeight: CGFloat = 0 {
        didSet {
            guard abs(headerHeight - oldValue) > 0.01 else { return }
            if let textView {
                // Band height feeds the overscroll activation — re-run the policy
                // first (no re-measure; skipped when detached, e.g. teardown).
                if let scrollView = enclosingScrollView {
                    textView.reapplyOverscrollPolicy(for: scrollView)
                }
                // The viewport-fill inflation depends on the band height
                // (header + text view ≥ viewport); re-apply before the restack so a
                // short doc never grows a phantom scroll range.
                textView.applyManagedFrameSize(width: textView.frame.width)
            }
            restack(propagateWidth: false)
        }
    }

    private var isRestacking = false
    /// A restack requested WHILE one is already running (re-entrancy). Dropping it
    /// used to leave the container height stale versus the content — e.g. a block
    /// reveal/collapse grows the text view's final self-measure inside an outer
    /// restack, that nested `textViewDidResize → restack` gets swallowed, and the
    /// clip can then scroll past the (too-short) container into a BLANK document
    /// that stays blank. Instead we remember it and re-run after the outer pass.
    private var pendingRestackPropagateWidth: Bool?

    /// Flipped (top-left origin) to match `NSTextView`, so `y = headerHeight` means
    /// "below the header" and the text view's local space is a pure translation of the
    /// container's. A non-flipped container would invert the stack and break every
    /// `convert(_:to:)`-based coordinate path.
    override var isFlipped: Bool { true }

    /// Real scrollable height = header band + the text view's real content (no
    /// min-viewport inflation), so the scroll view can't scroll past actual content.
    var scrollableContentHeight: CGFloat {
        headerHeight + (textView?.scrollableContentHeight ?? 0)
    }

    /// Single layout method. Moves the text view below the header (ORIGIN only — never
    /// `setFrameSize`, so the text view's self-measure isn't re-triggered) and sizes the
    /// container to `headerHeight + textViewHeight` (min the viewport). The header clip
    /// is positioned by its own Auto Layout against this container, so it isn't touched.
    func restack(propagateWidth: Bool) {
        guard let textView else { return }
        // Re-entrancy: a nested restack must NOT be dropped (that strands the
        // container height stale → blank document). Remember it — OR-ing width
        // propagation so a swallowed width pass isn't downgraded — and re-run it
        // after the current pass. The `abs(... ) > 0.5` guards below make restack
        // idempotent, so the re-run chain converges in one or two passes.
        if isRestacking {
            pendingRestackPropagateWidth = (pendingRestackPropagateWidth ?? false) || propagateWidth
            return
        }
        isRestacking = true
        defer {
            isRestacking = false
            if let pending = pendingRestackPropagateWidth {
                pendingRestackPropagateWidth = nil
                restack(propagateWidth: pending)
            }
        }

        // Visual zoom (ADR-0019): the container AND the text view span the
        // LARGER of the prose width (viewport frame — what the column wraps
        // at, zoom-independent) and the effective width (viewport bounds —
        // grows on zoom-out). Wide block images then spill past the prose
        // column while staying INSIDE the text view — AppKit clips drawing at
        // view bounds, so a spill outside the view is simply cut. The wrap
        // width is protected by the container pin (`applyZoomWrapPinning`),
        // never by keeping the view narrow. Clip-view autoresizing hands this
        // method a frame-delta width that drifts from that rule under
        // magnification ≠ 1, so the corrected value is adopted here — the
        // `setFrameSize` at the bottom applies it (idempotent via the guards).
        var w = bounds.width
        if let scrollView = enclosingScrollView, scrollView.allowsMagnification,
           textView.configuration.readingWidth == nil {
            let prose = scrollView.contentView.frame.width
            let effective = scrollView.contentView.bounds.width
            if prose.isFinite, prose > 1, effective.isFinite, effective > 1 {
                w = max(prose, effective)
            }
        }
        // Width propagation happens ONLY from the scroll-view-driven path; a height-only
        // restack must never resize the text view (that would re-measure → loop).
        if propagateWidth {
            if textView.configuration.readingWidth != nil {
                // Reading column: the column keeps its fixed width; re-center its X
                // (and shift the wide-table overlay insets) instead of resizing.
                textView.centerReadingColumn(forClipWidth: w)
            } else {
                // Pin/release must never let the container track a TRANSIENT
                // view width (each tracked change is a full-document rewrap):
                // growing → pin FIRST (tracking off before the width jumps);
                // shrinking to prose → resize FIRST (pin still holds the wrap),
                // release after (tracking resumes at the identical width).
                let willPin = textView.zoomIndependentProseWidth.map { w > $0 + 0.5 } ?? false
                if willPin { textView.applyZoomWrapPinning(forViewWidth: w) }
                if abs(textView.frame.width - w) > 0.5 {
                    textView.setFrameSize(NSSize(width: w, height: textView.frame.height))
                }
                if !willPin { textView.applyZoomWrapPinning(forViewWidth: w) }
            }
        }
        // Y: below the header band. X is owned by the reading-column centering
        // (0 in full-width mode — the zoomed-out column placement is the text
        // CONTAINER's inset, not the view's X).
        let x = textView.configuration.readingWidth != nil ? textView.frame.origin.x : 0
        if abs(textView.frame.origin.y - headerHeight) > 0.01 || abs(textView.frame.origin.x - x) > 0.01 {
            let deltaY = headerHeight - textView.frame.origin.y
            textView.setFrameOrigin(NSPoint(x: x, y: headerHeight))
            // Breakout wide-table overlays are siblings whose frames bake in the
            // text view's offset — keep them glued to their anchor paragraphs.
            textView.shiftWideTableOverlays(byY: deltaY)
        }
        let viewportH = enclosingScrollView?.contentView.bounds.height ?? 0
        let totalH = max(headerHeight + textView.frame.height, viewportH)
        // Width too: the zoom-corrected `w` above can differ from the current
        // frame while the height is already settled (a pure zoom change).
        if abs(frame.height - totalH) > 0.5 || abs(frame.width - w) > 0.5 {
            setFrameSize(NSSize(width: w, height: totalH))
        }
    }

    /// The text view calls this after it self-resizes its height.
    func textViewDidResize() {
        guard !isRestacking else { return }
        restack(propagateWidth: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width came from the scroll view's clip view (autoresizing); propagate it.
        restack(propagateWidth: true)
    }
}

extension NSScrollView {
    /// Editor text view inside the container document view.
    var nativeTextView: NativeTextView? {
        (documentView as? NativeTextViewContainer)?.textView
    }

    /// The view that should hold the keyboard for this editor: the focused table
    /// cell while one is being edited, otherwise the text view.
    public var markdownEditorKeyView: NSView? {
        guard let textView = nativeTextView else { return nil }
        return (textView.delegate as? NativeTextViewCoordinator)?.tableEditingSession.preferredResponder ?? textView
    }
}
