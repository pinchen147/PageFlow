//
//  GlassScroller.swift
//  PageFlow
//
//  Custom NSScroller with a visible glass knob over bright PDF pages.
//
//  The knob is rendered with plain CALayers (translucent fill + hairline
//  border + a subtle top sheen) rather than a live backdrop-blur view.
//  A scroller knob is repositioned on every scroll frame, and recomputing a
//  real Liquid Glass / NSVisualEffectView refraction that often is the classic
//  source of scroll jank. The layer-based knob keeps the glassy look while
//  tracking the scroll position with effectively zero per-frame cost.
//

import AppKit

final class GlassScroller: NSScroller {
    private let glassKnob = GlassScrollerKnobView()

    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue > 0.01 ? super.hitTest(point) : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var floatValue: Float {
        didSet {
            updateKnobFrame()
        }
    }

    override var knobProportion: CGFloat {
        didSet {
            updateKnobFrame()
        }
    }

    override func layout() {
        super.layout()
        updateKnobFrame()
    }

    override func drawKnob() {
        // The layer-backed child view replaces AppKit's painted knob.
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track: the knob floats over the PDF like an overlay scroller.
    }

    private func configure() {
        scrollerStyle = .overlay
        knobStyle = .default
        addSubview(glassKnob)
        updateKnobFrame()
    }

    private func updateKnobFrame() {
        glassKnob.updateFrame(rect(for: .knob))
    }
}

private final class GlassScrollerKnobView: NSView {
    private static let fillColor = NSColor(white: 0.17, alpha: 0.55)
    private static let strokeColor = NSColor.white.withAlphaComponent(0.5)
    private static let sheenTop = NSColor.white.withAlphaComponent(0.22).cgColor
    private static let sheenClear = NSColor.white.withAlphaComponent(0.0).cgColor

    private let sheen = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        guard let layer else { return }

        layer.masksToBounds = true
        layer.backgroundColor = Self.fillColor.cgColor
        layer.borderWidth = 1
        layer.borderColor = Self.strokeColor.cgColor

        // Subtle top-down highlight for a glassy sheen.
        sheen.colors = [Self.sheenTop, Self.sheenClear]
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(sheen)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func updateFrame(_ frame: NSRect) {
        isHidden = frame.isEmpty
        guard !frame.isEmpty else { return }

        // Disable implicit animations so the knob tracks the scroll position
        // exactly instead of lagging behind with a 0.25s default animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        let radius = min(frame.width, frame.height) / 2
        layer?.cornerRadius = radius
        sheen.frame = bounds
        CATransaction.commit()
    }
}
