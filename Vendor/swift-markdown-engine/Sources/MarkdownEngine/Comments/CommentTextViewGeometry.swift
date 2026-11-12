import AppKit

@MainActor
private final class CommentGeometryState: NSObject {
    static let states = NSMapTable<NSTextView, CommentGeometryState>.weakToStrongObjects()
    var lane: CGFloat = 0
    var overhang: CGFloat = 0
    var keepout: CGFloat = 0
    var freed: Set<Int> = []
}

@MainActor
extension NSTextView {
    private var commentGeometry: CommentGeometryState {
        if let state = CommentGeometryState.states.object(forKey: self) { return state }
        let state = CommentGeometryState()
        CommentGeometryState.states.setObject(state, forKey: self)
        return state
    }
    var comments_commentLaneReserve: CGFloat {
        get { (self as? NativeTextView)?.commentLaneReserve ?? commentGeometry.lane }
        set {
            if let legacy = self as? NativeTextView { legacy.commentLaneReserve = newValue }
            else if let semantic = self as? NativeSemanticTextView {
                guard abs(commentGeometry.lane - newValue) > 0.5 else { return }
                semantic.preservingSemanticViewport(requireEdit: false, revealCaret: false) {
                    commentGeometry.lane = newValue
                    semantic.updateSemanticGeometry()
                    semantic.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    semantic.refreshSemanticTables()
                }
                semantic.semanticCoordinator?.onLayoutChange?()
            } else {
                commentGeometry.lane = newValue
                textContainer?.widthTracksTextView = newValue == 0
                textContainer?.containerSize.width = max(80, bounds.width - textContainerInset.width * 2 - newValue)
            }
        }
    }
    var comments_commentOverhang: CGFloat {
        get { (self as? NativeTextView)?.commentOverhang ?? commentGeometry.overhang }
        set { if let legacy = self as? NativeTextView { legacy.commentOverhang = newValue } else { commentGeometry.overhang = newValue } }
    }
    var comments_commentTableKeepout: CGFloat {
        get { (self as? NativeTextView)?.commentTableKeepout ?? commentGeometry.keepout }
        set { if let legacy = self as? NativeTextView { legacy.commentTableKeepout = newValue } else { commentGeometry.keepout = newValue } }
    }
    var comments_tablesFreedIntoCommentLane: Set<Int> {
        get { (self as? NativeTextView)?.tablesFreedIntoCommentLane ?? commentGeometry.freed }
        set { if let legacy = self as? NativeTextView { legacy.tablesFreedIntoCommentLane = newValue } else { commentGeometry.freed = newValue } }
    }
    var comments_wideTableOverlays: [Int: WideTableOverlay] { (self as? NativeTextView)?.wideTableOverlays ?? [:] }
    var comments_viewportCharacterRange: NSRange? {
        if let legacy = self as? NativeTextView { return legacy.viewportCharacterRange }
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let range = manager.textViewportLayoutController.viewportRange else { return nil }
        return NSRange(location: content.offset(from: content.documentRange.location, to: range.location),
                       length: content.offset(from: range.location, to: range.endLocation))
    }
    func comments_tableCanvas(forTableAt range: NSRange) -> (view: NSView, origin: NSPoint)? {
        (self as? NativeTextView)?.tableCanvas(forTableAt: range)
    }
    func comments_convertTableRect(_ rect: NSRect, canvas: (view: NSView, origin: NSPoint)) -> NSRect {
        convert(rect.offsetBy(dx: canvas.origin.x, dy: canvas.origin.y), from: canvas.view)
    }
    func comments_renderedImageRect(at anchor: Int) -> NSRect? {
        if let legacy = self as? NativeTextView { return legacy.renderedImageRect(at: anchor) }
        return comments_lineFrame(at: anchor)
    }
    func comments_lineFrame(at offset: Int) -> NSRect? {
        if let legacy = self as? NativeTextView { return legacy.lineFrame(at: offset) }
        guard let manager = textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        manager.ensureLayout(for: NSTextRange(location: start))
        return manager.textLayoutFragment(for: start)?.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
}

extension MarkdownCommentsController {
    func performCommentNavigation(_ action: @escaping () -> Void) {
        if let coordinator { coordinator.performNavigationWhenInputSettles(action) }
        else if semanticOwner?.textView.hasMarkedText() == false { action() }
    }
}
