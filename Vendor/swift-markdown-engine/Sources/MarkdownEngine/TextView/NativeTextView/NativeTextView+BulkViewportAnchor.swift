import AppKit

struct BulkViewportAnchor {
    let offset: Int
    let offsetInViewport: CGFloat
    let clipBounds: CGRect
    let selection: NSRange
    let sourceGeneration: Int

    func isCurrent(in view: NativeTextView, sourceGeneration: Int) -> Bool {
        let currentSelection = view.selectedRange()
        // Select All changes the command's scope, not the reading position.
        // Caret and partial-selection changes still relinquish this receipt.
        let selectsAll = currentSelection.location == 0
            && currentSelection.length == view.textStorage?.length
        return self.sourceGeneration == sourceGeneration
            && (selection == currentSelection || selectsAll)
            && clipBounds == view.enclosingScrollView?.contentView.bounds
    }
}

extension NativeTextView {
    /// Attribute/overlay callbacks can arrive after the deferred queue drained.
    /// Continue the bulk source while the user has not moved or edited it.
    func continueBulkViewportAnchor(_ body: () -> Void) -> Bool {
        guard viewportPinDepth == 0, enclosingScrollView?.isHidden == false,
              let coordinator = delegate as? NativeTextViewCoordinator,
              let receipt = coordinator.bulkViewportAnchor else { return false }
        guard receipt.isCurrent(in: self, sourceGeneration: coordinator.nativeSourceGeneration),
              !coordinator.isComposing(in: self), !coordinator.isWritingToolsActive,
              textLayoutManager?.textContentManager != nil else {
            coordinator.bulkViewportAnchor = nil
            return false
        }
        coordinator.restylePreservingViewport(self, anchoringVisibleSource: true, body)
        return true
    }

    /// Bulk replacements invalidate the estimated layout chain. Hold an actual
    /// visible source paragraph across its subsequent viewport passes, rather
    /// than hit-testing the new estimates after each correction.
    /// Returns false without running `body` when no visible source can be read.
    func preservingVisibleSourceAnchor(
        continuing receipt: inout BulkViewportAnchor?,
        sourceGeneration: () -> Int,
        settle: (Int) -> Void,
        mapPin: ((Int) -> Int)?,
        _ body: () -> Void
    ) -> Bool {
        guard viewportPinDepth == 0, let scroll = enclosingScrollView, !scroll.isHidden,
              let layout = textLayoutManager, let content = layout.textContentManager else { return false }
        let anchor: (offset: Int, offsetInViewport: CGFloat)
        if let receipt, receipt.isCurrent(in: self, sourceGeneration: sourceGeneration()) {
            anchor = (receipt.offset, receipt.offsetInViewport)
        } else if let captured = visibleSourceParagraphAnchor() {
            anchor = captured
        } else {
            receipt = nil
            return false
        }
        receipt = nil
        viewportPinDepth += 1
        defer { viewportPinDepth -= 1 }
        body()
        let offset = mapPin?(anchor.offset) ?? anchor.offset
        guard offset >= 0, offset < (textStorage?.length ?? 0),
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return true }

        // Moving the clip can cause TextKit to revise the estimated chain on
        // its next viewport pass. Recheck the SAME source after that pass. This
        // is synchronous and bounded. Its receipt survives only unchanged
        // source, selection and clip bounds while this bulk edit finishes.
        for _ in 0..<4 {
            settle(offset)
            if layout.textLayoutFragment(for: location)?.state != .layoutAvailable {
                layout.ensureLayout(for: NSTextRange(location: location))
            }
            guard let fragment = layout.textLayoutFragment(for: location),
                  fragment.state == .layoutAvailable else { break }
            let top = fragment.layoutFragmentFrame.minY + textContainerOrigin.y
            let delta = top - anchor.offsetInViewport - visibleRect.minY
            guard delta.isFinite, abs(delta) > 0.5 else { break }
            let clip = scroll.contentView
            let before = clip.bounds.origin
            ScrollTrace.stamp(String(format: "bulkViewportPin(Δ%.1f, pinLoc=%d)", delta, offset))
            clip.scroll(to: NSPoint(x: before.x, y: before.y + delta))
            scroll.reflectScrolledClipView(clip)
            (scroll as? ClampedScrollView)?.clampToInsets()
            if clip.bounds.origin == before { break }
        }
        receipt = BulkViewportAnchor(offset: offset, offsetInViewport: anchor.offsetInViewport,
                                     clipBounds: scroll.contentView.bounds, selection: selectedRange(),
                                     sourceGeneration: sourceGeneration())
        return true
    }

    private func visibleSourceParagraphAnchor() -> (offset: Int, offsetInViewport: CGFloat)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let storage = textStorage else { return nil }
        let visible = visibleRect
        guard visible.height > 0 else { return nil }
        let origin = textContainerOrigin
        guard let start = layout.textViewportLayoutController.viewportRange?.location else { return nil }
        var remainingFragments = 128
        var remainingLines = 256
        var result: (offset: Int, offsetInViewport: CGFloat)?
        func inspect(_ fragment: NSTextLayoutFragment, reverse: Bool) -> Bool {
            guard remainingFragments > 0, remainingLines > 0 else { return false }
            remainingFragments -= 1
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.maxY <= visible.minY { return !reverse }
            if frame.minY >= visible.maxY { return reverse }
            guard fragment.state == .layoutAvailable,
                  let elementRange = fragment.textElement?.elementRange else { return true }
            let elementStart = content.offset(from: content.documentRange.location, to: elementRange.location)
            guard elementStart != NSNotFound, elementStart >= 0 else { return true }
            for line in fragment.textLineFragments {
                guard remainingLines > 0 else { return false }
                remainingLines -= 1
                let lineFrame = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                guard line.characterRange.location != NSNotFound, line.characterRange.length > 0,
                      lineFrame.height >= 1, lineFrame.minY >= visible.minY,
                      lineFrame.maxY <= visible.maxY else { continue }
                let range = NSRange(location: elementStart + line.characterRange.location,
                                    length: line.characterRange.length)
                guard range.location <= storage.length, range.length <= storage.length - range.location else { continue }
                var readable = false
                var raster = false
                storage.enumerateAttributes(in: range) { attributes, _, _ in
                    if let font = attributes[.font] as? NSFont, font.pointSize > 1 { readable = true }
                    if attributes[.renderedBlockImage] is NSImage { raster = true }
                }
                guard readable, !raster else { continue }
                result = (elementStart, frame.minY - visible.minY)
                return false
            }
            return true
        }
        layout.enumerateTextLayoutFragments(from: start, options: []) {
            inspect($0, reverse: false)
        }
        if result == nil {
            // Native scrolling can expose already-laid-out source above a
            // stale viewportRange. Search backward without asking for layout,
            // sharing the same finite work budget with the forward search.
            layout.enumerateTextLayoutFragments(from: start, options: [.reverse]) {
                inspect($0, reverse: true)
            }
        }
        return result
    }
}
