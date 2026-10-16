//
//  NativeTextView+FrameAndOverscroll.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Frame-size management, content-height measurement (TextKit-2 last-fragment
//  + end-segment pattern), bottom-overscroll application, and transient-shrink
//  scroll-position restoration.
//

import AppKit
#if DEBUG
import os
#endif

#if DEBUG
// Debug-only viewport-anchor tracing. Entirely opt-in: when the environment
// variable PAGEFLOW_ANCHOR_TRACE is unset (release builds and normal dev runs)
// every probe below short-circuits on `anchorTraceEnabled` BEFORE building any
// string, so the click hot path stays O(1) and allocation-free. Launch with
// `PAGEFLOW_ANCHOR_TRACE=1` and read the trace in Console.app (subsystem
// com.pageflow.MarkdownEngine, category AnchorTrace).
private let anchorTraceEnabled = ProcessInfo.processInfo.environment["PAGEFLOW_ANCHOR_TRACE"] != nil
private let anchorTraceLog = OSLog(subsystem: "com.pageflow.MarkdownEngine", category: "AnchorTrace")

@inline(__always)
private func anchorTrace(_ message: @autoclosure () -> String) {
    guard anchorTraceEnabled else { return }
    let text = message()
    os_log("%{public}@", log: anchorTraceLog, type: .default, text)
    // stderr as well: the harness captures stderr, not the system log.
    FileHandle.standardError.write(Data("ANCHOR \(text)\n".utf8))
}

/// One-line, whitespace-flattened, length-capped preview of the paragraph that
/// contains `loc`. Trace-only — it allocates, but never on the release path.
private func anchorLinePreview(_ loc: Int, in ns: NSString) -> String {
    guard loc >= 0, loc < ns.length else { return "<oob>" }
    let para = ns.paragraphRange(for: NSRange(location: loc, length: 0))
    let flattened = ns.substring(with: para)
        .replacingOccurrences(of: "\n", with: "\u{23CE}")
        .replacingOccurrences(of: "\t", with: "\u{2192}")
    return flattened.count > 48 ? String(flattened.prefix(48)) + "\u{2026}" : flattened
}
#endif

extension NativeTextView {
    /// The ONE mechanism for "a height-changing reflow must not pan the view":
    /// capture the pin character's viewport-relative Y (the caret when visible —
    /// that's where the user is looking — else the first visible character),
    /// run `body`, let `settle` bring TextKit's layout current up to the pin,
    /// then correct the scroll so the pin's on-screen Y is unchanged. A
    /// height-neutral reflow yields delta≈0 and never scrolls.
    ///
    /// `settle` receives the pin location so a caller that must force layout can
    /// bound it to the pin (the coordinator's structural restyles run a viewport
    /// pass + ensureLayout-to-pin here; the async overlay reconcile already
    /// ensures per-anchor layout in its body, so it passes the default no-op).
    /// A single source of truth for the scroll-correction math, which was
    /// duplicated between the coordinator and the overlay reconcile and prone
    /// to silent drift.
    ///
    /// Attribute-only callers keep the pin's character offset. Source edits
    /// supply `mapPin` so the measurement follows the same source paragraph
    /// through inserted or removed text. Resolve the mapped location against
    /// the current source length, which can differ from the captured source.
    func preservingViewportAnchor(settle: (Int) -> Void = { _ in }, mapPin: ((Int) -> Int)? = nil, tag: String = "pin", _ body: () -> Void) {
        if mapPin == nil, continueBulkViewportAnchor(body) { return }
        guard let scrollView = enclosingScrollView,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer else { body(); return }
        let ns: NSString = textStorage?.mutableString ?? ""
        guard ns.length > 0 else { body(); return }
        let visible = visibleRect
        guard visible.height > 0 else { body(); return }
        // A pin inside another pin's body measures a layout the outer body
        // has already invalidated (every fragment estimated after a whole-note
        // replacement): its "before" is fiction, its scroll is overridden by
        // the outer pin's own correction, and its settle lays out the document
        // twice. The outer pin covers everything its body does.
        if viewportPinDepth > 0 {
            #if DEBUG
            anchorTrace("ANCHOR-NESTED[\(tag)]: inside an outer pin, no measurement")
            #endif
            body(); return
        }
        viewportPinDepth += 1
        defer { viewportPinDepth -= 1 }

        // Pin Y measured in ONE space: text-view document coordinates (bridge
        // container coords + textContainerOrigin). Do NOT use
        // viewRect(forCharacterRange:) — it converts for popup positioning and
        // mixing it with visibleRect double-counts the scroll offset.
        //
        // The pin is the TOP of the paragraph (layout fragment) holding `loc`,
        // not the rect of its line. A paragraph's top moves only when the
        // content above it moves — the one motion a viewport pin exists to
        // cancel — and is untouched by anything inside the paragraph: its
        // spacing-before, its line count, a rendered block collapsing to
        // source. The line rect was not: a caret entering a rendered math block
        // (spacing-before 16 while rendered, none as source) measured 16 pt
        // nearer the top after the reveal, and the pin "corrected" the viewport
        // by 16 pt — the jump on every click into a formula, and a 16 pt drift
        // left behind on every edit of one. The pin's own paragraph is laid out
        // if it is still an estimate (one paragraph, as the line rect used to
        // force); a fragment that stays estimated reports nil and the callers
        // walk to a laid-out neighbour.
        func pinY(_ loc: Int) -> CGFloat? {
            guard loc >= 0, loc < (textStorage?.length ?? 0),
                  let tlm = textLayoutManager, let tcm = tlm.textContentManager,
                  let location = tcm.location(tcm.documentRange.location, offsetBy: loc),
                  var fragment = tlm.textLayoutFragment(for: location) else { return nil }
            if fragment.state != .layoutAvailable {
                tlm.ensureLayout(for: NSTextRange(location: location))
                guard let laidOut = tlm.textLayoutFragment(for: location) else { return nil }
                fragment = laidOut
            }
            guard fragment.state == .layoutAvailable else { return nil }
            return fragment.layoutFragmentFrame.minY + textContainerOrigin.y
        }

        // A location's LINE decides whether it is on screen (its paragraph may
        // start above the viewport and still be the right pin), and it is what
        // the walk below a collapsed block tests: every source character of a
        // collapsed block reports the one image line, so the walk steps over
        // the whole block instead of stopping on an interior fragment.
        func lineY(_ loc: Int) -> CGFloat? {
            guard loc >= 0, loc < ns.length else { return nil }
            let r = bridge.boundingRect(forCharacterRange: NSRange(location: loc, length: 1), in: container)
            guard r.height >= 0.01 else { return nil }
            return r.minY + textContainerOrigin.y
        }

        // Pin the caret when it's on screen, else the first visible character.
        // (Broken out of the original `if let y = pinY(pinLoc)` so the trace can
        //  report whether pinY(caret) was nil and whether the fallback ran; the
        //  control flow is identical to the old two-branch form.)
        let caretLoc = min(max(0, selectedRange().location), ns.length - 1)
        let caretY = lineY(caretLoc)
        #if DEBUG
        anchorCensusTrace("pin.afterCaretLineY")
        #endif
        let caretOnScreen = caretY.map { $0 >= visible.minY && $0 <= visible.maxY } ?? false
        var pinLoc = caretLoc
        if !caretOnScreen {
            var fraction: CGFloat = 0
            let probe = CGPoint(x: visible.midX - textContainerOrigin.x,
                                y: visible.minY + 1 - textContainerOrigin.y)
            let probed = bridge.characterIndex(for: probe, in: container,
                                               fractionOfDistanceBetweenInsertionPoints: &fraction)
            // A probe into an ESTIMATED / collapsed overlay-band region (viewport
            // top sitting over a wide table) returns NSNotFound; keep the
            // caret-clamped index so the resolver below walks from a real
            // location instead of the sentinel.
            if probed != NSNotFound { pinLoc = probed }
            #if DEBUG
            anchorCensusTrace("pin.afterProbe")
            #endif
            // The pin may still land in a COLLAPSED standalone-image band (a tall
            // diagram / block-math scrolled partly off the top): all of that
            // block's source chars report the single image-top Y, which is
            // off-screen AND does not move when the block reveals its shorter
            // source — so pinning it lets the visible content below slide by the
            // whole height delta (the reveal-direction jump). A non-nil but
            // off-screen pinY is the tell; walk DOWN to the first line the user
            // can actually see. (nil pinY still flows to `nearestLaidOutPin` below,
            // the untouched wide-table-overlay path.)
            if let y = lineY(pinLoc), y < visible.minY || y > visible.maxY,
               let onScreen = firstOnScreenPinBelow(pinLoc, lineY: lineY, visible: visible) {
                pinLoc = onScreen
            }
        }

        // A pin inside a collapsed block (a rendered table's hidden rows, a
        // formula's hidden source) sits on a 1 pt fragment whose top moves by the
        // image height the moment the block reveals or is base-styled; the
        // block's anchor paragraph — the first one, carrying the image — keeps
        // its top. Pin that paragraph instead.
        #if DEBUG
        anchorCensusTrace("pin.afterWalk")
        #endif
        pinLoc = anchorParagraphOfCollapsedBlock(containing: pinLoc)

        // Resolve a pin that HAS real layout. `pinLoc` can land in an ESTIMATED
        // or collapsed overlay-band fragment (probe → NSNotFound above, or a
        // caret inside a wide-table band) whose pinY is nil; the old code then
        // skipped the anchor entirely and let the reflow pan freely — the
        // click-jump on table-adjacent lines. Walk to the nearest char that
        // ALREADY has real layout instead. Existing layout only (no ensureLayout
        // here) so beforeY stays in the pre-settle coordinate space the delta
        // math depends on — the unpinned `body()` is now a true last resort.
        let resolvedBefore: (loc: Int, y: CGFloat)?
        if let y = pinY(pinLoc) {
            resolvedBefore = (pinLoc, y)
        } else {
            resolvedBefore = nearestLaidOutPin(from: pinLoc, pinY: pinY)
        }
        guard let (resolvedPin, beforeY) = resolvedBefore else {
            #if DEBUG
            anchorTrace(
                "ANCHOR-SKIP[\(tag)]: no laid-out pin on screen, restyle ran UNPINNED — "
                + "pinLoc=\(pinLoc) caretLoc=\(caretLoc) usedFallback=\(!caretOnScreen) "
                + "pinY(caret)=\(caretY.map { String(format: "%.1f", $0) } ?? "nil") "
                + "line=\"\(anchorLinePreview(pinLoc, in: ns))\""
            )
            #endif
            body(); return
        }
        pinLoc = resolvedPin
        let beforeOffset = beforeY - visible.minY
        #if DEBUG
        let censusBefore = anchorTraceEnabled ? laidOutCensus(upTo: pinLoc) : (0, 0)
        let laidOutSetBefore = anchorTraceEnabled ? laidOutOffsets(upTo: pinLoc) : []
        let docHBefore = textLayoutManager?.usageBoundsForTextContainer.height ?? -1
        #endif

        #if DEBUG
        let pinLocBeforeMap = pinLoc
        let previewBeforeMap = anchorTraceEnabled ? anchorLinePreview(pinLoc, in: ns) : ""
        #endif
        body()
        if let mapPin { pinLoc = mapPin(pinLoc) }
        #if DEBUG
        let censusAfterBody = anchorTraceEnabled ? laidOutCensus(upTo: pinLoc) : (0, 0)
        let docHAfterBody = textLayoutManager?.usageBoundsForTextContainer.height ?? -1
        if anchorTraceEnabled, censusAfterBody.0 < censusBefore.0 {
            anchorTrace("BODY-INVALIDATED[\(tag)]: \(invalidatedFragmentSpans(upTo: pinLoc, laidOutBefore: laidOutSetBefore))")
        }
        #endif
        settle(pinLoc)

        guard let afterY = pinY(pinLoc) else {
            #if DEBUG
            anchorTrace(
                "ANCHOR-LOST[\(tag)]: pin vanished after body — NO scroll correction — "
                + "pinLoc=\(pinLoc) beforeOffset=\(String(format: "%.1f", beforeOffset)) "
                + "line=\"\(anchorLinePreview(pinLoc, in: ns))\""
            )
            #endif
            return
        }
        let delta = (afterY - beforeOffset) - visibleRect.minY
        let willCorrect = abs(delta) > 0.5
        #if DEBUG
        anchorTrace(
            "ANCHOR[\(tag)]: pinLoc=\(pinLoc) caretLoc=\(caretLoc) usedFallback=\(!caretOnScreen) "
            + "pinY(caret)=\(caretY.map { String(format: "%.1f", $0) } ?? "nil") "
            + "beforeY=\(String(format: "%.1f", beforeY)) "
            + "beforeOffset=\(String(format: "%.1f", beforeOffset)) "
            + "afterY=\(String(format: "%.1f", afterY)) "
            + "delta=\(String(format: "%.1f", delta)) corrected=\(willCorrect) "
            + "laidOutAbove=\(censusBefore.0)/\(censusBefore.1)→body \(censusAfterBody.0)/\(censusAfterBody.1)→settle \(laidOutCensus(upTo: pinLoc).0)/\(laidOutCensus(upTo: pinLoc).1) "
            + "docH=\(String(format: "%.0f", docHBefore))→body \(String(format: "%.0f", docHAfterBody))→settle \(String(format: "%.0f", textLayoutManager?.usageBoundsForTextContainer.height ?? -1)) "
            + "line=\"\(anchorLinePreview(pinLoc, in: textStorage?.mutableString ?? ""))\""
            + (mapPin != nil ? " mapped \(pinLocBeforeMap)→\(pinLoc) from=\"\(previewBeforeMap)\"" : "")
        )
        #endif
        guard willCorrect else { return }
        ScrollTrace.stamp(String(format: "viewportPin(Δ%.1f, pinLoc=%d, %@)", delta, pinLoc, tag))
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }

    #if DEBUG
    /// Trace-only: (laid-out, total) layout fragments from the document start
    /// up to `loc`, without forcing layout — how much of the chain above the
    /// pin is real rather than estimated.
    var anchorTraceIsEnabled: Bool { anchorTraceEnabled }
    func anchorTraceLine(_ text: String) { anchorTrace(text) }

    func anchorCensusTrace(_ tag: String) {
        guard anchorTraceEnabled else { return }
        let loc = selectedRange().location
        let census = laidOutCensus(upTo: loc)
        let y = textLayoutManager.flatMap { tlm -> CGFloat? in
            guard let tcm = tlm.textContentManager, let l = tcm.location(tcm.documentRange.location, offsetBy: loc) else { return nil }
            return tlm.textLayoutFragment(for: l)?.layoutFragmentFrame.minY
        }
        anchorTrace("CENSUS[\(tag)] caret=\(loc) laidOutAbove=\(census.0)/\(census.1) fragY=\(y.map { String(format: "%.1f", $0) } ?? "nil") docH=\(String(format: "%.0f", textLayoutManager?.usageBoundsForTextContainer.height ?? -1)) origin=\(String(format: "%.1f", enclosingScrollView?.contentView.bounds.origin.y ?? -1))")
    }

    /// Trace-only: the offsets of the laid-out fragments up to `loc`.
    func laidOutOffsets(upTo loc: Int) -> Set<Int> {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let end = tcm.location(tcm.documentRange.location, offsetBy: max(0, loc)) else { return [] }
        var offsets = Set<Int>()
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(end) != .orderedAscending { return false }
            if fragment.state == .layoutAvailable {
                offsets.insert(tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location))
            }
            return true
        }
        return offsets
    }

    /// Trace-only: spans (first…last offset, count) of fragments that were laid out
    /// in `laidOutBefore` and are not any more, with a preview of the first one.
    func invalidatedFragmentSpans(upTo loc: Int, laidOutBefore: Set<Int>) -> String {
        let now = laidOutOffsets(upTo: loc)
        let lost = laidOutBefore.subtracting(now).sorted()
        guard let first = lost.first, let last = lost.last else { return "none" }
        let ns: NSString = textStorage?.mutableString ?? ""
        return "\(lost.count) fragments \(first)…\(last) first=\"\(anchorLinePreview(first, in: ns))\" last=\"\(anchorLinePreview(last, in: ns))\""
    }

    func laidOutCensus(upTo loc: Int) -> (Int, Int) {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let end = tcm.location(tcm.documentRange.location, offsetBy: max(0, loc)) else { return (0, 0) }
        var laidOut = 0, total = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            if fragment.rangeInElement.location.compare(end) != .orderedAscending { return false }
            total += 1
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        return (laidOut, total)
    }
    #endif

    /// The start of the paragraph that carries a collapsed block's image when
    /// `loc` lies in one of the block's hidden (1 pt line height) paragraphs;
    /// `loc` itself otherwise.
    private func anchorParagraphOfCollapsedBlock(containing loc: Int) -> Int {
        guard let storage = textStorage, loc >= 0, loc < storage.length else { return loc }
        let ns: NSString = textStorage?.mutableString ?? ""
        func isCollapsed(_ location: Int) -> Bool {
            let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            return (style?.maximumLineHeight ?? 0) > 0 && (style?.maximumLineHeight ?? 0) <= 1
        }
        guard isCollapsed(loc) else { return loc }
        var paragraph = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        for _ in 0..<512 {
            guard paragraph.location > 0 else { return paragraph.location }
            let previous = ns.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
            if !isCollapsed(previous.location) { return previous.location }
            paragraph = previous
        }
        return paragraph.location
    }

    /// The nearest character to `loc` with real (>= 0.01) laid-out geometry,
    /// searching paragraph starts outward in both directions. Existing layout
    /// ONLY — never forces an ensure, so a returned Y is in the same pre-settle
    /// coordinate space the viewport-anchor delta math depends on. Bounded (64
    /// paragraphs); returns nil only when nothing on screen is laid out. This is
    /// what keeps `preservingViewportAnchor` from skipping the pin when the
    /// chosen anchor fell in an ESTIMATED or collapsed overlay-band fragment.
    private func nearestLaidOutPin(from loc: Int, pinY: (Int) -> CGFloat?) -> (loc: Int, y: CGFloat)? {
        let ns: NSString = textStorage?.mutableString ?? ""
        guard ns.length > 0 else { return nil }
        // NSNotFound / out-of-range probe → center the outward walk on the caret.
        let center = (loc >= 0 && loc < ns.length)
            ? loc
            : max(0, min(selectedRange().location, ns.length - 1))
        var back = ns.paragraphRange(for: NSRange(location: center, length: 0)).location
        var fwd = back
        for _ in 0..<64 {
            if let y = pinY(back) { return (back, y) }
            if fwd != back, let y = pinY(fwd) { return (fwd, y) }
            if back > 0 {
                back = ns.paragraphRange(for: NSRange(location: back - 1, length: 0)).location
            }
            let next = NSMaxRange(ns.paragraphRange(for: NSRange(location: fwd, length: 0)))
            if next < ns.length {
                fwd = next
            } else if back == 0 {
                break
            }
        }
        return nil
    }

    /// The first character strictly BELOW `loc` whose laid-out Y lies within
    /// `visible`. Used to reject an off-screen collapsed-standalone-image pin: a
    /// collapsed diagram / block-math whose top is above the viewport reports the
    /// same off-screen image-top Y for every source char, and that Y does not move
    /// when the block reveals — so the anchor must instead hold the first genuinely
    /// visible line under the block. Advances paragraph-by-paragraph (skipping the
    /// block's own still-off-screen source lines first) using EXISTING layout only,
    /// bounded to 64 paragraphs; nil when nothing on screen sits below the block.
    private func firstOnScreenPinBelow(_ loc: Int, lineY: (Int) -> CGFloat?, visible: NSRect) -> Int? {
        let ns: NSString = textStorage?.mutableString ?? ""
        guard ns.length > 0 else { return nil }
        var cur = ns.paragraphRange(for: NSRange(location: min(max(0, loc), ns.length - 1), length: 0)).location
        for _ in 0..<64 {
            let next = NSMaxRange(ns.paragraphRange(for: NSRange(location: cur, length: 0)))
            guard next < ns.length else { return nil }
            cur = next
            if let y = lineY(cur), y >= visible.minY, y <= visible.maxY { return cur }
        }
        return nil
    }

    /// Real content height including overscroll, excluding the click-below-text inflation.
    var scrollableContentHeight: CGFloat {
        max(ceil(baseContentHeight + activeBottomOverscroll + commentOverhang), 0)
    }

    func recalcOverscroll(
        for scrollView: NSScrollView,
        targetWidth: CGFloat? = nil,
        debugTag: String = "?"
    ) {
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        // File switch/resize forces full layout until height settles; typing stays O(edit).
        if debugTag == "?" { pendingFullLayoutMeasure = true }
        let measured = measuredBaseContentHeight(
            minimumHeight: lineHeight,
            forceFullLayout: pendingFullLayoutMeasure
        )
        let visibleHeight = scrollView.contentView.bounds.height
        let resolvedOverscroll = resolvedOverscroll(
            baseContentHeight: measured,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )

        let baseHeightChanged = abs(measured - baseContentHeight) > 0.5
        let overscrollChanged = abs(resolvedOverscroll - activeBottomOverscroll) > 0.5
        // Height settled → stop forcing full layout (until the next switch/resize).
        if !(baseHeightChanged || overscrollChanged) { pendingFullLayoutMeasure = false }
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = measured
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }

    /// Re-run the policy with the CURRENT base content height — no TextKit
    /// re-measure. For header-band changes (runs per animation frame).
    func reapplyOverscrollPolicy(for scrollView: NSScrollView) {
        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        let resolved = resolvedOverscroll(
            baseContentHeight: baseContentHeight,
            visibleHeight: scrollView.contentView.bounds.height,
            lineHeight: lineHeight
        )
        guard abs(resolved - activeBottomOverscroll) > 0.5 else { return }
        activeBottomOverscroll = resolved
        applyManagedFrameSize(width: frame.size.width)
    }

    /// Keystroke-time height/overscroll refresh. This deliberately avoids
    /// `measuredBaseContentHeight`, because measuring the document end forces
    /// TextKit to lay out invalidated fragments below the edit. The exact
    /// document-height pass is debounced to the idle edge; typing gets only a
    /// cheap frame-growth estimate so the caret never runs out of scrollable room.
    func refreshOverscrollAfterTextEdit(
        for scrollView: NSScrollView,
        scheduleExactMeasure: Bool = true
    ) {
        scrollView.contentInsets.bottom = 0

        let lineDelta = pendingTextEditLineDelta
        pendingTextEditLineDelta = 0

        if lineDelta > 0 {
            let lineHeight = layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge)
            let paragraphSpacing = ceil(lineHeight * configuration.paragraph.spacingFactor)
            let lineAdvance = ceil(lineHeight) + configuration.paragraph.lineHeightExtraSpacing + paragraphSpacing
            baseContentHeight += CGFloat(lineDelta) * lineAdvance
            applyManagedFrameSize(width: frame.size.width)
        }

        reapplyOverscrollPolicy(for: scrollView)

        if scheduleExactMeasure {
            scheduleDeferredOverscrollRecalc(for: scrollView)
        } else {
            // Plain character edits do not change document height in the common
            // case. More importantly, they must cancel an older exact remeasure
            // that could otherwise fire mid-burst and force TextKit to the
            // document end.
            deferredOverscrollRecalcGeneration &+= 1
            pendingDeferredOverscrollRecalc = false
        }
    }

    func pauseDeferredLayoutWork() {
        deferredOverscrollRecalcGeneration &+= 1
        zoomRefitWorkItem?.cancel()
        zoomRefitWorkItem = nil
    }

    func resumeDeferredLayoutWork(for scrollView: NSScrollView) {
        if pendingDeferredOverscrollRecalc {
            scheduleDeferredOverscrollRecalc(for: scrollView)
        }
        if pendingZoomRefit { magnificationDidSettle() }
        if pendingDeferredWideTableOverlayUpdate { updateWideTableOverlays() }
    }

    private func scheduleDeferredOverscrollRecalc(for scrollView: NSScrollView) {
        deferredOverscrollRecalcGeneration &+= 1
        pendingDeferredOverscrollRecalc = true
        guard !scrollView.isHidden else { return }
        let generation = deferredOverscrollRecalcGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak scrollView] in
            guard let self,
                  let scrollView,
                  generation == self.deferredOverscrollRecalcGeneration,
                  !scrollView.isHidden else { return }

            self.pendingDeferredOverscrollRecalc = false
            self.pendingFullLayoutMeasure = true
            self.recalcOverscroll(for: scrollView, debugTag: "deferredTextDidChange")
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
    }

    /// Shared policy evaluation, including the header band stacked above the text —
    /// without it, a short text under an expanded band gets no slack.
    private func resolvedOverscroll(
        baseContentHeight: CGFloat,
        visibleHeight: CGFloat,
        lineHeight: CGFloat
    ) -> CGFloat {
        let headerHeight = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        return policy.activeOverscroll(
            baseContentHeight: baseContentHeight,
            headerHeight: headerHeight,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )
    }

    func measuredBaseContentHeight(minimumHeight: CGFloat, forceFullLayout: Bool = false) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        guard let textLayoutManager else { return minimumContentHeight }

        // Partial TextKit-2 layout under-measures and oscillates; force full layout only on switch/resize.
        if forceFullLayout, !prefersEstimatedLayoutChain {
            #if DEBUG
            let started = CACurrentMediaTime()
            #endif
            PerfTrace.time("overscroll.fullMeasure") { textLayoutManager.ensureLayout(for: textLayoutManager.documentRange) }
            #if DEBUG
            anchorTrace(String(format: "FULLMEASURE: whole-note layout took %.0f ms (docH %.0f)",
                               (CACurrentMediaTime() - started) * 1000, textLayoutManager.usageBoundsForTextContainer.height))
            #endif
        }

        let documentEnd = textLayoutManager.documentRange.endLocation

        // Lay out the last fragment; gives a max-Y fallback if enumerateTextSegments misses it.
        var fragmentMaxY: CGFloat = 0
        var visited = 0
        // Geometry of the fragment containing the document end — the extra line
        // fragment normalization below needs its frame and line boxes.
        var lastFragmentFrame: NSRect = .zero
        var lastFragmentLineBoxes: [CGRect] = []
        textLayoutManager.enumerateTextLayoutFragments(
            from: documentEnd,
            options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if visited == 0 {
                lastFragmentFrame = frame
                lastFragmentLineBoxes = fragment.textLineFragments.map { $0.typographicBounds }
            }
            fragmentMaxY = max(fragmentMaxY, frame.maxY)
            // Trailing block image draws below TextKit's height; count its surface extent so it scrolls.
            let surfaceMaxY = frame.origin.y + fragment.renderingSurfaceBounds.maxY
            if surfaceMaxY > frame.maxY + 8 { fragmentMaxY = max(fragmentMaxY, surfaceMaxY) }
            visited += 1
            return visited < 3
        }

        // End-segment maxY = authoritative document height in TextKit 2.
        let segmentRange = NSTextRange(location: documentEnd)
        textLayoutManager.ensureLayout(for: segmentRange)
        var segmentMaxY: CGFloat = 0
        var segmentMinY: CGFloat = 0
        textLayoutManager.enumerateTextSegments(
            in: segmentRange,
            type: .standard,
            options: .middleFragmentsExcluded
        ) { _, rect, _, _ in
            if rect.maxY >= segmentMaxY {
                segmentMaxY = rect.maxY
                segmentMinY = rect.minY
            }
            return true
        }

        var rawHeight = max(segmentMaxY, fragmentMaxY)

        // With a trailing "\n", the last line is TextKit's extra line fragment.
        // Its metrics follow the final newline's attributes — not the body style a
        // typed line would get — so the measured height would jump on the first
        // typed character. Normalize the empty last line to body metrics.
        if segmentMaxY > 0, let storage = textStorage, storage.mutableString.hasSuffix("\n") {
            let bodyLineHeight = ceil(layoutBridgeDefaultLineHeight(for: baseFont, using: layoutBridge))
                + configuration.paragraph.lineHeightExtraSpacing

            // TextKit omits the final paragraph's paragraphSpacing above the extra
            // line fragment but inserts it once a real character follows — add the
            // missing gap so typing stays height-neutral.
            let ns = storage.mutableString
            let lastParaRange = ns.paragraphRange(for: NSRange(location: ns.length - 1, length: 0))
            let lastParaStyle = storage.attribute(
                .paragraphStyle, at: lastParaRange.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let paragraphSpacing = lastParaStyle?.paragraphSpacing ?? 0
            let prevLineBottom: CGFloat
            if lastFragmentLineBoxes.count >= 2 {
                let secondToLast = lastFragmentLineBoxes[lastFragmentLineBoxes.count - 2]
                prevLineBottom = lastFragmentFrame.minY + secondToLast.maxY
            } else {
                prevLineBottom = lastFragmentFrame.minY
            }
            let appliedGap = max(segmentMinY - prevLineBottom, 0)
            let missingSpacing = max(paragraphSpacing - appliedGap, 0)
            let normalizedEnd = segmentMinY + missingSpacing + bodyLineHeight
            if abs(rawHeight - segmentMaxY) < 0.5 {
                // The extra line itself is the bottom-most content — replace it.
                rawHeight = normalizedEnd
            } else {
                // Something else (e.g. a trailing image surface) reaches lower — keep it.
                rawHeight = max(rawHeight, normalizedEnd)
            }
        }

        return max(ceil(rawHeight + (textContainerInset.height * 2)), minimumContentHeight)
    }

    /// Fixed reading-column width = wrap width + horizontal insets on both sides.
    var readingColumnWidth: CGFloat {
        (configuration.readingWidth ?? 0) + configuration.textInsets.horizontal * 2
    }

    func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll + commentOverhang), 0)
        // The container stacks a header band ABOVE this text view, so the text view only
        // needs to fill the viewport MINUS that band for the whole document view to fill
        // the viewport on short docs (header + textView ≥ viewport).
        let headerH = (superview as? NativeTextViewContainer)?.headerHeight ?? 0
        let scrollViewHeight = max((enclosingScrollView?.contentView.bounds.height ?? 0) - headerH, 0)
        let height = max(contentHeight, scrollViewHeight)
        // Reading column: the column keeps its fixed wrap width; its centered X is
        // owned by `centerReadingColumn` (driven from the container's restack).
        let targetWidth = configuration.readingWidth != nil ? readingColumnWidth : max(width, 0)
        let targetSize = NSSize(
            width: targetWidth,
            height: height
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
        // Tell the container our height changed so it can re-stack (move us below the
        // header) and size itself. Re-entrancy is guarded inside the container.
        (superview as? NativeTextViewContainer)?.textViewDidResize()
    }

    /// Re-center the column by moving its X (not resizing it) so it stays smooth during live resize.
    func centerReadingColumn(forClipWidth clipWidth: CGFloat) {
        guard configuration.readingWidth != nil,
              let container = superview as? NativeTextViewContainer else { return }
        if abs(container.frame.size.width - clipWidth) > 0.5 {
            var f = container.frame
            f.size.width = max(clipWidth, 0)
            container.frame = f
        }
        var originX = floor(max(0, (clipWidth - readingColumnWidth) / 2))
        // the reference editor's comment lane: the text ends at least `commentLaneReserve`
        // from the right edge, centred when there is room.
        if commentLaneReserve > 0 {
            let limit = clipWidth - commentLaneReserve - (readingColumnWidth - configuration.textInsets.horizontal)
            originX = floor(max(0, min(originX, limit)))
        }
        let delta = originX - frame.origin.x
        if abs(delta) > 0.5 {
            setFrameOrigin(NSPoint(x: originX, y: frame.origin.y))
            repositionWideTableOverlaysForWidthChange(insetDelta: delta)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if isApplyingManagedFrameSize {
            super.setFrameSize(newSize)
            return
        }

        guard let scrollView = enclosingScrollView else {
            baseContentHeight = max(newSize.height, 0)
            super.setFrameSize(newSize)
            return
        }

        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        if widthChanged {
            // A view-width change re-wraps (→ height changes → full re-measure)
            // only while the text container TRACKS the view. Under the zoom
            // wrap-pin (ADR-0019) the wrap width is fixed, the resize is pure
            // canvas growth, and the full-document measure — the expensive part
            // of every zoom settle — is skipped. A pinned-wrap CHANGE (window
            // resize while zoomed) re-arms the flag in applyZoomWrapPinning.
            if textContainer?.widthTracksTextView ?? true {
                pendingFullLayoutMeasure = true
            }
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        recalcOverscroll(for: scrollView, targetWidth: newSize.width, debugTag: "setFrameSize")

        // Width change → only table paragraphs whose layout depends on the
        // container width need restyling.
        if widthChanged {
            DispatchQueue.main.async { [weak self] in
                self?.containerWidthDidChange()
            }
        }
    }

    // MARK: - Visual-zoom effective width (ADR-0019)

    /// Effective width for width-FITTED blocks (tables, diagrams, images) under
    /// visual ZOOM-OUT, in document points: the clip view's bounds width
    /// (= viewport frame ÷ magnification — it GROWS as the user zooms out)
    /// minus the horizontal text insets. `nil` at magnification ≥ 1 or without
    /// a live scroll view — callers fall back to the text container width.
    ///
    /// ZOOM-OUT ONLY (field revision of the symmetric-re-fit decision): at
    /// magnification > 1 a re-fit SHRINKS a diagram to keep fitting the visible
    /// window — its height changes at every settle (content below shifts,
    /// magnified: "view jumps erratically") and the diagram never actually
    /// gets bigger, defeating the zoom. Zoom-in is PDF-pure: the 100% layout
    /// scales up and the user pans; only raster DENSITY re-renders (same
    /// fitted size — no layout shift) so diagrams stay crisp.
    var zoomedBlockFitWidth: CGFloat? {
        guard let scrollView = enclosingScrollView,
              scrollView.allowsMagnification,
              scrollView.magnification < 1 - 0.001 else { return nil }
        // BASE inset (the host's side margin), not the live textContainerInset —
        // the centering knob inflates the live inset to position the pinned
        // wrap column, which must not shrink the block-fit target.
        let width = scrollView.contentView.bounds.width - configuration.textInsets.horizontal * 2
        guard width.isFinite, width > 1 else { return nil }
        return width
    }

    /// Pixel density freshly rasterized block content should target: the
    /// window's backing scale times the magnification (clamped ≥ 1 — zoom-out
    /// never needs extra pixels). A diagram rasterized at a zoomed-in settle
    /// then stays crisp instead of showing stretched pixels (ADR-0019).
    var blockRasterScale: CGFloat {
        let backing = window?.backingScaleFactor ?? 2
        guard let scrollView = enclosingScrollView, scrollView.allowsMagnification else { return backing }
        let magnification = min(max(scrollView.magnification, 1), max(scrollView.maxMagnification, 1))
        return backing * magnification
    }

    /// The prose column's wrap width in full-width mode: the viewport's FRAME
    /// width (device points), which magnification never touches — zoom scales
    /// the document visually, it must not rewrap a single line. `nil` without
    /// a live scroll view (headless hosting), where the container width is
    /// authoritative as before.
    var zoomIndependentProseWidth: CGFloat? {
        guard let scrollView = enclosingScrollView, scrollView.allowsMagnification else { return nil }
        let width = scrollView.contentView.frame.width
        guard width.isFinite, width > 1 else { return nil }
        return width
    }

    /// Breakout overlays (container siblings spanning the full container width)
    /// serve reading-column mode; in full-width mode the text view itself spans
    /// the zoom-grown container (`applyZoomWrapPinning`), so overlays stay
    /// text-view subviews there. The width check is a safety net for a
    /// transient frame mismatch mid-settle.
    var wideTableBreakoutActive: Bool {
        if configuration.readingWidth != nil { return true }
        guard let container = superview else { return false }
        return container.bounds.width > frame.width + 0.5
    }

    /// The live textContainerInset width the current zoom geometry wants:
    /// the host's base side margin, plus — when the wrap column is pinned and
    /// the host opted into centering — the offset that centers the column in
    /// the zoom-widened view. The wrapper's inset reconcile compares against
    /// THIS (not the raw base), so it never fights the centering placement.
    func zoomAdjustedInsetWidth(base: CGFloat, viewWidth: CGFloat? = nil) -> CGFloat {
        let vw = viewWidth ?? frame.width
        // A comment lane keeps the column at the left margin.
        guard configuration.readingWidth == nil, configuration.centersZoomedOutColumn, commentLaneReserve == 0,
              let prose = zoomIndependentProseWidth, vw > prose + 0.5 else { return base }
        return base + floor((vw - prose) / 2)
    }

    /// Full-width mode geometry under visual zoom (ADR-0019): the text VIEW
    /// spans the effective width (so inline block images can spill past the
    /// prose column WITHOUT leaving the view — AppKit clips drawing at view
    /// bounds, which cut every re-fitted table when the spill drew outside),
    /// while the text CONTAINER — the wrap width — stays pinned at the prose
    /// width, so no line ever rewraps. At magnification ≤ 1 the pin is
    /// released and the container tracks the view exactly as before.
    /// Idempotent. `viewWidth` is the (target) view width — the restack pins
    /// BEFORE growing and releases AFTER shrinking, so the container never
    /// tracks a transient width (each would be a full document rewrap).
    func applyZoomWrapPinning(forViewWidth viewWidth: CGFloat? = nil) {
        guard configuration.readingWidth == nil, let textContainer else { return }
        let vw = viewWidth ?? frame.width
        let base = configuration.textInsets.horizontal
        // the reference editor's comment lane: the wrap ends `commentLaneReserve` short of the right edge.
        let reserve = commentLaneReserve
        let prose = zoomIndependentProseWidth
        if (prose.map { vw > $0 + 0.5 } ?? false) || reserve > 0 {
            let wrap = max(min(prose ?? vw, vw) - base * 2 - reserve, 1)
            if textContainer.widthTracksTextView { textContainer.widthTracksTextView = false }
            if abs(textContainer.size.width - wrap) > 0.5 {
                textContainer.size = NSSize(width: wrap, height: .greatestFiniteMagnitude)
                // The WRAP actually changed (window resize / margin change while
                // zoomed) → heights are stale; the next overscroll recalc must
                // re-measure against a full layout.
                pendingFullLayoutMeasure = true
            }
        } else if !textContainer.widthTracksTextView {
            let restored = max(vw - base * 2, 1)
            if abs(textContainer.size.width - restored) > 0.5 {
                pendingFullLayoutMeasure = true   // release at a DIFFERENT width → rewrap
            }
            textContainer.widthTracksTextView = true
            textContainer.size = NSSize(width: restored, height: .greatestFiniteMagnitude)
        }
        let desiredInset = zoomAdjustedInsetWidth(base: base, viewWidth: vw)
        if abs(textContainerInset.width - desiredInset) > 0.5 {
            textContainerInset = NSSize(width: desiredInset, height: textContainerInset.height)
        }
    }

    /// Coalesced zoom-settle hook: pinch end, each Ctrl-scroll tick, and every
    /// projected ⌘±/restore change land here; the re-fit itself runs once,
    /// ~200ms after the last change (PDFKit's settle-then-sharpen model — the
    /// live gesture keeps AppKit's bitmap scaling untouched).
    func magnificationDidSettle() {
        zoomRefitWorkItem?.cancel()
        zoomRefitWorkItem = nil
        pendingZoomRefit = true
        guard enclosingScrollView?.isHidden == false else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.zoomRefitWorkItem = nil
            guard self.enclosingScrollView?.isHidden == false else { return }
            self.pendingZoomRefit = false
            self.performZoomRefit()
        }
        zoomRefitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func performZoomRefit() {
        guard configuration.readingWidth == nil else { return }
        #if DEBUG
        let originBefore = enclosingScrollView?.contentView.bounds.origin.y ?? .nan
        #endif
        applyZoomContainerGeometry()
        // A zoom-out re-fit CHANGES block heights (a freed diagram grows, a
        // re-clamped one shrinks) — without the pin the content below the
        // anchor shifts by the delta, magnified on screen ("view jumps").
        //
        // FULL-document layout inside the pin, not viewport-only, on a note
        // short enough to afford it (a long note keeps the estimated chain,
        // ADR-0020). A re-fit that changes block heights leaves estimates
        // everywhere it doesn't lay out, and field traces showed them paying
        // back as post-zoom drift crawls and a −2359pt pin correction long
        // after the gesture; the retained heights this pass creates prevent
        // that. Already-laid fragments make it cheap when nothing changed.
        preservingViewportAnchor {
            containerWidthDidChange()
            ensureWholeNoteLayoutUnlessLong()
        }
        // Exact content height (the clamp bound) from the fresh layout, then
        // the ONE post-zoom clamp — frozen frames skip clamping entirely so
        // they can't fight AppKit's magnification bounce animation.
        if let scrollView = enclosingScrollView {
            pendingFullLayoutMeasure = true
            recalcOverscroll(for: scrollView, debugTag: "zoomSettle")
            (scrollView as? ClampedScrollView)?.clampToInsets()
        }
        // Chrome that tracks the final viewport (skipped by the frozen frames).
        if let coord = delegate as? NativeTextViewCoordinator {
            coord.refreshActiveLinkCaretRect()
            coord.updateCodeBlockSelection(textView: self)
        }
        #if DEBUG
        let originAfter = enclosingScrollView?.contentView.bounds.origin.y ?? .nan
        NSLog("[ZOOMSETTLE] mag=%.3f origin %.1f → %.1f (Δ%.1f)",
              enclosingScrollView?.magnification ?? -1, originBefore, originAfter, originAfter - originBefore)
        #endif
    }

    /// Full-width mode under magnification: size the container to the larger of
    /// the prose width and the effective width, so zoom-out opens breakout room
    /// for width-fitted blocks (and the column can center inside it) while
    /// zoom-in leaves today's pan-the-column geometry untouched.
    func applyZoomContainerGeometry() {
        guard configuration.readingWidth == nil,
              let scrollView = enclosingScrollView, scrollView.allowsMagnification,
              let container = superview as? NativeTextViewContainer else { return }
        let prose = scrollView.contentView.frame.width
        let effective = scrollView.contentView.bounds.width
        guard prose.isFinite, prose > 1, effective.isFinite, effective > 1 else { return }
        let target = max(prose, effective)
        if abs(container.frame.width - target) > 0.5 {
            container.setFrameSize(NSSize(width: target, height: container.frame.height))
        } else {
            // Width already right (e.g. only the centering knob flipped) — the
            // restack still owns the column's X, so re-run it.
            container.restack(propagateWidth: true)
        }
    }

    /// The container's usable width changed (window resize, the host's live
    /// side-margin/textInsets reconcile, or a zoom settle). Restyles exactly the
    /// paragraphs whose rendering depends on that width:
    /// - every currently-WIDE table (its anchor kern bakes the display width)
    ///   and any table whose wide↔narrow decision FLIPS at the new width. The
    ///   old stamp-only walk saw exclusively wide tables, so a wide→narrow flip
    ///   was one-way: shrink the window back and the inline image stayed
    ///   clipped forever, with no overlay recreated.
    /// - every RENDERED diagram (```mermaid …) and image block: their style
    ///   pass fits the raster to the width (`min(natural, width)`), so any
    ///   width change can re-clamp or free them. The re-render is a cache hit
    ///   (natural rasters are width-independent) plus fit arithmetic.
    /// Ends with the overlay reconcile.
    func containerWidthDidChange() {
        defer { updateWideTableOverlays() }
        guard configuration.readingWidth == nil,
              let storage = textStorage,
              let coord = delegate as? NativeTextViewCoordinator,
              let container = layoutBridge?.firstTextContainer else { return }
        // Blocks FIT to the effective width (viewport ÷ magnification —
        // identical to the container width at magnification 1); the same width
        // drives the wide↔narrow decision, so zooming out can flip an overlay
        // table to an inline spill and back (ADR-0019).
        let effectiveWidth = zoomedBlockFitWidth ?? container.size.width
        guard effectiveWidth.isFinite, effectiveWidth > 0 else { return }
        // De-dupe: one zoom settle reaches here twice (directly from the
        // refit AND via the view resize's async dispatch), and repeated calls
        // at an unchanged width would re-render every wide-table raster each
        // time. The same width and requested density need no restyle; the
        // overlay reconcile (defer above) still runs. Zoom-in preserves point
        // layout but requests sharper pixels. Renderer-specific cache buckets
        // belong to the injected renderer, not the core editor.
        let rasterScale = blockRasterScale
        if let last = lastBlockFitRefitWidth, abs(last - effectiveWidth) <= 0.5,
           lastBlockRasterScale == rasterScale { return }
        // Before a background parse lands there is nothing styled to refit; its
        // restyle styles every block at this width.
        guard let parsed = coord.parsedDocumentIfCached(for: string) else { return }
        lastBlockFitRefitWidth = effectiveWidth
        lastBlockRasterScale = rasterScale

        let ns: NSString = textStorage?.mutableString ?? ""
        let diagramLanguages = configuration.diagramLanguages
        var ranges: [NSRange] = []
        for token in parsed.tokens {
            guard NSMaxRange(token.range) <= storage.length else { continue }
            switch token.kind {
            case .table:
                // The rendered image at the table's anchor (nil = active/raw table).
                var imageWidth: CGFloat?
                var wasWide = false
                storage.enumerateAttribute(.latexBounds, in: token.range, options: []) { value, r, stop in
                    guard let bounds = value as? NSValue else { return }
                    imageWidth = bounds.rectValue.width
                    wasWide = storage.attribute(.scrollableBlockSourceID, at: r.location, effectiveRange: nil) != nil
                    stop.pointee = true
                }
                guard let imageWidth else { continue }
                let isWideNow = imageWidth > effectiveWidth + 0.5
                if wasWide || isWideNow != wasWide {
                    ranges.append(ns.paragraphRange(for: token.range))
                }
            case .codeBlock, .imageLink, .imageEmbed:
                // Width-fitted iff it is currently RENDERED as a block image
                // (inactive + renderable); a revealed/plain block re-fits
                // through the ordinary restyle when it collapses again.
                if token.kind == .codeBlock {
                    guard !diagramLanguages.isEmpty,
                          let language = MarkdownTokenizer.extractLanguage(from: token, in: ns)?.lowercased(),
                          diagramLanguages.contains(language) else { continue }
                }
                var isRendered = false
                storage.enumerateAttribute(.renderedBlockImage, in: token.range, options: []) { value, _, stop in
                    if value != nil { isRendered = true; stop.pointee = true }
                }
                if isRendered {
                    ranges.append(ns.paragraphRange(for: token.range))
                }
            default:
                continue
            }
        }
        guard !ranges.isEmpty else { return }
        coord.restyleParagraphs(ranges, in: self)
    }
}
