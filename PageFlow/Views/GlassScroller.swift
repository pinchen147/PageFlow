//
//  GlassScroller.swift
//  PageFlow
//
//  Custom NSScroller with a visible glass knob over bright PDF pages.
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
        // The Liquid Glass child view replaces AppKit's painted knob.
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
    private static let tintOpacity: CGFloat = 0.42
    private static let strokeOpacity: CGFloat = 0.52

    private let fill = HUDGlassFillView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(Self.strokeOpacity).cgColor

        fill.frame = bounds
        fill.autoresizingMask = [.width, .height]
        fill.apply(cornerRadius: 0, tint: .dark, tintOpacity: Self.tintOpacity, variant: .regular)
        addSubview(fill)
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

        self.frame = frame
        let radius = min(frame.width, frame.height) / 2
        layer?.cornerRadius = radius
        fill.apply(cornerRadius: radius, tint: .dark, tintOpacity: Self.tintOpacity, variant: .regular)
    }
}
