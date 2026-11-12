import AppKit
import QuartzCore

extension NativeTextViewCoordinator {
    /// Both native inheritance and a highlighter's independent palette can
    /// invalidate installed attributes. Read the live drawing appearance when
    /// draining, so a burst of notifications shares one current-palette pass.
    func requestAppearanceRefresh(in view: NSTextView) {
        guard textView === view else { return }
        pendingAppearanceRefresh = true
        appearanceRestyleRanges.removeAll()
        resumeAppearanceRefresh()
    }

    func resumeAppearanceRefresh(after delay: TimeInterval = 0.004) {
        guard pendingAppearanceRefresh || !appearanceRestyleRanges.isEmpty,
              !appearanceRefreshScheduled, let view = textView else { return }
        appearanceRefreshScheduled = true
        let generation = documentGeneration
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, generation == self.documentGeneration,
                      self.textView === view else { return }
                self.appearanceRefreshScheduled = false
                self.drainAppearanceRefresh(in: view)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func drainAppearanceRefresh(in view: NSTextView) {
        guard didInitialFormatting, lastDisplayed,
              view.enclosingScrollView?.isHidden == false,
              !isComposing(in: view), !isWritingToolsActive else { return }
        // Opening a very long note already has a background parse in flight.
        // Do not steal that work with a synchronous parse for a palette event.
        if pendingBackgroundStyle != nil {
            resumeAppearanceRefresh(after: 0.05)
            return
        }
        if (view.enclosingScrollView as? ClampedScrollView)?.isZoomInProgress == true {
            resumeAppearanceRefresh(after: 0.05)
            return
        }
        // A source edit invalidates these coordinates. Start a new viewport
        // pass from the live source instead of publishing an old queued span.
        if appearanceSourceGeneration != nativeSourceGeneration {
            pendingAppearanceRefresh = true
            appearanceRestyleRanges.removeAll()
        }
        let text = view.string
        let ns = text as NSString
        guard ns.length > 0 else {
            pendingAppearanceRefresh = false
            appearanceRestyleRanges.removeAll()
            return
        }
        let tokens = parsedDocument(for: text).tokens
        if pendingAppearanceRefresh {
            pendingAppearanceRefresh = false
            appearanceSourceGeneration = nativeSourceGeneration
            appearanceRestyleChunkSize = Self.deferredRestyleChunk / 4
            let bounds = NSRange(location: 0, length: ns.length)
            let viewport = NSIntersectionRange(viewportCharacterRange(in: view)
                ?? NSRange(location: min(view.selectedRange().location, ns.length - 1), length: 1), bounds)
            var visible = ns.paragraphRange(for: viewport)
            // A diagram or code fence must be styled as a complete block even
            // when its opening/closing delimiter is just outside the viewport.
            for token in tokens where token.kind == .codeBlock || token.kind == .table {
                if NSIntersectionRange(token.range, visible).length > 0 { visible = NSUnionRange(visible, token.range) }
            }
            visible = ns.paragraphRange(for: visible)
            visible = Self.wholeBlocks(visible, in: ns, tokens: tokens)
            visible = Self.rebuildScope(visible, focus: viewport.location, in: ns, tokens: tokens,
                                        visibleLines: visibleLineCapacity(of: view))
            visible = NSIntersectionRange(visible, bounds)
            appearanceRestyleRanges = []
            if visible.location > 0 {
                appearanceRestyleRanges.append(NSRange(location: 0, length: visible.location))
            }
            if NSMaxRange(visible) < ns.length {
                appearanceRestyleRanges.append(NSRange(location: NSMaxRange(visible), length: ns.length - NSMaxRange(visible)))
            }
            // Source-edit chunks already consume the live drawing appearance.
            // Do not duplicate their debt and invalidate layout again after
            // the initial source formatting owner has settled.
            appearanceRestyleRanges = appearanceRangesOutsideSourceWork(appearanceRestyleRanges)
            restyle(view, paragraphCandidates: [visible], tokens: tokens, text: text,
                    anchoringViewport: true, anchoringVisibleSource: true, tag: "appearance.visible")
        } else if !appearanceRestyleRanges.isEmpty {
            let head = appearanceRestyleRanges.removeFirst()
            let chunk = Self.deferredRestyleChunk(of: head, in: ns, tokens: tokens, size: appearanceRestyleChunkSize)
            if NSMaxRange(chunk) < NSMaxRange(head) {
                appearanceRestyleRanges.insert(NSRange(location: NSMaxRange(chunk), length: NSMaxRange(head) - NSMaxRange(chunk)), at: 0)
            }
            let started = CACurrentMediaTime()
            restyle(view, paragraphCandidates: [chunk], tokens: tokens, text: text,
                    anchoringViewport: true, anchoringVisibleSource: true, tag: "appearance.chunk")
            appearanceRestyleChunkSize = Self.nextDeferredRestyleChunkSize(
                after: chunk.length, took: CACurrentMediaTime() - started, current: appearanceRestyleChunkSize)
        }
        resumeAppearanceRefresh()
    }

    private func appearanceRangesOutsideSourceWork(_ ranges: [NSRange]) -> [NSRange] {
        var remaining = ranges
        for owed in deferredRestyleRanges {
            remaining = remaining.flatMap { span -> [NSRange] in
                let overlap = NSIntersectionRange(span, owed)
                guard overlap.length > 0 else { return [span] }
                var pieces: [NSRange] = []
                if span.location < overlap.location {
                    pieces.append(NSRange(location: span.location, length: overlap.location - span.location))
                }
                if NSMaxRange(overlap) < NSMaxRange(span) {
                    pieces.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(span) - NSMaxRange(overlap)))
                }
                return pieces
            }
        }
        return remaining
    }

}
