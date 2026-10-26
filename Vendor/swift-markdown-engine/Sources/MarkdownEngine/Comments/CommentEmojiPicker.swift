import AppKit

/// the reference editor's reaction picker (doc 25 §6.2–§6.3): the eight emoji as 16 pt
/// ghost buttons, 4 apart with 4 padding, each "React with ‹emoji›". From
/// the keyboard the first emoji has focus and the arrows move; Escape closes.
final class CommentEmojiPicker: NSView {
    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?
    private var buttons: [EmojiButton] = []
    private var focused: Int?
    /// A card's popover, or the strip that replaces the selection bar.
    let isPopover: Bool
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?

    /// Each emoji's button; the strip is the selection bar's 34 tall.
    static let side: CGFloat = 24

    init(popover: Bool) {
        isPopover = popover
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("React with an emoji")
        for emoji in CommentReactions.emoji {
            let button = EmojiButton(emoji: emoji)
            button.onPress = { [weak self] in self?.onPick?(emoji) }
            addSubview(button)
            buttons.append(button)
        }
        let size = intrinsicContentSize
        setFrameSize(size)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 5 + CGFloat(index) * (Self.side + 4), y: 5, width: Self.side, height: Self.side)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        monitors.forEach(NSEvent.removeMonitor)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        // A 1 pt border and 4 padding around 24 pt buttons 4 apart.
        NSSize(width: 10 + CGFloat(buttons.count) * Self.side + CGFloat(buttons.count - 1) * 4, height: Self.side + 10)
    }
    override var acceptsFirstResponder: Bool { focused != nil }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 10
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (isPopover ? CommentPalette.popover : ChromePalette.surface).cgColor
            layer.borderColor = (isPopover ? CommentPalette.alpha2 : ChromePalette.border).cgColor
        }
        layer.borderWidth = 1
        ChromePalette.applyBarShadow(to: layer, dark: CommentPalette.isDark(effectiveAppearance))
    }

    /// Opened from the keyboard: the first emoji takes focus.
    func beginKeyboardFocus() {
        focused = 0
        refreshFocus()
        window?.makeFirstResponder(self)
    }

    private func refreshFocus() {
        for (index, button) in buttons.enumerated() { button.hasFocus = index == focused }
    }

    override func keyDown(with event: NSEvent) {
        let current = focused ?? 0
        switch event.keyCode {
        case 123: focused = max(0, current - 1)
        case 124: focused = min(buttons.count - 1, current + 1)
        case 115: focused = 0
        case 119: focused = buttons.count - 1
        case 36, 76, 49: onPick?(CommentReactions.emoji[current]); return
        case 53: onClose?(); return
        default: return
        }
        refreshFocus()
    }

    /// A popover closes on a click outside it or when the window resigns.
    func closesOnOutsideClick() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.window != nil else { return event }
            if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.onClose?()
            }
            return event
        } as Any)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSWindow) === self.window else { return }
                self.onClose?()
            }
        }
    }

    override func removeFromSuperview() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        super.removeFromSuperview()
    }

    /// One emoji: 16 pt, a hover fill.
    final class EmojiButton: NSView {
        let emoji: String
        var onPress: (() -> Void)?
        var hasFocus = false { didSet { needsDisplay = true } }
        private var isHovered = false { didSet { needsDisplay = true } }

        init(emoji: String) {
            self.emoji = emoji
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("React with \(emoji)")
            toolTip = "React with \(emoji)"
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if isHovered || hasFocus {
                CommentPalette.alpha1.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            if hasFocus {
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                ring.lineWidth = 2
                CommentPalette.accent.setStroke()
                ring.stroke()
            }
            let font = NSFont.systemFont(ofSize: 16)
            let size = (emoji as NSString).size(withAttributes: [.font: font])
            (emoji as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                     withAttributes: [.font: font])
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

        override func mouseEntered(with event: NSEvent) { isHovered = true }
        override func mouseExited(with event: NSEvent) { isHovered = false }
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
}
