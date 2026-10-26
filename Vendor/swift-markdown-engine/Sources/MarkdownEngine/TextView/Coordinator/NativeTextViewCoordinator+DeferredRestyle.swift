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

extension NativeTextViewCoordinator {

    /// Text (UTF-16 units) styled per idle pass: about 5 ms of styling on a
    /// marker-dense note. Scrolling a 4.6 MB note while it finishes styling
    /// ran near 50 fps with twice this (60 ms worst frame); this keeps it
    /// near 64 fps (40 ms worst).
    static let deferredRestyleChunk = 12_000

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

    /// Styles one chunk from the head of the queue and reschedules while work remains.
    func flushDeferredRestyle() {
        deferredRestyleScheduled = false
        guard let tv = textView, let textStorage = tv.textStorage, !deferredRestyleRanges.isEmpty else { return }
        // A hidden editor keeps its queue and resumes when shown again.
        if tv.enclosingScrollView?.isHidden == true || isComposing(in: tv) || isWritingToolsActive { return }
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

        var chunk = head
        if chunk.length > Self.deferredRestyleChunk {
            // Cut on a paragraph boundary so no paragraph is styled in two halves.
            let cut = ns.paragraphRange(for: NSRange(location: chunk.location + Self.deferredRestyleChunk, length: 0))
            chunk = NSRange(location: chunk.location, length: NSMaxRange(cut) - chunk.location)
            let rest = NSRange(location: NSMaxRange(chunk), length: NSMaxRange(head) - NSMaxRange(chunk))
            if rest.length > 0 { deferredRestyleRanges.insert(rest, at: 0) }
        }
        let text = ns as String
        let tokens = parsedDocument(for: text).tokens
        PerfTrace.time("deferred.chunk") {
            restyle(tv, paragraphCandidates: [chunk], tokens: tokens, text: text, anchoringViewport: true,
                    anchoringVisibleSource: deferredRestyleAnchorsVisibleSource)
        }
        if deferredRestyleRanges.isEmpty {
            deferredRestyleAnchorsVisibleSource = false
            scheduleBulkViewportAnchorFinish()
        }
        scheduleDeferredRestyle()
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
