import AppKit

/// Native text input operates only on visible semantic characters.
@MainActor
final class NativeSemanticTextView: NSTextView {
    weak var semanticCoordinator: NativeSemanticDocumentCoordinator?
    private(set) var isSettingMarkedText = false
    private(set) var isCommittingMarkedText = false
    var semanticViewportPinDepth = 0

    var semanticTableProxy: TableProxyScroller?
    private var tableTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tableTracking { removeTrackingArea(tableTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tableTracking = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        semanticCoordinator?.imageControls?.hover(at: point)
        for session in semanticTableSessions() { session.hoverChrome(at: point) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        semanticCoordinator?.imageControls?.hover(at: nil)
        for session in semanticTableSessions() { session.chrome?.removeFromSuperview() }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { semanticCoordinator?.preferredInputView = self }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSemanticCodeBackgrounds()
        super.draw(dirtyRect)
        drawSemanticQuoteRules()
    }

    override func layout() {
        preservingSemanticViewport(requireEdit: false, revealCaret: false) {
            super.layout()
            updateSemanticGeometry()
            refreshSemanticTables()
            refreshSemanticSourceBlocks()
            semanticCoordinator?.imageControls?.refresh()
        }
        semanticCoordinator?.onLayoutChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let configuration = semanticCoordinator?.configuration, let reading = configuration.readingWidth {
            size.width = max(size.width, reading + configuration.horizontalLayoutInset * 2 + comments_commentLaneReserve)
        }
        super.setFrameSize(size)
        updateSemanticGeometry()
    }

    func updateSemanticGeometry() {
        guard let configuration = semanticCoordinator?.configuration, let container = textContainer else { return }
        let minimum = configuration.horizontalLayoutInset
        let available = max(1, bounds.width)
        let lane = max(0, comments_commentLaneReserve)
        let reading = configuration.readingWidth
        let unscaledWidth = enclosingScrollView?.contentView.frame.width ?? available
        let zoomedOut = (enclosingScrollView?.magnification ?? 1) < 1
        let wrap = reading ?? max(1, (zoomedOut ? min(available, unscaledWidth) : available) - minimum * 2 - lane)
        let center = reading != nil || (zoomedOut && configuration.centersZoomedOutColumn)
        let inset = center ? max(minimum, (available - wrap - lane) / 2) : minimum
        let desired = NSSize(width: inset, height: configuration.textInsets.vertical)
        if textContainerInset != desired { textContainerInset = desired }
        container.widthTracksTextView = false
        if abs(container.size.width - wrap) > 0.5 {
            container.size = NSSize(width: wrap, height: .greatestFiniteMagnitude)
        }
    }

    override func mouseDown(with event: NSEvent) {
        semanticCoordinator?.onRequestFocus?()
        if semanticCoordinator?.imageControls?.mouseDown(event) == true { return }
        if semanticCoordinator?.routeChecklistClick(event) == true { return }
        refreshSemanticTables()
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            let index = characterIndexForInsertion(at: point)
            if let storage = textStorage, index < storage.length, storage.attribute(.attachment, at: index, effectiveRange: nil) != nil {
                setSelectedRange(NSRange(location: index, length: 1))
                semanticCoordinator?.editObject(at: index)
                return
            }
        }
        if let grid = subviews.compactMap({ $0 as? MarkdownTableGridView }).last(where: { $0.frame.contains(point) }) {
            grid.mouseDown(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        preservingSemanticViewport { super.keyDown(with: event) }
    }

    override func deleteBackward(_ sender: Any?) {
        preservingSemanticViewport { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        preservingSemanticViewport { super.deleteForward(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        preservingSemanticViewport { performSemanticKeyEquivalent(with: event) }
    }

    private func performSemanticKeyEquivalent(with event: NSEvent) -> Bool {
        if semanticCoordinator?.handleKeyEquivalent(event, in: self) == true { return true }
        // A stale direct request must not fall through to a native font action on a foreign field.
        guard window?.firstResponder === self, isEditable else { return false }
        return super.performKeyEquivalent(with: event)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if semanticCoordinator?.acceptFileDrop(sender.draggingPasteboard) == true { return true }
        guard let value = sender.draggingPasteboard.string(forType: .string) else { return false }
        return semanticCoordinator?.pasteText(value) == true
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        semanticCoordinator?.paste(from: pboard) == true
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        semanticCoordinator?.copySelection(to: pboard) == true
    }

    override func copy(_ sender: Any?) {
        _ = semanticCoordinator?.copySelection(to: .general)
    }

    override func cut(_ sender: Any?) {
        preservingSemanticViewport { cutSemanticSelection(sender) }
    }

    private func cutSemanticSelection(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), semanticCoordinator?.copySelection(to: .general) == true else { return }
        _ = semanticCoordinator?.replaceVisible(selectedRange(), with: NSAttributedString(string: ""), actionName: "Cut")
    }

    override func paste(_ sender: Any?) {
        preservingSemanticViewport { _ = semanticCoordinator?.paste(from: .general) }
    }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    @objc func copyAsMarkdown(_ sender: Any?) { _ = semanticCoordinator?.copySelection(to: .general, asMarkdown: true) }
    @objc func pasteAsMarkdown(_ sender: Any?) { _ = semanticCoordinator?.paste(from: .general, asMarkdown: true) }

    override func insertNewline(_ sender: Any?) {
        preservingSemanticViewport { insertSemanticNewline(sender) }
    }

    private func insertSemanticNewline(_ sender: Any?) {
        if semanticCoordinator?.insertParagraphBreak() == true { return }
        super.insertNewline(sender)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let range = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            guard semanticCoordinator?.beginComposition(replacing: range) != false else { return }
        }
        isSettingMarkedText = true
        defer {
            isSettingMarkedText = false
            if !hasMarkedText() { semanticCoordinator?.finishedComposition() }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        preservingSemanticViewport { insertSemanticText(string, replacementRange: replacementRange) }
    }

    private func insertSemanticText(_ string: Any, replacementRange: NSRange) {
        let committing = hasMarkedText()
        if !committing, let attributes = semanticCoordinator?.safeTypingAttributes() { typingAttributes = attributes }
        isCommittingMarkedText = committing
        super.insertText(string, replacementRange: replacementRange)
        isCommittingMarkedText = false
        if committing { semanticCoordinator?.finishedComposition() }
        else if (string as? String) == " " { semanticCoordinator?.completeTypedBlockPrefix() }
        else if let typed = string as? String, typed.count == 1, "*_~=```".contains(typed) {
            semanticCoordinator?.completeTypedInlineSyntax()
        }
    }

    override func unmarkText() {
        let committing = hasMarkedText() && !isCommittingMarkedText
        if committing { isCommittingMarkedText = true }
        super.unmarkText()
        if committing {
            isCommittingMarkedText = false
            semanticCoordinator?.finishedComposition()
        }
    }
}
