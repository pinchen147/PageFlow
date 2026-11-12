import AppKit

extension NativeSemanticTextView {
    /// Native input can replace TextKit's estimated paragraph origins while it
    /// scrolls the caret. Keep a visible line stationary, then reveal only the
    /// part of the resulting caret that lies outside the viewport.
    func preservingSemanticViewport<T>(requireEdit: Bool = true, revealCaret: Bool = true, _ body: () -> T) -> T {
        guard semanticViewportPinDepth == 0,
              semanticCoordinator?.tableWidthsController?.semanticHost?.isRestoringViewport != true,
              window != nil, !isHiddenOrHasHiddenAncestor,
              !hasMarkedText(), semanticCoordinator?.isWritingToolsActive != true,
              let scroll = enclosingScrollView, let storage = textStorage,
              let layout = textLayoutManager,
              let pin = semanticViewportPin() else { return body() }
        semanticViewportPinDepth += 1
        defer { semanticViewportPinDepth -= 1 }
        let magnification = scroll.magnification
        let blockPin = semanticBlockPin(at: pin.offset, in: storage)
        var offset = pin.offset
        var changed = false
        var replacedDocument = false
        // Both the pin and editedRange use visible UTF-16 coordinates. Source
        // punctuation never participates in this native-input transaction.
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                changed = true
                guard storage.editedMask.contains(.editedCharacters) else { return }
                let range = storage.editedRange
                guard range.location != NSNotFound else { return }
                let oldEnd = range.location + max(0, range.length - storage.changeInLength)
                if range.location == 0, oldEnd == storage.length - storage.changeInLength {
                    replacedDocument = true
                }
                if offset > range.location {
                    offset = offset >= oldEnd ? offset + storage.changeInLength : range.location
                }
            }
        }
        let result = body()
        NotificationCenter.default.removeObserver(observer)
        guard (changed || !requireEdit), scroll.magnification == magnification, !hasMarkedText(), semanticCoordinator?.isWritingToolsActive != true,
              storage.length > 0 else { return result }
        if replacedDocument, let blockPin {
            offset = resolveSemanticBlockPin(blockPin, in: storage) ?? min(selectedRange().location, storage.length - 1)
        }
        offset = min(max(0, offset), storage.length - 1)
        let clip = scroll.contentView
        for _ in 0..<6 {
            guard let line = semanticInputLineRect(at: offset) else { break }
            let top = convert(clip.bounds, from: clip).minY
            let correction = line.minY - pin.inset - top
            if abs(correction) < 0.5 { break }
            let rest = (scroll as? ClampedScrollView)?.restingOriginY ?? -CGFloat.greatestFiniteMagnitude
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(rest, clip.bounds.minY + correction)))
            scroll.reflectScrolledClipView(clip)
            layout.textViewportLayoutController.layoutViewport()
        }
        let caret = min(selectedRange().location, storage.length)
        if revealCaret, let line = semanticInputLineRect(at: caret) {
            let rawViewport = convert(clip.bounds, from: clip)
            let topInset = scroll.contentInsets.top / max(0.01, scroll.magnification)
            let bottomInset = scroll.contentInsets.bottom / max(0.01, scroll.magnification)
            let viewport = NSRect(x: rawViewport.minX, y: rawViewport.minY + topInset,
                width: rawViewport.width, height: max(1, rawViewport.height - topInset - bottomInset))
            let correction: CGFloat
            if line.minY < viewport.minY { correction = line.minY - viewport.minY }
            else if line.maxY > viewport.maxY { correction = line.maxY - viewport.maxY }
            else { correction = 0 }
            if abs(correction) > 0.5 {
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + correction))
                scroll.reflectScrolledClipView(clip)
                layout.textViewportLayoutController.layoutViewport()
            }
        }
        return result
    }

    private struct SemanticBlockPin {
        let id: UUID
        let localOffset: Int
        let previous: UUID?
        let next: UUID?
    }

    private func semanticBlockPin(at offset: Int, in storage: NSTextStorage) -> SemanticBlockPin? {
        guard offset >= 0, offset < storage.length else { return nil }
        var range = NSRange()
        guard let id = storage.attribute(NativeSemanticAttributes.blockID, at: offset,
            longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? UUID else { return nil }
        let previous = range.location > 0
            ? storage.attribute(NativeSemanticAttributes.blockID, at: range.location - 1, effectiveRange: nil) as? UUID : nil
        let next = NSMaxRange(range) < storage.length
            ? storage.attribute(NativeSemanticAttributes.blockID, at: NSMaxRange(range), effectiveRange: nil) as? UUID : nil
        return SemanticBlockPin(id: id, localOffset: offset - range.location, previous: previous, next: next)
    }

    private func resolveSemanticBlockPin(_ pin: SemanticBlockPin, in storage: NSTextStorage) -> Int? {
        var own: NSRange?
        var previous: NSRange?
        var next: NSRange?
        storage.enumerateAttribute(NativeSemanticAttributes.blockID,
            in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? UUID else { return }
            if id == pin.id { own = range }
            if id == pin.previous { previous = range }
            if id == pin.next { next = range }
        }
        if let own { return own.location + min(pin.localOffset, max(0, own.length - 1)) }
        if let next { return next.location }
        if let previous { return max(previous.location, NSMaxRange(previous) - 1) }
        return nil
    }

    private func semanticViewportPin() -> (offset: Int, inset: CGFloat)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let scroll = enclosingScrollView, scroll.contentView.bounds.height > 0 else { return nil }
        let clip = scroll.contentView
        let top = convert(clip.bounds, from: clip).minY
        let probe = max(visibleRect.minY, top + scroll.contentInsets.top / max(0.01, scroll.magnification)) + 8
        var result: (Int, CGFloat)?
        let start = layout.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            guard frame.maxY > probe else { return true }
            guard frame.minY < top + clip.bounds.height else { return false }
            guard let line = fragment.textLineFragment(forVerticalOffset: probe - frame.minY, requiresExactMatch: false),
                  let element = fragment.textElement?.elementRange,
                  let location = content.location(element.location, offsetBy: line.characterRange.location) else { return false }
            result = (content.offset(from: content.documentRange.location, to: location), frame.minY + line.typographicBounds.minY - top)
            return false
        }
        return result
    }

    private func semanticInputLineRect(at offset: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location),
              let element = fragment.textElement?.elementRange else { return nil }
        let local = content.offset(from: element.location, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(local, $0.characterRange) })
                ?? fragment.textLineFragments.last else { return nil }
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x,
                                               dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
    }
}
