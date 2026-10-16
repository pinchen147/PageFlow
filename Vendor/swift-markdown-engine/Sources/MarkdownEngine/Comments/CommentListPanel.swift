import AppKit

/// the reference editor's comments list (doc 25 §5.6): a 320 wide panel at the
/// editor's right with a 48 tall header — "Comments", the count, Filter
/// (Open / Resolved / All), More (Hide comments), Close — and the threads as
/// ruled rows with their quotes: open ones first, then document order.
/// Detached threads say "was on:". Under All, resolved threads fold into
/// "Resolved (N)". Narrow editors get it as a 308 wide popover.
final class CommentListPanel: NSView {
    static let width: CGFloat = 320
    static let widthRange: ClosedRange<CGFloat> = 240...600
    static let popoverWidth: CGFloat = 308
    private static let widthKey = "MarkdownEngine.commentListWidth"

    /// The docked width the user left it at (the reference editor keeps it per browser).
    static var savedWidth: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: widthKey)
            return stored > 0 ? min(widthRange.upperBound, max(widthRange.lowerBound, stored)) : width
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: widthKey) }
    }

    /// the reference editor's 6 pt "Resize comments" handle on the panel's left edge.
    let resizeHandle = CommentResizeHandle()
    static let headerHeight: CGFloat = 48

    struct Row {
        var thread: MarkdownCommentThread
        var quote: String
        var detached: Bool
    }

    let title = NSTextField(labelWithString: "Comments")
    let count = NSTextField(labelWithString: "")
    let filterButton = CommentButton(symbol: "line.3.horizontal.decrease", tooltip: "Filter")
    let moreButton = CommentButton(symbol: "ellipsis", tooltip: "More")
    let closeButton = CommentButton(symbol: "xmark", tooltip: "Close comments")
    let scrollView = NSScrollView()
    private let content = FlippedView()
    private let rule = NSView()
    private(set) var cards: [String: CommentCardView] = [:]
    private var resolvedFold: CommentTextButton?
    private var emptyLabel: NSTextField?
    var showsResolvedFold = false
    /// A popover (narrow editors) rather than a docked panel.
    var isPopover = false { didSet { needsDisplay = true; layer?.cornerRadius = isPopover ? 10 : 0 } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Comments")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = CommentPalette.text
        count.font = NSFont.systemFont(ofSize: 13)
        count.textColor = CommentPalette.mutedText
        for view in [title, count, filterButton, moreButton, closeButton, rule] as [NSView] { addSubview(view) }
        rule.wantsLayer = true
        scrollView.documentView = content
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (isPopover ? CommentPalette.popover : CommentPalette.card).cgColor
            layer.borderColor = CommentPalette.alpha2.cgColor
            rule.layer?.backgroundColor = CommentPalette.alpha2.cgColor
        }
        layer.borderWidth = isPopover ? 1 : 0
        if isPopover { ChromePalette.applyBarShadow(to: layer, dark: CommentPalette.isDark(effectiveAppearance)) } else {
            layer.shadowOpacity = 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isPopover else { return }
        // The docked panel's left rule.
        CommentPalette.alpha2.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()
        let header = Self.headerHeight
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(x: 16, y: (header - titleSize.height) / 2, width: titleSize.width, height: titleSize.height)
        let countSize = count.intrinsicContentSize
        count.frame = NSRect(x: title.frame.maxX + 6, y: title.frame.minY, width: countSize.width, height: countSize.height)
        var x = bounds.width - 12
        for button in [closeButton, moreButton, filterButton] {
            x -= 24
            button.frame = NSRect(x: x, y: (header - 24) / 2, width: 24, height: 24)
            x -= 4
        }
        rule.frame = NSRect(x: 0, y: header - 1, width: bounds.width, height: 1)
        resizeHandle.isHidden = isPopover
        resizeHandle.frame = NSRect(x: 0, y: 0, width: 6, height: bounds.height)
        scrollView.frame = NSRect(x: 0, y: header, width: bounds.width, height: max(0, bounds.height - header))
        layoutRows()
    }

    /// Shows `rows` (already filtered and ordered); `folded` resolved rows
    /// collapse behind "Resolved (N)" until it is pressed.
    func show(_ rows: [Row], resolvedFolded: [Row], foldOpen: Bool, focusID: String?, delegate: CommentCardDelegate,
              emptyText: String?) {
        let wanted = rows + (foldOpen ? resolvedFolded : [])
        let ids = Set(wanted.map(\.thread.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        orderedIDs = wanted.map(\.thread.id)
        resolvedSplit = rows.count
        for row in wanted {
            let card = cards[row.thread.id] ?? {
                let made = CommentCardView(thread: row.thread)
                made.delegate = delegate
                made.isFlat = true
                content.addSubview(made)
                cards[row.thread.id] = made
                return made
            }()
            card.update(row.thread)
            if card.quote?.text != row.quote || card.quote?.detached != row.detached {
                card.quote = (row.quote, row.detached)
            }
            card.isExpanded = focusID == row.thread.id
        }
        resolvedFold?.removeFromSuperview()
        resolvedFold = nil
        if !resolvedFolded.isEmpty {
            let fold = CommentTextButton("\(foldOpen ? "\u{25BE}" : "\u{25B8}") Resolved (\(resolvedFolded.count))", style: .link)
            fold.onPress = { [weak self] in self?.onToggleFold?() }
            content.addSubview(fold)
            resolvedFold = fold
        }
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
        if let emptyText, wanted.isEmpty, resolvedFolded.isEmpty {
            let label = NSTextField(labelWithString: emptyText)
            label.font = CommentPalette.footnote
            label.textColor = CommentPalette.mutedText
            label.alignment = .center
            content.addSubview(label)
            emptyLabel = label
        }
        needsLayout = true
    }

    var onToggleFold: (() -> Void)?
    private var orderedIDs: [String] = []
    private var resolvedSplit = 0

    private func layoutRows() {
        let width = scrollView.contentSize.width
        var y: CGFloat = 0
        for (index, id) in orderedIDs.enumerated() {
            if index == resolvedSplit, let fold = resolvedFold {
                fold.frame = NSRect(x: 16, y: y + 12, width: fold.intrinsicContentSize.width, height: 17)
                y += 41
            }
            guard let card = cards[id] else { continue }
            card.frame.size.width = width
            let height = card.fittingHeight()
            card.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        if orderedIDs.count == resolvedSplit, let fold = resolvedFold {
            fold.frame = NSRect(x: 16, y: y + 12, width: fold.intrinsicContentSize.width, height: 17)
            y += 41
        }
        if let emptyLabel {
            emptyLabel.frame = NSRect(x: 0, y: 24, width: width, height: 17)
            y = 65
        }
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scrollView.contentSize.height))
    }

    /// A flipped document view for the rows.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// Drags the docked list wider or narrower (240–600); double-click resets
/// it to 320; ← and → step it from the keyboard.
final class CommentResizeHandle: NSView {
    /// The width the drag asks for; `done` when the drag ends.
    var onResize: ((CGFloat, _ done: Bool) -> Void)?
    var currentWidth: (() -> CGFloat)?
    private var start: (x: CGFloat, width: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize comments")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onResize?(CommentListPanel.width, true)
            return
        }
        start = (event.locationInWindow.x, currentWidth?() ?? CommentListPanel.width)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        // The panel is on the right: dragging left widens it.
        onResize?(clamp(start.width + start.x - event.locationInWindow.x), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        onResize?(clamp(start.width + start.x - event.locationInWindow.x), true)
        self.start = nil
    }

    override func keyDown(with event: NSEvent) {
        let width = currentWidth?() ?? CommentListPanel.width
        switch event.keyCode {
        case 123: onResize?(clamp(width + 16), true)
        case 124: onResize?(clamp(width - 16), true)
        default: super.keyDown(with: event)
        }
    }

    private func clamp(_ width: CGFloat) -> CGFloat {
        min(CommentListPanel.widthRange.upperBound, max(CommentListPanel.widthRange.lowerBound, width))
    }
}
