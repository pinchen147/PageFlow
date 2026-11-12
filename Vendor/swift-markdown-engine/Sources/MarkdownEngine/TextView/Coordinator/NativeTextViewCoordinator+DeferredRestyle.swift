//
//  NativeTextViewCoordinator+DeferredRestyle.swift
//  MarkdownEngine
//
//  Viewport-first restyling for edits that touch the whole document (⌘A then a
//  style). Styling a 500 KB note takes ~300 ms; the reader only sees one screen
//  of it. Everything from the top of the edit down to one screen below the
//  viewport is styled in the same turn as the edit; the rest — all of it below
//  the viewport — in short idle passes. Nothing above the viewport is ever left
//  half-styled: a transient there changes the heights the viewport pin measures
//  against and the view wobbles by hundreds of points until the passes land.
//  Reading near the top of a note, which is where most edits happen, keeps the
//  synchronous part small; at the very end it is the whole note, as before.
//

import AppKit
import QuartzCore

extension NativeTextViewCoordinator {

    /// Text (UTF-16 units) styled per idle pass: about 5 ms of styling on a
    /// marker-dense note. Scrolling a 4.6 MB note while it finishes styling
    /// ran near 50 fps with twice this (60 ms worst frame); this keeps it
    /// near 64 fps (40 ms worst).
    static let deferredRestyleChunk = 12_000
    static let deferredRestyleMinimumChunk = 1_500

    /// Text styled below the viewport in the edit's own turn, so a small scroll
    /// never reaches an unstyled paragraph.
    static let deferredRestyleMargin = 6_000
    /// From this many UTF-16 characters a whole-note rebuild (open, font change,
    /// Writing Tools) styles only the screens around its focus synchronously
    /// and queues the rest as deferred chunks — the ⌘A viewport-first path,
    /// applied to opening.
    static let viewportFirstRebuildThreshold = 60_000

    /// Whole-document edits shorter than this restyle synchronously: the split
    /// is not worth a visible pass on a note that styles in a few milliseconds.
    static let deferredRestyleThreshold = 3 * deferredRestyleMargin

    /// Formulas in one idle pass: a new one takes about half a millisecond to typeset,
    /// and a chunk measured by its text can hold hundreds of them.
    static let deferredRestyleFormulas = 30
    /// Formulas typeset before a rebuild's first paint when fewer are in view: the rest
    /// come in idle passes.
    static let rebuildFormulas = 40
    /// The most a first paint typesets, however many are in view (a window zoomed far
    /// out): past this the stall is worse than formulas filling in.
    static let rebuildFormulaHardStop = 200
    /// From this many formulas a note short enough to style whole rebuilds viewport-first
    /// too: past it, typesetting them all would cost more than the stall bar.
    static let viewportFirstRebuildFormulas = 120

    /// The character range of the laid-out viewport, if any.
    func viewportCharacterRange(in textView: NSTextView) -> NSRange? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let range = tlm.textViewportLayoutController.viewportRange else { return nil }
        let start = tcm.offset(from: tcm.documentRange.location, to: range.location)
        let end = tcm.offset(from: tcm.documentRange.location, to: range.endLocation)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Splits the edited `span` into the part to style now (from the span's start
    /// through the viewport plus a margin) and the remainder below, to queue.
    func splitViewportFirst(span: NSRange, viewport: NSRange, in text: NSString) -> (now: NSRange, later: [NSRange]) {
        let length = text.length
        let endProbe = max(0, min(NSMaxRange(viewport) + Self.deferredRestyleMargin, NSMaxRange(span), length))
        let end = endProbe > span.location
            ? NSMaxRange(text.paragraphRange(for: NSRange(location: endProbe - 1, length: 0)))
            : span.location
        let now = NSRange(location: span.location, length: max(0, min(end, NSMaxRange(span)) - span.location))
        guard NSMaxRange(now) < NSMaxRange(span) else { return (now, []) }
        return (now, [NSRange(location: NSMaxRange(now), length: NSMaxRange(span) - NSMaxRange(now))])
    }

    func enqueueDeferredRestyle(_ ranges: [NSRange], anchoringVisibleSource: Bool = false) {
        if deferredRestyleRanges.isEmpty { deferredRestyleAnchorsVisibleSource = false }
        deferredRestyleAnchorsVisibleSource = deferredRestyleAnchorsVisibleSource || anchoringVisibleSource
        deferredRestyleRanges.append(contentsOf: ranges.filter { $0.length > 0 })
        scheduleDeferredRestyle()
    }

    private func scheduleDeferredRestyle(after delay: TimeInterval = 0.004) {
        guard !deferredRestyleScheduled, !deferredRestyleRanges.isEmpty else { return }
        deferredRestyleScheduled = true
        let generation = documentGeneration
        // A short delay rather than the next run-loop block: back-to-back chunks
        // after a viewport-first open held the main thread for 0.5–1 s before
        // the first frame could be drawn; a few milliseconds between chunks let
        // the display commit and events through (≈80 ms over a 20-chunk note).
        // A run-loop timer, not a dispatch timer: the test harness pumps the
        // run loop directly and would never fire a dispatch timer.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, generation == self.documentGeneration else { return }
                self.flushDeferredRestyle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Text laid out per pass of a note's owed measure: about 8 ms. A whole note at once
    /// was 90 ms at 72 KB, in one turn.
    static let owedMeasureChunk = 6_000

    /// The measure a first paint left for when the queue empties, however it empties:
    /// the note laid out a piece per pass, then measured. Each pass holds the reader's
    /// place, as the exact chain replaces estimates above it. A hidden editor keeps
    /// owing it, and pays when shown.
    func finishOwedFullMeasure() {
        guard let view = textView as? NativeTextView, view.owesFullMeasureAfterStyling,
              deferredRestyleRanges.isEmpty, !owedMeasureScheduled else { return }
        owedMeasureScheduled = true
        scheduleOwedMeasurePass(from: 0, generation: documentGeneration)
    }

    private func scheduleOwedMeasurePass(from offset: Int, generation: Int) {
        let timer = Timer(timeInterval: 0.004, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.owedMeasurePass(from: offset, generation: generation) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func owedMeasurePass(from offset: Int, generation: Int) {
        guard generation == documentGeneration, let view = textView as? NativeTextView, view.owesFullMeasureAfterStyling,
              deferredRestyleRanges.isEmpty, let scrollView = view.enclosingScrollView, !scrollView.isHidden,
              !isComposing(in: view), !isWritingToolsActive,
              let layout = view.textLayoutManager, let content = layout.textContentManager else {
            owedMeasureScheduled = false
            return
        }
        let text = view.string as NSString
        if offset < text.length, !view.prefersEstimatedLayoutChain {
            let end = NSMaxRange(text.paragraphRange(for: NSRange(location: min(text.length - 1, offset + Self.owedMeasureChunk), length: 0)))
            if let from = content.location(content.documentRange.location, offsetBy: offset),
               let to = content.location(content.documentRange.location, offsetBy: end),
               let range = NSTextRange(location: from, end: to) {
                PerfTrace.time("deferred.measurePass") {
                    restylePreservingViewport(view, tag: "owedMeasure") { layout.ensureLayout(for: range) }
                }
            }
            scheduleOwedMeasurePass(from: end, generation: generation)
            return
        }
        owedMeasureScheduled = false
        view.owesFullMeasureAfterStyling = false
        PerfTrace.time("deferred.fullMeasure") {
            restylePreservingViewport(view, tag: "owedMeasure") { view.recalcOverscroll(for: scrollView) }
        }
    }

    /// Styles one chunk from the head of the queue and reschedules while work remains.
    func flushDeferredRestyle() {
        deferredRestyleScheduled = false
        guard let tv = textView, let textStorage = tv.textStorage, !deferredRestyleRanges.isEmpty else { return }
        if isComposing(in: tv) || isWritingToolsActive { return }
        // A warm hidden editor stays warm: it finishes styling, without pins or layout,
        // which it has no view to hold, and more slowly, as the tab in view comes first.
        let isHidden = tv.enclosingScrollView?.isHidden == true
        // Zoom frames are frozen (ADR-0019): a chunk's height changes would
        // move the text under a zoom in flight. Check back at a gesture's pace,
        // not a chunk's.
        if (tv.enclosingScrollView as? ClampedScrollView)?.isZoomInProgress == true {
            scheduleDeferredRestyle(after: 0.05)
            return
        }
        let ns = textStorage.mutableString
        let bounds = NSRange(location: 0, length: ns.length)
        let head = NSIntersectionRange(deferredRestyleRanges.removeFirst(), bounds)
        guard head.length > 0 else { scheduleDeferredRestyle(); return }

        let text = ns as String
        let tokens = parsedDocument(for: text).tokens
        let chunk = Self.deferredRestyleChunk(of: head, in: ns, tokens: tokens, size: deferredRestyleChunkSize)
        let rest = NSRange(location: NSMaxRange(chunk), length: max(0, NSMaxRange(head) - NSMaxRange(chunk)))
        if rest.length > 0 { deferredRestyleRanges.insert(rest, at: 0) }
        let started = CACurrentMediaTime()
        PerfTrace.time("deferred.chunk") {
            restyle(tv, paragraphCandidates: [chunk], tokens: tokens, text: text, anchoringViewport: !isHidden,
                    anchoringVisibleSource: deferredRestyleAnchorsVisibleSource)
        }
        deferredRestyleChunkSize = Self.nextDeferredRestyleChunkSize(
            after: chunk.length, took: CACurrentMediaTime() - started, current: deferredRestyleChunkSize)
        if deferredRestyleRanges.isEmpty {
            deferredRestyleAnchorsVisibleSource = false
            scheduleBulkViewportAnchorFinish()
        }
        scheduleDeferredRestyle(after: isHidden ? 0.03 : 0.004)
    }

    /// The head of `range` to style in one idle pass: about one chunk, cut on
    /// a paragraph boundary so no paragraph is styled in two halves, and past
    /// the end of any table the cut falls in. Every pass that touches a table
    /// renders all of it, so a table split over passes rendered once per pass.
    static func deferredRestyleChunk(of range: NSRange, in text: NSString, tokens: [MarkdownToken],
                                     size: Int = deferredRestyleChunk) -> NSRange {
        let sizeEnd = range.length > size
            ? NSMaxRange(text.paragraphRange(for: NSRange(location: range.location + size, length: 0)))
            : NSMaxRange(range)
        var end = sizeEnd
        let formulas = formulaLocations(in: NSRange(location: range.location, length: sizeEnd - range.location), tokens: tokens)
        if formulas.count > deferredRestyleFormulas {
            end = NSMaxRange(text.paragraphRange(for: NSRange(location: formulas[deferredRestyleFormulas - 1], length: 0)))
        }
        guard end < NSMaxRange(range) else { return range }
        end = NSMaxRange(wholeBlocks(NSRange(location: range.location, length: end - range.location), in: text, tokens: tokens))
        if let table = tokens.first(where: { $0.kind == .table && $0.range.location < end && end < NSMaxRange($0.range) }) {
            end = NSMaxRange(table.range)
        }
        return NSRange(location: range.location, length: min(end, NSMaxRange(range)) - range.location)
    }

    /// Where the formulas in `range` start, in order.
    static func formulaLocations(in range: NSRange, tokens: [MarkdownToken]) -> [Int] {
        tokens.lazy.filter { ($0.kind == .blockLatex || $0.kind == .inlineLatex) && NSLocationInRange($0.range.location, range) }
            .map(\.range.location).sorted()
    }

    /// `scope` around `focus`, cut so a first paint typesets everything in view and, with
    /// few in view, up to `limit` formulas: three parts after the focus to one before, as
    /// the reader looks down from it. `visibleLines` is the most lines the view can show.
    static func rebuildScope(_ scope: NSRange, focus: Int, in text: NSString, tokens: [MarkdownToken], visibleLines: Int,
                             limit: Int = rebuildFormulas, hardStop: Int = rebuildFormulaHardStop) -> NSRange {
        let formulas = formulaLocations(in: scope, tokens: tokens)
        guard formulas.count > limit else { return scope }
        let split = formulas.firstIndex { $0 >= focus } ?? formulas.count
        let visibleEnd = endOfVisibleLines(visibleLines, from: focus, in: text, tokens: tokens)
        let inView = formulas[split...].prefix { $0 < visibleEnd }.count
        let after = min(formulas.count - split, hardStop, max(inView, limit - min(split, limit / 4)))
        let before = min(split, max(0, limit - after))
        let start = before > 0 ? text.paragraphRange(for: NSRange(location: formulas[split - before], length: 0)).location : scope.location
        let end = after > 0 ? NSMaxRange(text.paragraphRange(for: NSRange(location: formulas[split + after - 1], length: 0))) : NSMaxRange(scope)
        let whole = wholeBlocks(NSRange(location: start, length: end - start), in: text, tokens: tokens)
        return NSIntersectionRange(whole, NSRange(location: 0, length: text.length))
    }

    /// Where `count` lines from `focus` end, counting so the view can't show more than
    /// that: a wrapped line takes more room than one, a display formula takes at least
    /// one line however many it spans in the source, and so does a blank line, but for
    /// the one a block formula hides.
    static func endOfVisibleLines(_ count: Int, from focus: Int, in text: NSString, tokens: [MarkdownToken]) -> Int {
        guard count > 0 else { return focus }
        let blocks = tokens.filter { $0.kind == .blockLatex }.map(\.range).sorted { $0.location < $1.location }
        var nextBlock = blocks.firstIndex { NSMaxRange($0) > focus } ?? blocks.count
        var lines = 0
        var location = focus
        var afterBlock = false
        while location < text.length, lines < count {
            if nextBlock < blocks.count, NSLocationInRange(location, blocks[nextBlock]) {
                lines += 1
                location = min(text.length, NSMaxRange(text.lineRange(for: NSRange(location: NSMaxRange(blocks[nextBlock]) - 1, length: 0))))
                nextBlock += 1
                afterBlock = true
                continue
            }
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            let isBlank = line.length <= 1
            if !(isBlank && afterBlock) { lines += 1 }
            afterBlock = false
            location = NSMaxRange(line)
        }
        return location
    }

    /// `range` grown so neither end falls inside a display formula: one drawn from half
    /// its source shows its image beside the rest, raw, and changes height twice.
    static func wholeBlocks(_ range: NSRange, in text: NSString, tokens: [MarkdownToken]) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        for token in tokens where token.kind == .blockLatex {
            let tokenEnd = NSMaxRange(token.range)
            if token.range.location < start, start < tokenEnd { start = token.range.location }
            if token.range.location < end, end < tokenEnd {
                end = NSMaxRange(text.paragraphRange(for: NSRange(location: tokenEnd - 1, length: 0)))
            }
        }
        return NSRange(location: start, length: end - start)
    }

    /// The most lines of the body font the view can show, zoom included. A view not yet
    /// sized (a first mount, often before it has a window, which may be a new one of any
    /// height) goes by its window or the screen.
    func visibleLineCapacity(of textView: NSTextView) -> Int {
        let scrollView = textView.enclosingScrollView
        var height = scrollView?.contentView.bounds.height ?? 0
        if height <= 1 {
            let available = textView.window?.contentView?.bounds.height ?? NSScreen.main?.frame.height ?? 0
            height = available / max(scrollView?.magnification ?? 1, 0.01)
        }
        let lineHeight = layoutBridgeDefaultLineHeight(for: baseFontAndStyle().0, using: layoutBridge)
        return Int((height / max(lineHeight, 1)).rounded(.up))
    }

    /// The next chunk's size, so a pass stays near one frame's work: diagrams,
    /// tables and highlighted code cost far more per character than prose, and
    /// a fixed size held the main thread past 100 ms on them. Grows back on
    /// cheap text; never above the normal size, which a short pass keeps.
    static func nextDeferredRestyleChunkSize(after length: Int, took seconds: TimeInterval, current: Int) -> Int {
        let target: TimeInterval = 0.024
        guard length > 0 else { return current }
        if seconds > target * 1.25 {
            return max(deferredRestyleMinimumChunk, min(current, Int(Double(length) * target / seconds)))
        }
        return seconds < target / 2 ? min(deferredRestyleChunk, current * 2) : current
    }

    /// One final presentation turn may revise estimates after the last chunk.
    /// Late native/overlay pins can continue the receipt after this check;
    /// changes to document, selection or clip revoke it without a polling loop.
    func scheduleBulkViewportAnchorFinish() {
        guard bulkViewportAnchor != nil else { return }
        let generation = documentGeneration
        let sourceGeneration = nativeSourceGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.documentGeneration,
                  sourceGeneration == self.nativeSourceGeneration,
                  self.deferredRestyleRanges.isEmpty else { return }
            guard let view = self.textView as? NativeTextView,
                  !self.isComposing(in: view), !self.isWritingToolsActive,
                  view.enclosingScrollView?.isHidden != true,
                  self.bulkViewportAnchor?.isCurrent(in: view, sourceGeneration: sourceGeneration) == true else {
                self.bulkViewportAnchor = nil
                return
            }
            self.restylePreservingViewport(view, anchoringVisibleSource: true) {}
        }
    }

    /// Keeps queued ranges valid across an edit: ranges after the edit shift by
    /// its length change, a range holding the edit stretches over it.
    /// `edited` is the range in the NEW text.
    func shiftDeferredRestyle(edited: NSRange, delta: Int) {
        guard !deferredRestyleRanges.isEmpty else { return }
        let oldEnd = NSMaxRange(edited) - delta
        deferredRestyleRanges = deferredRestyleRanges.compactMap { range in
            if range.location >= oldEnd {
                return NSRange(location: range.location + delta, length: range.length)
            }
            if NSMaxRange(range) <= edited.location { return range }
            let start = min(range.location, edited.location)
            let end = max(NSMaxRange(range) + delta, NSMaxRange(edited))
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
    }
}
