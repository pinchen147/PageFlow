//
//  NativeTextView+Reveal.swift
//  MarkdownEngine
//
//  Bringing a location on screen. Every far jump (Find, an outline click, a
//  reading-position restore, the caret's own reveal) lands through one path,
//  `scroll(by:landing:)`: a target far from the viewport is placed by TextKit's
//  estimates for everything above it, and the viewport pass at the new origin
//  replaces them and moves the target under a fixed clip — about 2 000 pt on a
//  2 MB note. Landing runs that pass at once and corrects by however far the
//  target moved, so the reader arrives where asked without laying out the note
//  in between (ADR-0020).
//

import AppKit

extension NativeTextView {
    /// Every reveal — AppKit's caret auto-scroll, find, outline jumps, the
    /// harness — lands by LOCATION: the target paragraph is laid out on its
    /// own (nothing else materializes) and the clip moves the least distance
    /// that shows it. AppKit's own implementation is a no-op for a range
    /// TextKit 2 has not laid out yet, which is every range far from the
    /// viewport; a range with any part already on screen is left alone (⌘A,
    /// an undo that re-selects the whole note), as AppKit does.
    override func scrollRangeToVisible(_ range: NSRange) {
        if suppressAutoRevealOnce {
            suppressAutoRevealOnce = false
            return
        }
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let scrollView = enclosingScrollView else { return }
        let length = (textStorage?.length ?? 0)
        guard length > 0, range.location >= 0 else { return }
        let loc = min(range.location, length - 1)
        var viewportStart = NSNotFound
        var viewportEnd = 0
        if let viewport = tlm.textViewportLayoutController.viewportRange {
            viewportStart = tcm.offset(from: tcm.documentRange.location, to: viewport.location)
            viewportEnd = tcm.offset(from: tcm.documentRange.location, to: viewport.endLocation)
        }
        // A range with any part inside the laid-out viewport is left alone (⌘A,
        // an undo that re-selects the whole note), as AppKit does.
        if range.length > 0, viewportStart != NSNotFound {
            let visible = NSRange(location: viewportStart, length: max(0, viewportEnd - viewportStart))
            if NSIntersectionRange(range, visible).length > 0 || NSLocationInRange(visible.location, range) { return }
        }
        let inViewport = viewportStart != NSNotFound && loc >= viewportStart && loc < max(viewportEnd, viewportStart + 1)
        if inViewport {
            // AppKit's own reveal for a location the viewport pass has laid out.
            // A fragment's frame re-read right after an edit can sit a whole
            // estimate revision away from where the pass drew it (the same
            // paragraph read 19977 → 20363 → 17722 pt across three consecutive
            // passes on a 490 KB note); judging it against the clip origin sent
            // an on-screen caret 1800 pt up on the first keystroke in a formula.
            // AppKit's implementation does not jump there; only the far case —
            // a location nothing has laid out, where AppKit is a no-op — is
            // handled below.
            ScrollTrace.stamp("scrollRangeToVisible(loc=\(range.location), super)")
            super.scrollRangeToVisible(range)
            return
        }
        // What must be visible is the range's first LINE (a revealed block's
        // paragraph can be a screen tall).
        guard let line = lineFrame(at: loc) else { return }
        let visible = visibleRect
        let margin: CGFloat = 24
        let delta: CGFloat
        if line.minY < visible.minY + scrollView.contentInsets.top + margin {
            delta = line.minY - margin - scrollView.contentInsets.top - visible.minY
        } else if line.maxY > visible.maxY - margin {
            delta = line.maxY + margin - visible.maxY
        } else {
            return
        }
        ScrollTrace.stamp("scrollRangeToVisible(loc=\(range.location))")
        scroll(by: delta, landing: loc)
    }

    /// The line holding `offset`, in the text view's coordinates, read from the
    /// geometry TextKit draws — the fragment frame plus its line fragment, the
    /// model the viewport pin measures in. Lays out that one paragraph if it is
    /// still an estimate; nothing else materializes.
    func lineFrame(at offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = tlm.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false)
                ?? fragment.textLineFragments.last else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        return line.typographicBounds.offsetBy(dx: origin.x + textContainerOrigin.x,
                                               dy: origin.y + textContainerOrigin.y)
    }

    /// Moves the clip by `delta`, then lands the line holding `offset` where
    /// that move put it: after each move TextKit's viewport pass runs at the new
    /// origin and the clip follows the line by however far the pass moved it,
    /// up to six times (2 MB note: 327, 6, then 0 pt; a far jump on a chain of
    /// estimates can need more).
    func scroll(by delta: CGFloat, landing offset: Int) {
        guard let scrollView = enclosingScrollView, let tlm = textLayoutManager,
              var landed = lineFrame(at: offset)?.minY else { return }
        let clip = scrollView.contentView
        var correction = delta
        for pass in 0..<6 {
            ScrollTrace.stamp(pass == 0 ? "land(offset=\(offset))" : "land(offset=\(offset), reland)")
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + correction))
            scrollView.reflectScrolledClipView(clip)
            (scrollView as? ClampedScrollView)?.clampToInsets()
            tlm.textViewportLayoutController.layoutViewport()
            ensureVisibleLayout()
            guard let now = lineFrame(at: offset)?.minY else { return }
            correction = now - landed
            landed = now
            guard correction.isFinite, abs(correction) > 0.5 else { return }
        }
    }

    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    ///
    /// Enumerates from the VIEWPORT TOP, not `documentRange.location`. Starting at
    /// the document start with `.ensuresLayout` forces a layout pass over every
    /// fragment above the fold — O(document) on a long doc, and this runs on every
    /// restyle (per keystroke) and every scroll tick. The viewport-layout controller
    /// already knows its visible range (allocation-free); a point lookup covers the
    /// window before the first viewport pass populates it; the document start is the
    /// final fallback. The `fr.maxY < visTop` skip is kept as a cheap safety net for
    /// the one fragment that may straddle the top edge.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visTop = visibleRect.minY
        let visBot = visibleRect.maxY
        let viewport = tlm.textViewportLayoutController
        // Right after a jump (a scroller drag, a caret far off screen) the
        // viewport is still the OLD one, and walking from it laid out every
        // paragraph in between — most of a long note (D12). TextKit lays out
        // the viewport at the new origin first, so the walk starts on screen.
        if !viewport.viewportBounds.intersects(visibleRect.insetBy(dx: 0, dy: -visibleRect.height)) {
            viewport.layoutViewport()
        }
        let startLocation = viewport.viewportRange?.location
            ?? tlm.textLayoutFragment(for: NSPoint(x: 0, y: max(visTop, 0)))?.rangeInElement.location
            ?? tlm.documentRange.location

        tlm.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let fr = fragment.layoutFragmentFrame
            if fr.maxY < visTop { return true }
            if fr.minY > visBot { return false }
            return true
        }
    }
}
