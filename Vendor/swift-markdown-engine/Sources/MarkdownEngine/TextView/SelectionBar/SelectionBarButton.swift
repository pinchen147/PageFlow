import AppKit

/// One control in the selection bar (doc 24 §6.13): 24 tall, radius 6, a 16 pt
/// symbol, hover and pressed fills, α .4 when disabled. It never takes the
/// keyboard or changes the selection; a click acts on mouse-up over the same
/// button, and a dropdown trigger opens on mouse-down.
final class SelectionBarButton: NSView {
    enum Content: Equatable {
        case symbol(String)
        case text(String)
    }

    var content: Content { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let hasCaret: Bool
    let opensOnMouseDown: Bool
    /// The List trigger's tighter padding (0 3 0 5, gap 1) rather than Text style's (0 4 0 8, gap 3).
    var compactTrigger = false
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var isMenuOpen = false { didSet { if isMenuOpen != oldValue { needsDisplay = true } } }
    /// Drawn with the reference editor's keyboard focus ring (F6 into the bar).
    var hasKeyboardFocus = false { didSet { if hasKeyboardFocus != oldValue { needsDisplay = true } } }
    var tooltip: String
    var onPress: ((SelectionBarButton) -> Void)?
    var onHover: ((SelectionBarButton, Bool) -> Void)?
    /// A value that must be unchanged between mouse-down and mouse-up (the selection).
    var snapshot: (() -> AnyHashable)?

    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var downSnapshot: AnyHashable?
    private var lastPress: TimeInterval = 0

    init(content: Content, tooltip: String, hasCaret: Bool = false, opensOnMouseDown: Bool = false) {
        self.content = content
        self.tooltip = tooltip
        self.hasCaret = hasCaret
        self.opensOnMouseDown = opensOnMouseDown
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(hasCaret ? .menuButton : .button)
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// the reference editor's widths: a plain button is 24; Text style is padding 0 4 0 8
    /// with a 3 gap and a 12 caret; List is padding 0 3 0 5 with a 1 gap.
    override var intrinsicContentSize: NSSize {
        guard hasCaret else { return NSSize(width: 24, height: 24) }
        switch content {
        case .text(let label):
            let width = (label as NSString).size(withAttributes: [.font: Self.labelFont]).width
            return NSSize(width: ceil(8 + width + 3 + 12 + 4), height: 24)
        case .symbol:
            return compactTrigger ? NSSize(width: 5 + 16 + 1 + 12 + 3, height: 24) : NSSize(width: 8 + 16 + 3 + 12 + 4, height: 24)
        }
    }

    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        if isEnabled, isPressed {
            ChromePalette.pressedFill.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        } else if isEnabled, isHovered || isMenuOpen {
            ChromePalette.hover.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
        let ink = (isPressed ? ChromePalette.pressedIcon : ChromePalette.text).withAlphaComponent(isEnabled ? 1 : 0.4)
        var x: CGFloat
        switch content {
        case .symbol(let name):
            x = hasCaret ? (compactTrigger ? 5 : 8) : 4
            Self.drawSymbol(name, size: 16, in: NSRect(x: x, y: 4, width: 16, height: 16), color: ink)
            x += 16 + (compactTrigger ? 1 : 3)
        case .text(let label):
            x = 8
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: ink]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: x, y: (box.height - size.height) / 2), withAttributes: attributes)
            x += size.width + 3
        }
        if hasCaret {
            Self.drawSymbol("chevron.down", size: 12, in: NSRect(x: x, y: 6, width: 12, height: 12),
                            color: ink.withAlphaComponent(ink.alphaComponent * 0.6))
        }
        if hasKeyboardFocus {
            // the reference editor's ring: 1 pt accent outside, a soft glow beyond it.
            let ring = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ChromePalette.accent.setStroke()
            ring.stroke()
        }
    }

    static func drawSymbol(_ name: String, size: CGFloat, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.82, weight: .regular)
            .applying(.preferringMonochrome())
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let fitted = image.size
        let scale = min(rect.width / max(1, fitted.width), rect.height / max(1, fitted.height), 1)
        let drawn = NSSize(width: fitted.width * scale, height: fitted.height * scale)
        // The monochrome glyph, tinted. A one-colour palette also filled a
        // symbol's background layer, so face.smiling drew as a solid disc.
        let tinted = NSImage(size: drawn, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                               width: drawn.width, height: drawn.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .arrow : .operationNotAllowed)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(self, false)
    }

    override func mouseDown(with event: NSEvent) {
        onHover?(self, false)
        guard isEnabled else { return }
        if opensOnMouseDown {
            fire()
            return
        }
        downSnapshot = snapshot?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, !opensOnMouseDown, let down = downSnapshot else { return }
        downSnapshot = nil
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), snapshot?() == down else { return }
        fire()
    }

    private func fire() {
        // the reference editor ignores a repeat within 150 ms.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPress > 0.15 else { return }
        lastPress = now
        onPress?(self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?(self)
        return true
    }
}

/// The 1 × 18 rule between groups of controls, with 2 pt margins.
final class SelectionBarSeparator: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 5, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        ChromePalette.border.setFill()
        NSRect(x: 2, y: (bounds.height - 18) / 2, width: 1, height: 18).fill()
    }
}
