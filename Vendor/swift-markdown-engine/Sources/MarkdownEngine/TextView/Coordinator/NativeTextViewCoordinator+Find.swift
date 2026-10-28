import AppKit

extension NativeTextViewCoordinator {
    struct FindHighlight {
        let range: NSRange
        let isCurrent: Bool
        var prefixMaximumEnd = 0
    }

    struct FindRequest {
        let range: NSRange
        let highlights: [FindHighlight]
    }

    enum PendingFindCommand {
        case show(FindRequest, source: String, generation: Int)
        case navigation(source: String, generation: Int, action: () -> Void)
        case sectionNavigation(SectionNavigationRequest)
        case clear
    }

    /// Comments share Find's protected-input deferral and stale-source rejection,
    /// while retaining their own scroll placement and card focus behavior.
    func performNavigationWhenInputSettles(_ action: @escaping () -> Void) {
        guard let view = textView else { return }
        if isComposing(in: view) || isWritingToolsActive {
            pendingFindCommand = .navigation(source: view.string, generation: documentGeneration, action: action)
            return
        }
        pendingFindCommand = nil
        action()
    }

    /// Rendering attributes disappear when TextKit reflows a fragment. Reapply
    /// Find's colors for that fragment without touching stored Markdown styling.
    func installFindRenderingValidator(in layout: NSTextLayoutManager) {
        layout.renderingAttributesValidator = { [weak self] layout, fragment in
            guard let self, !self.activeFindHighlights.isEmpty, let view = self.textView,
                  !self.isComposing(in: view), !self.isWritingToolsActive,
                  let content = layout.textContentManager else { return }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            guard start >= 0, end >= start, end != NSNotFound else { return }
            let span = NSRange(location: start, length: end - start)
            layout.removeRenderingAttribute(.backgroundColor, for: fragment.rangeInElement)
            // Prefix maxima are monotonic even for containing ranges. Binary
            // lookup skips matches entirely before this fragment.
            var low = 0, high = self.activeFindHighlights.count
            while low < high {
                let middle = (low + high) / 2
                if self.activeFindHighlights[middle].prefixMaximumEnd <= start { low = middle + 1 }
                else { high = middle }
            }
            var currentHighlight: (FindHighlight, NSRange)?
            for highlight in self.activeFindHighlights[low...] {
                if highlight.range.location >= end { break }
                let intersection = NSIntersectionRange(highlight.range, span)
                if intersection.length > 0 {
                    if highlight.isCurrent { currentHighlight = (highlight, intersection) }
                    else { self.paintFindHighlight(highlight, range: intersection, in: layout) }
                }
            }
            if let (highlight, intersection) = currentHighlight {
                self.paintFindHighlight(highlight, range: intersection, in: layout)
            }
        }
    }

    /// Empty `allRanges` is navigate-only: reveal and scroll without coloring.
    @objc func handleFindScrollToRange(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification), let view = textView,
              let info = notification.userInfo,
              let range = info["range"] as? NSRange,
              let current = info["currentIndex"] as? Int,
              let ranges = info["allRanges"] as? [NSRange] else { return }
        let length = (view.string as NSString).length
        guard Self.validFindRange(range, length: length) else { return }
        var highlights = ranges.enumerated().compactMap { index, range -> FindHighlight? in
            guard range.length > 0, Self.validFindRange(range, length: length) else { return nil }
            return FindHighlight(range: range, isCurrent: index == current)
        }.sorted { $0.range.location < $1.range.location }
        var prefixMaximumEnd = 0
        for index in highlights.indices {
            prefixMaximumEnd = max(prefixMaximumEnd, NSMaxRange(highlights[index].range))
            highlights[index].prefixMaximumEnd = prefixMaximumEnd
        }
        let request = FindRequest(range: range, highlights: highlights)
        if isComposing(in: view) || isWritingToolsActive {
            pendingFindCommand = .show(request, source: view.string, generation: documentGeneration)
            return
        }
        pendingFindCommand = nil
        applyFind(request, in: view)
    }

    @objc func handleFindClearHighlights(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification), let view = textView else { return }
        if isComposing(in: view) || isWritingToolsActive {
            pendingFindCommand = .clear
            return
        }
        pendingFindCommand = nil
        activeFindHighlights.removeAll()
        refreshFindRendering(in: view)
    }

    /// Called after the native input session has reconciled source and geometry.
    func finishPendingFind(in view: NSTextView) {
        guard !isComposing(in: view), !isWritingToolsActive else { return }
        if findRenderingNeedsReset { refreshFindRendering(in: view) }
        let command = pendingFindCommand
        pendingFindCommand = nil
        switch command {
        case .show(let request, let source, let generation):
            guard generation == documentGeneration, (view.string as NSString).isEqual(to: source) else { return }
            applyFind(request, in: view)
        case .navigation(let source, let generation, let action):
            guard generation == documentGeneration, (view.string as NSString).isEqual(to: source) else { return }
            action()
        case .sectionNavigation(let request):
            executeSectionNavigation(request)
        case .clear:
            activeFindHighlights.removeAll()
            refreshFindRendering(in: view)
        case nil: break
        }
    }

    /// Source edits retire offsets even on the plain-typing fast path. Protected
    /// sessions defer renderer changes until native composition/rewrite finishes.
    func retireFindAfterSourceEdit(in view: NSTextView) {
        guard !activeFindHighlights.isEmpty else { return }
        activeFindHighlights.removeAll()
        findRenderingNeedsReset = true
        if !isComposing(in: view), !isWritingToolsActive { refreshFindRendering(in: view) }
    }

    func cancelFindWork() {
        pendingFindCommand = nil
        guard !activeFindHighlights.isEmpty || findRenderingNeedsReset else { return }
        activeFindHighlights.removeAll()
        findRenderingNeedsReset = true
        if let view = textView, !isComposing(in: view), !isWritingToolsActive {
            refreshFindRendering(in: view)
        }
    }

    private static func validFindRange(_ range: NSRange, length: Int) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= length
            && range.length <= length - range.location
    }

    private func refreshFindRendering(in view: NSTextView) {
        findRenderingNeedsReset = false
        guard let layout = view.textLayoutManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        for highlight in activeFindHighlights where !highlight.isCurrent {
            paintFindHighlight(highlight, range: highlight.range, in: layout)
        }
        if let current = activeFindHighlights.first(where: \.isCurrent) {
            paintFindHighlight(current, range: current.range, in: layout)
        }
        view.needsDisplay = true
    }

    private func paintFindHighlight(_ highlight: FindHighlight, range: NSRange, in layout: NSTextLayoutManager) {
        guard let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        let color = highlight.isCurrent ? configuration.theme.findCurrentMatchHighlight
            : configuration.theme.findMatchHighlight.withAlphaComponent(configuration.markers.findMatchHighlightAlpha)
        layout.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
    }

    private func applyFind(_ request: FindRequest, in tv: NSTextView) {
        tableEditingSession.finishInput()
        tableEditingSession.retire()
        let range = request.range
        _ = revealFoldedSource(range)
        if tv.isEditable, tv.selectedRange() != range { tv.setSelectedRange(range) }
        activeFindHighlights = request.highlights
        refreshFindRendering(in: tv)
        // A short note reveals the match in its exact layout; a long note in
        // the estimated chain TextKit draws from (ADR-0020), since a whole-note
        // layout per match froze the editor (D12).
        tv.ensureWholeNoteLayoutUnlessLong()
        // Scroll the current match into view.
        // Default (text view IS documentView): native reveal — unchanged for non-readingWidth embedders.
        guard configuration.readingWidth != nil, let native = tv as? NativeTextView,
              let scrollView = tv.enclosingScrollView else {
            tv.scrollRangeToVisible(range)
            return
        }
        // Reading column: only scroll when the match is off-screen; reveal it a
        // little below the top.
        guard let line = native.lineFrame(at: range.location) else { return }
        let visible = native.visibleRect
        let top = visible.minY + scrollView.contentInsets.top
        guard line.minY < top || line.maxY > visible.maxY else { return }
        MainActor.assumeIsolated { ScrollTrace.stamp("findReveal") }
        native.scroll(by: line.minY - top - scrollView.contentView.bounds.height * 0.2, landing: range.location)
    }

}
