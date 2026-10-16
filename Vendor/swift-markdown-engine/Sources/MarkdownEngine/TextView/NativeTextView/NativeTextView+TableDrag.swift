import AppKit

/// The drop side of the table handle's drag (doc 24 §5.7.6): the table lands
/// between top-level blocks, shown by a 4 pt accent bar; other drags are
/// NSTextView's.
extension NativeTextView {
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [TableChromeController.tableMoveType]
    }

    private func isTableMove(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [TableChromeController.tableMoveType]) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isTableMove(sender) else { return super.draggingEntered(sender) }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isTableMove(sender) else { return super.draggingUpdated(sender) }
        guard isEditable, let boundary = tableDropBoundary(at: convert(sender.draggingLocation, from: nil)) else {
            hideTableDropIndicator()
            return []
        }
        showTableDropIndicator(at: boundary)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideTableDropIndicator()
        if let sender, isTableMove(sender) { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTableMove(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isTableMove(sender) else { return super.performDragOperation(sender) }
        hideTableDropIndicator()
        guard let coordinator = delegate as? NativeTextViewCoordinator,
              let value = sender.draggingPasteboard.string(forType: TableChromeController.tableMoveType), let location = Int(value),
              let token = coordinator.parsedDocument(for: string).tokens.first(where: { $0.kind == .table && $0.range.location == location }),
              let boundary = tableDropBoundary(at: convert(sender.draggingLocation, from: nil)) else { return false }
        return coordinator.moveTable(token.range, to: boundary)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, isTableMove(sender) { return }
        super.concludeDragOperation(sender)
    }

    /// The block boundary nearest `point`: the start of the block under it or
    /// of the next block, whichever line top is closer.
    func tableDropBoundary(at point: NSPoint) -> Int? {
        let text = string as NSString
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return nil }
        let before = NativeTextViewCoordinator.blockBoundary(near: index, after: false, in: text)
        let after = NativeTextViewCoordinator.blockBoundary(near: index, after: true, in: text)
        guard let top = lineTop(of: before), let next = lineTop(of: after) else { return before }
        return abs(point.y - top) <= abs(point.y - next) ? before : after
    }

    /// The top of the line at `location` (the bottom of the text at its end), in view coordinates.
    private func lineTop(of location: Int) -> CGFloat? {
        let length = (string as NSString).length
        let atEnd = location >= length
        let range = NSRange(location: atEnd ? max(0, length - 1) : location, length: length > 0 ? 1 : 0)
        guard let window else { return nil }
        let screen = firstRect(forCharacterRange: range, actualRange: nil)
        guard !screen.isNull, screen.origin.y.isFinite else { return nil }
        let rect = convert(window.convertFromScreen(screen), from: nil)
        return atEnd ? rect.maxY + 4 : rect.minY
    }

    private static let dropIndicatorIdentifier = NSUserInterfaceItemIdentifier("PageFlowTableDropIndicator")

    func showTableDropIndicator(at boundary: Int) {
        guard let y = lineTop(of: boundary) else { return }
        let indicator = subviews.first { $0.identifier == Self.dropIndicatorIdentifier } ?? {
            let view = NSView()
            view.identifier = Self.dropIndicatorIdentifier
            view.wantsLayer = true
            view.layer?.cornerRadius = 2
            view.layer?.backgroundColor = ChromePalette.accent.withAlphaComponent(0.5).cgColor
            addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }()
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let width = (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0)
        indicator.frame = NSRect(x: x, y: y - 2, width: max(40, width), height: 4)
        indicator.isHidden = false
    }

    func hideTableDropIndicator() {
        subviews.first { $0.identifier == Self.dropIndicatorIdentifier }?.removeFromSuperview()
    }
}
