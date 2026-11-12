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
        let expectedSource: String?
        let navigation: FindNavigation?
    }

    /// A bus receipt captures native ownership at intake, independently of source
    /// bytes: editing and undoing to equal text still retires the old request.
    struct FindNavigation {
        let document: Int
        let source: Int
        weak var controller: MarkdownEditorController?
        let whileValid: () -> Bool
        let didNavigate: (ReadingPosition) -> Void
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
            var currentHighlights: [(FindHighlight, NSRange)] = []
            for highlight in self.activeFindHighlights[low...] {
                if highlight.range.location >= end { break }
                let intersection = NSIntersectionRange(highlight.range, span)
                if intersection.length > 0 {
                    if highlight.isCurrent { currentHighlights.append((highlight, intersection)) }
                    else { self.paintFindHighlight(highlight, range: intersection, in: layout) }
                }
            }
            for (highlight, intersection) in currentHighlights {
                self.paintFindHighlight(highlight, range: intersection, in: layout)
            }
        }
    }

    /// Empty `allRanges` is navigate-only: reveal and scroll without coloring.
    /// `paintsOnly` is the reverse, for an editor built anew under a live search:
    /// color the matches, leaving the selection and the scroll where they are.
    @objc func handleFindScrollToRange(_ notification: Notification) {
        guard busNotificationIsForThisInstance(notification), let view = textView,
              let info = notification.userInfo,
              let range = info["range"] as? NSRange,
              let current = info["currentIndex"] as? Int,
              let ranges = info["allRanges"] as? [NSRange] else { return }
        let expectedSource = info["expectedSource"] as? String
        guard expectedSource.map({ (view.string as NSString).isEqual(to: $0) }) ?? true else { return }
        let length = (view.string as NSString).length
        guard Self.validFindRange(range, length: length) else { return }
        let sourceSegments = info["allSourceSegments"] as? [[NSRange]]
        guard sourceSegments == nil || sourceSegments?.count == ranges.count else { return }
        var highlights = ranges.enumerated().flatMap { index, envelope -> [FindHighlight] in
            guard envelope.length > 0, Self.validFindRange(envelope, length: length) else { return [] }
            let segments = sourceSegments?[index] ?? [envelope]
            return segments.compactMap { segment in
                guard segment.length > 0, Self.validFindRange(segment, length: length),
                      NSIntersectionRange(segment, envelope) == segment else { return nil }
                return FindHighlight(range: segment, isCurrent: index == current)
            }
        }.sorted { $0.range.location < $1.range.location }
        var prefixMaximumEnd = 0
        for index in highlights.indices {
            prefixMaximumEnd = max(prefixMaximumEnd, NSMaxRange(highlights[index].range))
            highlights[index].prefixMaximumEnd = prefixMaximumEnd
        }
        if info["paintsOnly"] as? Bool == true {
            activeFindHighlights = highlights
            refreshFindRendering(in: view)
            return
        }
        let navigation: FindNavigation?
        if let didNavigate = info["didNavigate"] as? (ReadingPosition) -> Void {
            guard let whileValid = info["whileValid"] as? () -> Bool, let controller = editorController else { return }
            navigation = FindNavigation(document: documentGeneration, source: nativeSourceGeneration,
                controller: controller, whileValid: whileValid, didNavigate: didNavigate)
        } else {
            navigation = nil
        }
        let request = FindRequest(range: range, highlights: highlights, expectedSource: expectedSource, navigation: navigation)
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
        for current in activeFindHighlights where current.isCurrent {
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

    /// Host code may synchronously change source, bindings, or presentation. Keep
    /// native checks on both sides of that call, including the final receipt.
    private func admitsFind(_ request: FindRequest, in view: NSTextView) -> Bool {
        func ownsRequest() -> Bool {
            guard textView === view,
                  request.expectedSource.map({ (view.string as NSString).isEqual(to: $0) }) ?? true else { return false }
            guard let navigation = request.navigation else { return true }
            guard let controller = navigation.controller else { return false }
            return documentGeneration == navigation.document && nativeSourceGeneration == navigation.source
                && editorController === controller && MainActor.assumeIsolated { controller.coordinator === self }
                && lastDisplayed && view.window != nil && view.enclosingScrollView?.isHidden == false
        }
        guard ownsRequest() else { return false }
        return request.navigation.map { $0.whileValid() && ownsRequest() } ?? true
    }

    private func applyFind(_ request: FindRequest, in tv: NSTextView) {
        guard admitsFind(request, in: tv) else { return }
        tableEditingSession.finishInput()
        tableEditingSession.retire()
        guard admitsFind(request, in: tv), !isComposing(in: tv), !isWritingToolsActive,
              Self.validFindRange(request.range, length: (tv.string as NSString).length) else { return }
        let native = tv as? NativeTextView
        let scroll = tv.enclosingScrollView
        let positionBeforeLayout = native?.readingPosition()
        let departure = request.navigation == nil ? nil : positionBeforeLayout
        if request.navigation != nil {
            guard native != nil, scroll != nil, departure != nil else { return }
        }
        let range = request.range
        _ = revealFoldedSource(range)
        if tv.isEditable, tv.selectedRange() != range { tv.setSelectedRange(range) }
        activeFindHighlights = request.highlights
        refreshFindRendering(in: tv)
        // A short note reveals the match in its exact layout; a long note in
        // the estimated chain TextKit draws from (ADR-0020), since a whole-note
        // layout per match froze the editor (D12).
        tv.ensureWholeNoteLayoutUnlessLong()
        if let native, let scroll, !native.prefersEstimatedLayoutChain,
           (scroll as? ClampedScrollView)?.isZoomInProgress != true {
            // Exact layout can move every fragment above this viewport. Reconcile
            // its extent and source position before deciding whether the target is visible.
            native.recalcOverscroll(for: scroll, debugTag: "findRevealLayout")
            if let positionBeforeLayout { native.restore(positionBeforeLayout) }
            else { tv.textLayoutManager?.textViewportLayoutController.layoutViewport() }
        }
        let oldY = scroll?.contentView.bounds.minY
        // EOF after a trailing newline has no text fragment of its own. Use
        // the final source character for geometry, retaining the exact selection.
        let landing = min(range.location, max(0, (tv.string as NSString).length - 1))
        // Every placement path reaches the same landing receipt. A visible
        // reading-column line is a no-op unless fold reveal changed geometry.
        if configuration.readingWidth != nil, let native, let scroll {
            guard let line = native.lineFrame(at: landing) else { return }
            let visible = native.visibleRect
            let top = visible.minY + scroll.contentInsets.top
            if line.minY < top || line.maxY > visible.maxY {
                MainActor.assumeIsolated { ScrollTrace.stamp("findReveal") }
                native.scroll(by: line.minY - top - scroll.contentView.bounds.height * 0.2, landing: landing)
            }
        } else {
            if request.navigation != nil, native?.lineFrame(at: landing) == nil { return }
            tv.scrollRangeToVisible(range)
        }
        guard let navigation = request.navigation, let departure, let oldY, let scroll,
              let arrival = native?.readingPosition() else { return }
        let changed = abs(scroll.contentView.bounds.minY - oldY) > 0.5
            || arrival.anchorOffset != departure.anchorOffset
            || abs(arrival.offsetInViewport - departure.offsetInViewport) > 0.5
        guard changed, admitsFind(request, in: tv) else { return }
        navigation.didNavigate(departure)
    }

}
