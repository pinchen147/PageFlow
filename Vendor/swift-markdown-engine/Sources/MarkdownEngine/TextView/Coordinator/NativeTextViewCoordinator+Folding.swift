import AppKit

struct FoldingCommandState: Equatable {
    let toggle: Bool
    let collapseAll: Bool
    let expandAll: Bool
    let currentClosed: Bool
}

extension NativeTextViewCoordinator {
    var foldSession: MarkdownFoldSession {
        MainActor.assumeIsolated { editorController?.foldSession } ?? localFoldSession
    }

    func installFolding(in view: NativeTextView) {
        (view.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = foldLayout
        if foldControls == nil { foldControls = MarkdownFoldControls(coordinator: self, view: view) }
        observeFoldSource(in: view)
    }

    /// Called only when source or canonical structure changes, never by pointer/layout callbacks.
    func synchronizeFolding(edit: TextChange? = nil) {
        guard let view = textView as? NativeTextView, let storage = view.textStorage,
              !isComposing(in: view), !isWritingToolsActive else { return }
        let source = storage.mutableString
        if foldBoundSession === foldSession, foldSourceGeneration == nativeSourceGeneration {
            if foldIndexNeedsReconciliation { reconcileFoldIndex(in: source) }
            applyFoldPresentation()
            return
        }
        if let edit, foldBoundSession === foldSession, foldSourceGeneration == nativeSourceGeneration - 1,
           mapFoldSourceEdit(edit, resultingLength: source.length) {
            foldSourceGeneration = nativeSourceGeneration
            reconcileFoldIndex(in: source)
            applyFoldPresentation()
            return
        }
        if let snapshot = cachedBlockParse, utf16(snapshot.characters, equals: source) {
            foldSession.update(source: source, blocks: snapshot.blocks,
                               edit: edit.map { (range: $0.oldRange, replacementLength: $0.replacementLength) })
            _ = foldSession.reindex(source: source, blocks: snapshot.blocks)
            cancelFoldIndex()
        } else {
            // A foreign replacement has no mapping receipt. Clear ambiguous visibility now;
            // canonical structure is rebuilt off main, including for a long initial mount.
            foldSession.update(source: source, blocks: [], edit: nil)
            scheduleFoldIndex()
        }
        foldBoundSession = foldSession
        foldSourceGeneration = nativeSourceGeneration
        applyFoldPresentation()
    }

    /// Native storage rebases its elements after an edit. Moving their source addresses does
    /// not change omission or summary height and must not invalidate the layout again.
    func mapFoldSourceEdit(_ edit: TextChange, resultingLength: Int) -> Bool {
        let session = foldSession
        let closedCount = session.collapsedHeadings.count
        let canRebase = !foldPresentationNeedsRefresh
            && !session.collapsedHeadings.contains(edit.oldRange.location)
            && foldLayout.hiddenRanges == session.hiddenRanges
            && lastFoldClosedHeadings == session.collapsedHeadings
        guard session.applyMappedEdit(range: edit.oldRange, replacement: edit.replacement,
                                      resultingLength: resultingLength) else { return false }
        if canRebase, closedCount == session.collapsedHeadings.count {
            let end = NSMaxRange(edit.oldRange)
            foldLayout.summaryHeadings = Set(foldLayout.summaryHeadings.compactMap { offset in
                if offset < edit.oldRange.location { return offset }
                if offset >= end { return offset + edit.delta }
                return nil
            })
            foldLayout.hiddenRanges = session.hiddenRanges
            lastFoldClosedHeadings = session.collapsedHeadings
        } else {
            foldPresentationNeedsRefresh = true
        }
        return true
    }

    private func cancelFoldIndex() {
        foldIndexTask?.cancel()
        foldIndexTask = nil
        foldIndexNeedsReconciliation = false
    }

    private func reconcileFoldIndex(in source: NSString) {
        if let snapshot = cachedBlockParse, utf16(snapshot.characters, equals: source),
           foldSession.reindex(source: source, blocks: snapshot.blocks) {
            cancelFoldIndex()
        } else {
            scheduleFoldIndex()
        }
    }

    /// Reuse the canonical parser's retained snapshot and incremental seam logic. Hidden tabs
    /// retain the reconciliation debt and resume it on their next displayed update.
    func scheduleFoldIndex() {
        foldIndexTask?.cancel()
        foldIndexTask = nil
        foldIndexNeedsReconciliation = true
        guard lastDisplayed else { return }
        let generation = nativeSourceGeneration
        let document = documentGeneration
        let session = foldSession
        foldIndexTask = Task { @MainActor [weak self, weak session] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, let session, let view = self.textView, self.lastDisplayed,
                  self.nativeSourceGeneration == generation, self.documentGeneration == document,
                  self.foldSession === session,
                  !self.isComposing(in: view), !self.isWritingToolsActive else { return }
            let source = view.string
            let previous = self.cachedBlockParse
            let snapshot = await Task.detached(priority: .utility) {
                BlockParser.snapshot(parsing: source as NSString, reusing: previous)
            }.value
            guard !Task.isCancelled, self.lastDisplayed,
                  self.nativeSourceGeneration == generation, self.documentGeneration == document,
                  self.foldSession === session, !self.isComposing(in: view), !self.isWritingToolsActive,
                  session.reindex(source: source as NSString, blocks: snapshot.blocks) else { return }
            self.cachedBlockParse = snapshot
            self.foldIndexTask = nil
            self.foldIndexNeedsReconciliation = false
            if view.selectedRange().length == 0 { _ = session.reveal(view.selectedRange()) }
            self.applyFoldPresentation()
        }
    }

    func beginFoldComposition(replacing range: NSRange, in view: NSTextView) {
        guard foldBoundSession === foldSession, foldSourceGeneration == nativeSourceGeneration else { return }
        foldCompositionStart = (range, view.textStorage?.length ?? 0, nativeSourceGeneration)
    }

    func committedFoldComposition(in view: NSTextView) -> TextChange? {
        guard let start = foldCompositionStart else { return nil }
        foldCompositionStart = nil
        guard start.generation == nativeSourceGeneration - 1, let source = view.textStorage?.mutableString else { return nil }
        let insertedLength = source.length - start.length + start.range.length
        guard insertedLength >= 0, start.range.location <= source.length,
              insertedLength <= source.length - start.range.location else { return nil }
        return TextChange(oldRange: start.range, replacement: source.substring(with: NSRange(location: start.range.location, length: insertedLength)))
    }

    var currentFoldRegion: MarkdownFoldRegion? {
        guard let view = textView else { return nil }
        let caret = view.selectedRange().location
        let regions = foldSession.index.regions
        var low = 0, high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].heading.location <= caret { low = middle + 1 } else { high = middle }
        }
        return regions[..<low].reversed().first { region in
            caret < NSMaxRange(region.body)
                || (caret == (view.textStorage?.length ?? 0) && caret == NSMaxRange(region.body))
        }
    }

    var foldingInteractionAllowed: Bool {
        guard let view = textView as? NativeTextView, lastDisplayed,
              !isComposing(in: view), !isWritingToolsActive,
              imageControls?.isInteracting != true, !blockMover.isDragging,
              blockMover.dropSession == nil, view.fileDrag == nil,
              view.dragStartMouseScreenLoc == nil, selectionBar?.isDragSelecting != true else { return false }
        if #available(macOS 15.0, *), view.isWritingToolsActive { return false }
        return true
    }

    func canPerformFolding(_ command: MarkdownEditorKeyCommand) -> Bool {
        guard foldingInteractionAllowed else { return false }
        switch command {
        case .toggleFold: return currentFoldRegion != nil
        case .collapseAll: return foldSession.collapsedHeadings.count < foldSession.index.regions.count
        case .expandAll: return !foldSession.collapsedHeadings.isEmpty
        default: return false
        }
    }

    @discardableResult
    func performFolding(_ command: MarkdownEditorKeyCommand, heading: Int? = nil) -> Bool {
        guard foldingInteractionAllowed, (heading != nil || canPerformFolding(command)),
              let view = textView as? NativeTextView else { return false }
        let target = heading ?? currentFoldRegion?.heading.location
        let priorLength = view.textStorage?.length ?? 0
        let priorCaret = view.selectedRange().location
        let hadCellFocus = view.window?.firstResponder === tableEditingSession.editor
        if tableEditingSession.isActive, !tableEditingSession.commitInput() { return false }
        tableEditingSession.finishInput()
        guard !tableEditingSession.isComposing else { return false }
        tableEditingSession.retire()
        let delta = (view.textStorage?.length ?? 0) - priorLength
        let mappedTarget = target.map { $0 > priorCaret ? $0 + delta : $0 }
        if hadCellFocus, let mappedTarget, let region = foldSession.index.regions.first(where: { $0.heading.location == mappedTarget }) {
            view.setSelectedRange(NSRange(location: Self.contentEnd(of: region.heading, in: view.textStorage!.mutableString), length: 0))
        }
        switch command {
        case .toggleFold:
            guard let mappedTarget else { return false }
            foldSession.toggle(at: mappedTarget)
        case .collapseAll: foldSession.collapseAll()
        case .expandAll: foldSession.expandAll()
        default: return false
        }
        let selection = view.selectedRange()
        if let covering = foldSession.index.regions.first(where: {
            foldSession.collapsedHeadings.contains($0.heading.location)
                && (NSIntersectionRange($0.body, selection).length > 0
                    || (selection.length == 0 && selection.location >= $0.body.location
                        && (selection.location < NSMaxRange($0.body)
                            || (selection.location == storageLength(view) && selection.location == NSMaxRange($0.body)))))
        }) {
            let source = view.textStorage!.mutableString
            let caret = Self.contentEnd(of: covering.heading, in: source)
            view.setSelectedRange(NSRange(location: caret, length: 0))
        }
        applyFoldPresentation()
        return true
    }

    /// One admission point before source and clipboard mutation; never part of text Undo.
    func admitFoldedEdit(_ range: NSRange, in view: NSTextView) -> Bool {
        // Initial marked input is admitted by NativeTextView before mutation. Subsequent
        // provisional replacements belong to AppKit and precede the mapped source receipt.
        if isComposing(in: view) { return true }
        if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
            _ = revealFoldedSource(range)
            return true
        }
        let event = foldCurrentKeyEvent ?? NSApp.currentEvent
        if foldBlockedKeyCode != nil, event?.isARepeat == true { return false }
        guard revealFoldedSource(range) else { return true }
        if let event, event.type == .keyDown { foldBlockedKeyCode = event.keyCode }
        return false
    }

    @discardableResult
    func revealFoldedSource(_ range: NSRange) -> Bool {
        guard foldSession.reveal(range) else { return false }
        applyFoldPresentation()
        return true
    }

    func applyFoldPresentation() {
        guard let view = textView as? NativeTextView, let storage = view.textStorage,
              let layout = view.textLayoutManager else { return }
        let session = foldSession
        var visibleClosed: [MarkdownFoldRegion] = []
        let needsSummaries = foldPresentationNeedsRefresh || foldLayout.hiddenRanges != session.hiddenRanges
            || lastFoldClosedHeadings != session.collapsedHeadings
            || lastFoldSummaryPreference != configuration.showsHiddenContentRow
        var summaries = foldLayout.summaryHeadings
        if needsSummaries {
            // Both sequences are source-sorted. One sweep avoids N² Collapse All.
            var hidden = 0
            for region in session.index.regions where session.collapsedHeadings.contains(region.heading.location) {
                while hidden < session.hiddenRanges.count, NSMaxRange(session.hiddenRanges[hidden]) <= region.heading.location { hidden += 1 }
                if hidden < session.hiddenRanges.count, NSLocationInRange(region.heading.location, session.hiddenRanges[hidden]) { continue }
                visibleClosed.append(region)
            }
            summaries = configuration.showsHiddenContentRow ? Set(visibleClosed.map { $0.heading.location }) : []
            lastFoldClosedHeadings = session.collapsedHeadings
            lastFoldSummaryPreference = configuration.showsHiddenContentRow
        }
        let changed = foldPresentationNeedsRefresh || foldLayout.hiddenRanges != foldSession.hiddenRanges || foldLayout.summaryHeadings != summaries
        foldPresentationNeedsRefresh = false
        if changed {
            var witness = view.readingPosition()
            if let anchor = witness?.anchorOffset, foldSession.hiddenRanges.contains(where: { NSLocationInRange(anchor, $0) }) {
                witness = visibleClosed.first(where: { NSLocationInRange(anchor, $0.body) }).map {
                    ReadingPosition(anchorOffset: $0.heading.location, offsetInViewport: 0,
                                    magnification: view.enclosingScrollView?.magnification ?? 1)
                }
            }
            let oldSummaries = foldLayout.summaryHeadings
            foldLayout.hiddenRanges = foldSession.hiddenRanges
            foldLayout.summaryHeadings = summaries
            // One notification invalidates cached custom paragraphs for this disclosure change.
            // Per-heading notifications repeatedly walk every cached element during Collapse All.
            let changedSummaries = oldSummaries.symmetricDifference(summaries)
            var summaryRange: NSRange?
            for region in session.index.regions where changedSummaries.contains(region.heading.location) {
                guard NSMaxRange(region.heading) <= storage.length else { continue }
                summaryRange = summaryRange.map { NSUnionRange($0, region.heading) } ?? region.heading
            }
            if let summaryRange { storage.edited(.editedAttributes, range: summaryRange, changeInLength: 0) }
            layout.invalidateLayout(for: layout.documentRange)
            view.ensureWholeNoteLayoutUnlessLong()
            view.ensureVisibleLayout()
            view.pendingFullLayoutMeasure = true
            if let scroll = view.enclosingScrollView { view.refreshOverscrollAfterTextEdit(for: scroll) }
            if let witness { _ = view.restore(witness) }
            view.needsDisplay = true
            blockMover.hide()
            blockMover.invalidate()
            tableChrome?.invalidate()
            blockMover.dropSession?.generation = -1
            view.fileDrag?.slotsBuiltFor = .null
            view.removeAllWideTableOverlays()
            view.updateWideTableOverlays()
            imageChrome?.refresh()
            if let comments { MainActor.assumeIsolated { comments.refresh() } }
        }
        foldControls?.refresh()
        notifyFoldingStateChange()
    }

    private func storageLength(_ view: NSTextView) -> Int { view.textStorage?.length ?? 0 }

    func notifyFoldingStateChange() {
        let closed = currentFoldRegion.map { foldSession.collapsedHeadings.contains($0.heading.location) } ?? false
        let state = FoldingCommandState(toggle: canPerformFolding(.toggleFold), collapseAll: canPerformFolding(.collapseAll),
                                        expandAll: canPerformFolding(.expandAll), currentClosed: closed)
        guard state != lastFoldingCommandState else { return }
        lastFoldingCommandState = state
        MainActor.assumeIsolated { editorController?.onFoldingStateChange?() }
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                         toCharacterRange newRange: NSRange) -> NSRange {
        guard newRange.length == 0, pendingEditedRange == nil, !isApplyingSpanEdit,
              !isProgrammaticEdit, !isUpdatingSourceOrStyle, !isComposing(in: textView),
              let hidden = foldLayout.hiddenRange(containing: newRange.location) else { return newRange }
        if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            _ = revealFoldedSource(newRange)
            return newRange
        }
        if newRange.location >= oldRange.location {
            return NSRange(location: NSMaxRange(hidden), length: 0)
        }
        return NSRange(location: max(0, hidden.location - 1), length: 0)
    }
}
