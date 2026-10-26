import AppKit

/// the reference editor's comment rail (doc 25 §4.1): a 320 wide lane at the editor's
/// right, inside the document so cards scroll 1:1 with the text. Cards sit
/// 36 from its left and 24 from its right (260 wide). Only cards take the
/// mouse; the lane between them is the document's.
final class CommentRailView: NSView {
    static let width: CGFloat = 320
    static let cardInset: CGFloat = 36
    /// The text column keeps at least this far from the editor's right edge.
    static let keepout: CGFloat = 340
    /// A wide table stops this far from it (`--rail-keepout`), unless freed.
    static let tableKeepout: CGFloat = 308

    private(set) var cards: [String: CommentCardView] = [:]
    /// The draft composer, while it sits in the rail.
    var composer: CommentComposerView? {
        didSet {
            if oldValue !== composer { oldValue?.removeFromSuperview() }
            if let composer, composer.superview !== self { addSubview(composer) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Comments")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func card(for thread: MarkdownCommentThread, delegate: CommentCardDelegate) -> CommentCardView {
        if let card = cards[thread.id] {
            card.update(thread)
            return card
        }
        let card = CommentCardView(thread: thread)
        card.delegate = delegate
        addSubview(card)
        cards[thread.id] = card
        return card
    }

    /// Removes the cards of threads not in `ids`.
    func keepCards(_ ids: Set<String>) {
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
    }

    func removeCard(_ id: String) {
        cards[id]?.removeFromSuperview()
        cards[id] = nil
    }

    /// Places `view` at `top`, sliding 180 ms when `animated` (a pivot change).
    func place(_ view: NSView, top: CGFloat, height: CGFloat, animated: Bool) {
        let frame = NSRect(x: Self.cardInset, y: top, width: CommentCardView.width, height: height)
        guard view.frame != frame else { return }
        if animated, view.frame.width > 0, !CommentPalette.reducesMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CommentPalette.easeOut
                view.animator().frame = frame
            }
        } else {
            view.frame = frame
        }
    }
}

/// Tracks the pointer over the editor for highlight hover (doc 25 §3.3).
final class CommentHoverTracker: NSResponder {
    var onMove: ((NSEvent) -> Void)?
    var onExit: (() -> Void)?
    override func mouseMoved(with event: NSEvent) { onMove?(event) }
    override func mouseEntered(with event: NSEvent) { onMove?(event) }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
