import AppKit

/// The line that shows where a drop lands (doc 26 §9.3, §10.4): a horizontal
/// bar across the text column in the primary label colour (black in light
/// mode, white in dark), centred in the gap between two blocks. A file drop
/// draws it 2 pt tall; a block move 4 pt. It slides between slots in 120 ms
/// unless Reduce Motion is on, and can carry a 12 pt spinner while a slow
/// import finishes (I3).
final class BlockDropIndicatorView: NSView {
    enum Style {
        case fileDrop
        case blockMove

        var thickness: CGFloat { self == .fileDrop ? 2 : 4 }
    }

    static let slideDuration: TimeInterval = 0.12
    static let spinnerSize: CGFloat = 12

    let style: Style
    private var spinner: NSProgressIndicator?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = style.thickness / 2
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    /// The bar's colour: the primary label colour made opaque (I10), resolved
    /// for the light or dark appearance it sits in.
    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(1).cgColor
        }
    }

    /// Puts the bar across `column` (view x range of the text column), centred on `y`.
    func place(columnMinX: CGFloat, width: CGFloat, centerY: CGFloat, animated: Bool) {
        let frame = NSRect(x: columnMinX, y: (centerY - style.thickness / 2).rounded(),
                           width: max(40, width), height: style.thickness)
        guard frame != self.frame || isHidden else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !isHidden, !reduceMotion, self.frame.width > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.slideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().frame = frame
            }
        } else {
            self.frame = frame
        }
        isHidden = false
        applyColor()
        layoutSpinner()
    }

    /// Shows or hides the 12 pt spinner in the middle of the bar.
    var showsSpinner: Bool {
        get { spinner != nil }
        set {
            guard newValue != showsSpinner else { return }
            if newValue {
                let indicator = NSProgressIndicator()
                indicator.style = .spinning
                indicator.controlSize = .mini
                indicator.isDisplayedWhenStopped = false
                indicator.setAccessibilityLabel("Adding images")
                addSubview(indicator)
                spinner = indicator
                layoutSpinner()
                indicator.startAnimation(nil)
            } else {
                spinner?.stopAnimation(nil)
                spinner?.removeFromSuperview()
                spinner = nil
            }
        }
    }

    private func layoutSpinner() {
        guard let spinner else { return }
        // The spinner hangs off the bar, so the bar keeps its thickness.
        clipsToBounds = false
        let size = Self.spinnerSize
        spinner.frame = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
    }
}
