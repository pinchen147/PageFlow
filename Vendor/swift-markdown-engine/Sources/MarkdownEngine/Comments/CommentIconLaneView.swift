import AppKit

/// the reference editor's narrow layout (doc 25 §4.6): a 64 wide lane at the editor's
/// right with one 26 tall chip per cluster of threads (anchors less than 32
/// apart share one): a chat icon and the count of threads and replies.
/// Hovering a chip lights the cluster's highlights; clicking it peeks.
final class CommentIconLaneView: NSView {
    static let width: CGFloat = 64
    /// The text keeps this far from the right edge (64 + 24).
    static let keepout: CGFloat = 88
    static let clusterJoin: CGFloat = 32

    struct Cluster: Equatable {
        var ids: [String]
        var top: CGFloat
        var count: Int
    }

    private(set) var chips: [CommentIconChip] = []
    var onHover: ((Cluster?) -> Void)?
    var onOpen: ((Cluster) -> Void)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Groups anchors (sorted by top) into clusters 32 apart.
    static func clusters(_ anchors: [(id: String, top: CGFloat, count: Int)]) -> [Cluster] {
        var result: [Cluster] = []
        for anchor in anchors.sorted(by: { $0.top < $1.top }) {
            if var last = result.last, anchor.top - last.top < clusterJoin {
                last.ids.append(anchor.id)
                last.count += anchor.count
                result[result.count - 1] = last
            } else {
                result.append(Cluster(ids: [anchor.id], top: anchor.top, count: anchor.count))
            }
        }
        return result
    }

    func show(_ clusters: [Cluster]) {
        while chips.count > clusters.count { chips.removeLast().removeFromSuperview() }
        while chips.count < clusters.count {
            let chip = CommentIconChip()
            chip.onHover = { [weak self, weak chip] inside in self?.onHover?(inside ? chip?.cluster : nil) }
            chip.onPress = { [weak self, weak chip] in
                guard let cluster = chip?.cluster else { return }
                self?.onOpen?(cluster)
            }
            addSubview(chip)
            chips.append(chip)
        }
        for (chip, cluster) in zip(chips, clusters) {
            chip.cluster = cluster
            let size = chip.intrinsicContentSize
            chip.frame = NSRect(x: (Self.width - size.width) / 2, y: cluster.top, width: size.width, height: size.height)
        }
    }
}

/// One chip in the icon lane: 26 tall, a 14 pt chat icon and the count.
final class CommentIconChip: NSView {
    var cluster: CommentIconLaneView.Cluster? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
            let count = cluster?.ids.count ?? 0
            toolTip = count == 1 ? "1 comment" : "\(count) comments"
            setAccessibilityLabel(toolTip)
        }
    }
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    override var intrinsicContentSize: NSSize {
        let label = "\(cluster?.count ?? 0)" as NSString
        return NSSize(width: ceil(8 + 14 + 4 + label.size(withAttributes: [.font: Self.font]).width + 8), height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        (isHovered ? CommentPalette.popover : CommentPalette.card).setFill()
        pill.fill()
        CommentPalette.alpha2.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        if isHovered {
            CommentPalette.alpha1.setFill()
            pill.fill()
        }
        SelectionBarButton.drawSymbol("bubble.left", size: 14, in: NSRect(x: 8, y: 6, width: 14, height: 14),
                                      color: CommentPalette.secondaryText)
        let label = "\(cluster?.count ?? 0)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: CommentPalette.secondaryText]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: 8 + 14 + 4, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        trackActionCursor()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isHovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// the reference editor's peek (doc 25 §4.6): the cluster's cards floating over the
/// text, at most 340 wide, 8 apart.
final class CommentPeekView: NSView {
    static let maximumWidth: CGFloat = 340
    private(set) var cards: [CommentCardView] = []
    let ids: [String]

    init(ids: [String]) {
        self.ids = ids
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func show(_ threads: [MarkdownCommentThread], focusID: String?, delegate: CommentCardDelegate, width: CGFloat) {
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.threadID, $0) })
        cards.forEach { $0.removeFromSuperview() }
        cards = threads.map { thread in
            let card = byID[thread.id] ?? CommentCardView(thread: thread)
            card.delegate = delegate
            card.update(thread)
            card.isExpanded = focusID == thread.id
            card.isLit = true
            addSubview(card)
            return card
        }
        var y: CGFloat = 0
        for card in cards {
            card.frame.size.width = width
            let height = card.fittingHeight()
            card.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 8
        }
        setFrameSize(NSSize(width: width, height: max(0, y - 8)))
    }
}
