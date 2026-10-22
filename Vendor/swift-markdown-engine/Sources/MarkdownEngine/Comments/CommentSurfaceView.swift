import AppKit

/// the reference editor's card surface (doc 25 §4.2, §8.3): radius 10, `surface-2`, a
/// 1 pt ring, and the rest shadow (0 1 2 ink 6 %, 0 2 8 ink 8 %) or, lit,
/// the panel shadow (0 8 24 black 12 %, 0 2 6 black 8 %), switched in 60 ms.
class CommentSurfaceView: NSView {
    var isRaised = false { didSet { if isRaised != oldValue { applyShadow(animated: true); if isFlat { needsDisplay = true } } } }
    /// the reference editor's focus ring: 1 pt accent, a 6 pt glow beyond it.
    var showsFocusRing = false {
        didSet {
            guard showsFocusRing != oldValue else { return }
            focusRing.isHidden = !showsFocusRing
        }
    }
    private let focusRing = CALayer()

    /// A list row: no card chrome, a rule underneath (the reference editor's `divide-y`).
    var isFlat = false { didSet { if isFlat != oldValue { needsDisplay = true; applyShadow(animated: false) } } }
    var fill: NSColor = CommentPalette.card { didSet { needsDisplay = true } }
    /// The second shadow, on a layer behind the card.
    private let underShadow = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        underShadow.cornerRadius = 10
        layer?.insertSublayer(underShadow, at: 0)
        bottomRule.isHidden = true
        layer?.addSublayer(bottomRule)
        focusRing.isHidden = true
        focusRing.borderWidth = 1
        focusRing.borderColor = CommentPalette.accent.cgColor
        focusRing.shadowColor = CommentPalette.focusGlow.cgColor
        focusRing.shadowOpacity = 1
        focusRing.shadowRadius = 3
        focusRing.shadowOffset = .zero
        layer?.addSublayer(focusRing)
        applyShadow(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = isFlat ? (isRaised ? CommentPalette.alpha1.cgColor : .clear) : fill.cgColor
            underShadow.backgroundColor = isFlat ? .clear : fill.cgColor
            layer.borderColor = CommentPalette.alpha2.cgColor
            bottomRule.backgroundColor = CommentPalette.alpha2.cgColor
        }
        layer.cornerRadius = isFlat ? 0 : 10
        layer.borderWidth = isFlat ? 0 : 1
        bottomRule.isHidden = !isFlat
        applyShadow(animated: false)
    }

    private let bottomRule = CALayer()

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underShadow.frame = bounds
        bottomRule.frame = NSRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1)
        focusRing.frame = bounds.insetBy(dx: -1, dy: -1)
        focusRing.cornerRadius = isFlat ? 0 : 11
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        underShadow.shadowPath = layer?.shadowPath
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func applyShadow(animated: Bool) {
        guard let layer else { return }
        let dark = CommentPalette.isDark(effectiveAppearance)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.06 : 0)
        CATransaction.setDisableActions(!animated)
        layer.shadowColor = NSColor.black.cgColor
        underShadow.shadowColor = NSColor.black.cgColor
        if isFlat {
            layer.shadowOpacity = 0
            underShadow.shadowOpacity = 0
            CATransaction.commit()
            return
        }
        // y is up in a layer: a shadow that falls down has a negative offset.
        if isRaised {
            layer.shadowOpacity = dark ? 0.32 : 0.12
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: -8)
            underShadow.shadowOpacity = dark ? 0.2 : 0.08
            underShadow.shadowRadius = 3
            underShadow.shadowOffset = CGSize(width: 0, height: -2)
        } else {
            layer.shadowOpacity = dark ? 0.24 : 0.06
            layer.shadowRadius = 1
            layer.shadowOffset = CGSize(width: 0, height: -1)
            underShadow.shadowOpacity = dark ? 0.24 : 0.08
            underShadow.shadowRadius = 4
            underShadow.shadowOffset = CGSize(width: 0, height: -2)
        }
        CATransaction.commit()
    }
}

/// A ghost icon button on a comment card or composer (doc 25 §5.1): a
/// rounded 6 hover fill, an SF Symbol, a tooltip, α .4 when disabled.
final class CommentButton: NSView {
    var symbol: String { didSet { needsDisplay = true } }
    var side: CGFloat
    var iconSize: CGFloat
    var tooltip: String { didSet { setAccessibilityLabel(tooltip) } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var tint: NSColor?
    var onPress: (() -> Void)?
    /// Shows and hides the shared tooltip.
    var onHover: ((CommentButton, Bool) -> Void)?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    init(symbol: String, tooltip: String, side: CGFloat = 24, iconSize: CGFloat = 16) {
        self.symbol = symbol
        self.tooltip = tooltip
        self.side = side
        self.iconSize = iconSize
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered {
            CommentPalette.alpha1.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let ink = (tint ?? CommentPalette.secondaryText).withAlphaComponent(isEnabled ? 1 : 0.4)
        SelectionBarButton.drawSymbol(symbol, size: iconSize, in: NSRect(x: (bounds.width - iconSize) / 2,
                                                                          y: (bounds.height - iconSize) / 2,
                                                                          width: iconSize, height: iconSize), color: ink)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        trackActionCursor()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func cursorUpdate(with event: NSEvent) { (isEnabled ? NSCursor.pointingHand : .arrow).set() }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(self, false)
    }

    /// Mouse-down never takes focus from the field (the reference editor's preventDefault).
    override func mouseDown(with event: NSEvent) {
        onHover?(self, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }
}
