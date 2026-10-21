import AppKit

/// Cached destination feedback, independent of the editor that began the drag.
final class BlockDragSession {
    let sequence: Int
    let payload: BlockMovePasteboard
    var slots: [(offset: Int, y: CGFloat)] = []
    var viewport = NSRect.null
    var generation = -1
    var validatedGeneration = -1
    var opaqueRanges: [NSRange]?
    var copying = false
    var target: Int?
    let indicator = BlockDropIndicatorView(style: .blockMove)
    init(sequence: Int, payload: BlockMovePasteboard) {
        self.sequence = sequence
        self.payload = payload
    }
}

extension NativeTextView {
    func isTableMove(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [BlockMovePasteboard.moveType]) != nil
    }

    func tableMoveUpdated(_ sender: NSDraggingInfo, at point: NSPoint) -> NSDragOperation {
        guard isEditable, let coordinator = delegate as? NativeTextViewCoordinator else { return [] }
        let mover = coordinator.blockMover
        let session: BlockDragSession
        if let cached = mover.dropSession, cached.sequence == sender.draggingSequenceNumber { session = cached }
        else {
            hideTableDropIndicator()
            guard let payload = BlockMovePasteboard.read(from: sender.draggingPasteboard) else { return [] }
            session = BlockDragSession(sequence: sender.draggingSequenceNumber, payload: payload)
            mover.dropSession = session
        }
        let local = session.payload.isLocal(document: coordinator.documentId, editor: coordinator.blockEditorID)
        if local && session.validatedGeneration != coordinator.nativeSourceGeneration {
            guard session.payload.matches(string as NSString) else { hideTableDropIndicator(); return [] }
            session.validatedGeneration = coordinator.nativeSourceGeneration
        }
        let copying = !local || NSEvent.modifierFlags.contains(.option)
        autoscrollForDrag(at: point)
        if session.viewport != visibleRect || session.generation != coordinator.nativeSourceGeneration || session.copying != copying {
            if session.opaqueRanges == nil || session.generation != coordinator.nativeSourceGeneration {
                session.opaqueRanges = dropOpaqueRanges()
            }
            session.slots = dropSlotsNearViewport(opaque: session.opaqueRanges)
            session.viewport = visibleRect
            session.generation = coordinator.nativeSourceGeneration
            session.copying = copying
        }
        guard let slot = session.slots.min(by: { abs($0.y - point.y) < abs($1.y - point.y) }) else {
            session.indicator.removeFromSuperview(); session.target = nil; return []
        }
        if !copying {
            let removed = NativeTextViewCoordinator.blockRemovalRange(session.payload.range, in: string as NSString)
            if slot.offset >= removed.location && slot.offset <= NSMaxRange(removed) {
                session.indicator.removeFromSuperview()
                session.target = nil
                return []
            }
        }
        if session.indicator.superview !== self { addSubview(session.indicator, positioned: .above, relativeTo: nil) }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let width = (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0)
        session.indicator.place(columnMinX: x, width: width, centerY: slot.y, animated: session.target != nil && session.target != slot.offset)
        session.target = slot.offset
        return copying ? .copy : .move
    }

    func performTableMove(_ sender: NSDraggingInfo, at point: NSPoint) -> Bool {
        _ = tableMoveUpdated(sender, at: point)
        guard let coordinator = delegate as? NativeTextViewCoordinator, let session = coordinator.blockMover.dropSession,
              let target = session.target else { hideTableDropIndicator(); return false }
        let payload = session.payload
        let copying = session.copying
        hideTableDropIndicator()
        return coordinator.moveBlock(payload, to: target, copying: copying)
    }

    func hideTableDropIndicator() {
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return }
        coordinator.blockMover.dropSession?.indicator.removeFromSuperview()
        coordinator.blockMover.dropSession = nil
    }
}
