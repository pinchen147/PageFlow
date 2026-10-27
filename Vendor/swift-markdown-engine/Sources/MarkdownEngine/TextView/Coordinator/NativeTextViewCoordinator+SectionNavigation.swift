import AppKit

extension NativeTextViewCoordinator {
    struct SectionAnchor {
        let target: MarkdownSectionTarget
        let bodyStart: Int
        let end: Int
    }

    struct SectionNavigationState {
        var editor = UUID()
        var revision: (source: Int, document: Int)?
        var anchors: [SectionAnchor] = []
        var targets: [MarkdownSectionTarget] = []
        var snapshot: MarkdownSectionNavigationSnapshot?
        var scheduled = false
    }

    struct SectionNavigationRequest {
        let target: MarkdownSectionTarget
        let whileValid: () -> Bool
        let didNavigate: (ReadingPosition) -> Void
    }

    private var sectionNavigationAvailable: Bool {
        MainActor.assumeIsolated {
            editorController?.coordinator === self && editorController?.isSectionNavigationEnabled == true
        } && lastDisplayed && textView?.window != nil && textView?.enclosingScrollView?.isHidden == false
    }

    /// Retires presentation ownership without changing Find or the native input session.
    func invalidateSectionNavigation() {
        sectionNavigationState.editor = UUID()
        sectionNavigationState.revision = nil
        sectionNavigationState.anchors = []
        sectionNavigationState.targets = []
        if case .sectionNavigation = pendingFindCommand { pendingFindCommand = nil }
        publishSectionSnapshot(nil)
    }

    func scheduleSectionNavigationRefresh() {
        guard !sectionNavigationState.scheduled else { return }
        guard MainActor.assumeIsolated({ editorController?.isSectionNavigationEnabled == true }) else { return }
        sectionNavigationState.scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sectionNavigationState.scheduled = false
            self.refreshSectionNavigation()
        }
    }

    /// Uses the committed canonical receipt once per revision. Viewport refreshes only
    /// inspect available native line fragments and binary-search the compact anchors.
    func refreshSectionNavigation() {
        guard sectionNavigationAvailable, let view = textView as? NativeTextView,
              let receipt = cachedBlockParseRevision,
              receipt.source == nativeSourceGeneration, receipt.document == documentGeneration,
              let parsed = cachedBlockParse else {
            publishSectionSnapshot(nil)
            return
        }
        let changed = sectionNavigationState.revision?.source != receipt.source
            || sectionNavigationState.revision?.document != receipt.document
        if changed {
            let headings = parsed.blocks.filter { $0.kind == .heading }
            let source = view.textStorage?.mutableString ?? (view.string as NSString)
            sectionNavigationState.anchors = headings.enumerated().map { rank, block in
                var start = block.range.location
                let end = NSMaxRange(block.range)
                while start < end, [0x20, 0x09].contains(source.character(at: start)) { start += 1 }
                let markerStart = start
                while start < end, source.character(at: start) == 0x23 { start += 1 }
                let level = start - markerStart
                while start < end, source.character(at: start) == 0x20 { start += 1 }
                let title = Self.boundedSectionText(source, start: start, end: end, limit: 160)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let target = MarkdownSectionTarget(rank: rank, level: level, title: title.isEmpty ? "Untitled heading" : title,
                    editor: sectionNavigationState.editor, document: receipt.document,
                    source: receipt.source, anchor: block.range.location)
                return SectionAnchor(target: target, bodyStart: end,
                    end: rank + 1 < headings.count ? headings[rank + 1].range.location : source.length)
            }
            sectionNavigationState.targets = sectionNavigationState.anchors.map(\.target)
            sectionNavigationState.revision = receipt
        }
        let visible = visibleSectionRanks(in: view)
        guard changed || sectionNavigationState.snapshot == nil
                || sectionNavigationState.snapshot?.visibleRanks != visible else { return }
        publishSectionSnapshot(MarkdownSectionNavigationSnapshot(
            targets: sectionNavigationState.targets, visibleRanks: visible))
    }

    private func publishSectionSnapshot(_ snapshot: MarkdownSectionNavigationSnapshot?) {
        guard snapshot != nil || sectionNavigationState.snapshot != nil else { return }
        sectionNavigationState.snapshot = snapshot
        MainActor.assumeIsolated { editorController?.onSectionNavigationChange?(snapshot) }
    }

    private func currentSectionAnchor(_ target: MarkdownSectionTarget) -> SectionAnchor? {
        guard sectionNavigationAvailable, target.editor == sectionNavigationState.editor,
              target.document == documentGeneration, target.source == nativeSourceGeneration,
              cachedBlockParseRevision?.document == target.document,
              cachedBlockParseRevision?.source == target.source,
              sectionNavigationState.anchors.indices.contains(target.rank) else { return nil }
        let anchor = sectionNavigationState.anchors[target.rank]
        return anchor.target == target ? anchor : nil
    }

    func sectionPreview(for target: MarkdownSectionTarget) -> MarkdownSectionPreview? {
        guard let anchor = currentSectionAnchor(target), let view = textView,
              !isComposing(in: view), !isWritingToolsActive,
              let source = view.textStorage?.mutableString else { return nil }
        return MarkdownSectionPreview(title: target.title,
            body: Self.boundedSectionText(source, start: anchor.bodyStart, end: anchor.end, limit: 2048)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Truncate before the composed character crossing the budget, including CRLF.
    private static func boundedSectionText(_ source: NSString, start: Int, end: Int, limit: Int) -> String {
        guard start >= 0, start <= end, end <= source.length else { return "" }
        var stop = min(end, start + limit)
        if stop < end {
            let crossing = source.rangeOfComposedCharacterSequence(at: stop)
            if crossing.location < stop { stop = max(start, crossing.location) }
        }
        return source.substring(with: NSRange(location: start, length: stop - start))
    }

    func scrollToSection(_ target: MarkdownSectionTarget, whileValid: @escaping () -> Bool,
                         didNavigate: @escaping (ReadingPosition) -> Void) {
        guard currentSectionAnchor(target) != nil, let view = textView else { return }
        let request = SectionNavigationRequest(target: target, whileValid: whileValid, didNavigate: didNavigate)
        if isComposing(in: view) || isWritingToolsActive {
            pendingFindCommand = .sectionNavigation(request)
        } else {
            pendingFindCommand = nil
            executeSectionNavigation(request)
        }
    }

    func executeSectionNavigation(_ request: SectionNavigationRequest) {
        guard currentSectionAnchor(request.target) != nil, request.whileValid(),
              let view = textView as? NativeTextView, !isComposing(in: view), !isWritingToolsActive,
              let scroll = view.enclosingScrollView, let departure = view.readingPosition() else { return }
        // The host predicate may synchronously replace ownership or source.
        guard currentSectionAnchor(request.target) != nil else { return }
        let oldY = scroll.contentView.bounds.minY
        // Chrome clearance is configured in scroll-view points; saved reading
        // positions use document points, including under native magnification.
        let topClearance = view.convert(NSSize(width: 0, height: scroll.contentInsets.top), from: scroll).height
        guard view.restore(ReadingPosition(anchorOffset: request.target.anchor, offsetInViewport: topClearance,
                                          magnification: scroll.magnification)) else { return }
        refreshSectionNavigation()
        let arrival = view.readingPosition()
        let changed = abs(scroll.contentView.bounds.minY - oldY) > 0.5
            || arrival.map { $0.anchorOffset != departure.anchorOffset
                || abs($0.offsetInViewport - departure.offsetInViewport) > 0.5 } == true
        if changed { request.didNavigate(departure) }
    }

    private func visibleSectionRanks(in view: NativeTextView) -> Set<Int> {
        let anchors = sectionNavigationState.anchors
        guard !anchors.isEmpty, let layout = view.textLayoutManager,
              let content = layout.textContentManager else { return [] }
        let visible = view.visibleRect
        let origin = view.textContainerOrigin
        let start = layout.textViewportLayoutController.viewportRange?.location
            ?? layout.textLayoutFragment(for: NSPoint(x: 0, y: max(0, visible.minY)))?.rangeInElement.location
            ?? layout.documentRange.location
        var result: Set<Int> = []
        func inspect(_ fragment: NSTextLayoutFragment, reverse: Bool) -> Bool {
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if reverse && frame.maxY <= visible.minY { return false }
            if !reverse && frame.minY >= visible.maxY { return false }
            guard frame.intersects(visible), let element = fragment.textElement?.elementRange else { return true }
            let elementOffset = content.offset(from: content.documentRange.location, to: element.location)
            guard elementOffset >= 0, elementOffset != NSNotFound else { return true }
            for line in fragment.textLineFragments {
                let rect = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                guard rect.maxY > visible.minY, rect.minY < visible.maxY,
                      line.characterRange.location != NSNotFound else { continue }
                let offset = elementOffset + line.characterRange.location
                guard foldLayout.hiddenRange(containing: offset) == nil else { continue }
                let end = offset + max(1, line.characterRange.length)
                var low = 0, high = anchors.count
                while low < high {
                    let mid = (low + high) / 2
                    if anchors[mid].target.anchor <= offset { low = mid + 1 } else { high = mid }
                }
                var rank = max(0, low - 1)
                while rank < anchors.count, anchors[rank].target.anchor < end {
                    if anchors[rank].end > offset { result.insert(rank) }
                    rank += 1
                }
            }
            return true
        }
        layout.enumerateTextLayoutFragments(from: start, options: []) { inspect($0, reverse: false) }
        layout.enumerateTextLayoutFragments(from: start, options: [.reverse]) { inspect($0, reverse: true) }
        return result
    }
}
