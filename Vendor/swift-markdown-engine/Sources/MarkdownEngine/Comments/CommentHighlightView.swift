import AppKit

/// the reference editor's comment highlights (doc 25 §3): one layer of gold per thread
/// under the text, so overlapping threads compound; 20 % at rest, 45 % lit,
/// and a 2 pt underline on the open thread. Colour changes fade over 200 ms.
/// Never written into the Markdown, never hit by the mouse.
final class CommentHighlightView: NSView {
    struct Paint: Equatable {
        /// The anchor's text segments, in this view's coordinates.
        var rects: [NSRect]
        var alpha: CGFloat
        var underlined: Bool
        var resolved = false
        /// A whole table: a 2 pt outline instead of a fill.
        var outline: NSColor?
        /// Inside a rendered table: painted over its raster, blended.
        var overTable = false
    }

    private final class ThreadLayer: CALayer {
        var fills: [CALayer] = []
        var lines: [CALayer] = []
    }

    private var threadLayers: [String: ThreadLayer] = [:]
    private(set) var paints: [String: Paint] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let current = paints
        paints = [:]
        apply(current, animated: false)
    }

    /// Paints `next`: geometry moves at once; colour and underline changes fade.
    func apply(_ next: [String: Paint], animated: Bool) {
        guard next != paints, let root = layer else { return }
        let fades = animated && !CommentPalette.reducesMotion
        var lineColor = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance { lineColor = CommentPalette.openLine.cgColor }

        for (id, layer) in threadLayers where next[id] == nil {
            layer.removeFromSuperlayer()
            threadLayers[id] = nil
        }
        for (id, paint) in next {
            let thread = threadLayers[id] ?? {
                let made = ThreadLayer()
                made.masksToBounds = false
                root.addSublayer(made)
                threadLayers[id] = made
                return made
            }()
            let base = paint.resolved ? CommentPalette.resolved : CommentPalette.gold
            var fill = base.withAlphaComponent(paint.alpha).cgColor
            var outline: CGColor?
            if let color = paint.outline {
                effectiveAppearance.performAsCurrentDrawingAppearance { outline = color.cgColor }
                fill = .clear
            }
            let previous = paints[id]
            // Geometry never animates.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            resize(&thread.fills, to: paint.rects.count, in: thread)
            resize(&thread.lines, to: paint.underlined && paint.outline == nil ? paint.rects.count : 0, in: thread)
            for (index, rect) in paint.rects.enumerated() {
                let layer = thread.fills[index]
                // An outline sits 2 pt outside the table, as CSS `outline` does.
                layer.frame = outline == nil ? rect : rect.insetBy(dx: -2, dy: -2)
                layer.borderWidth = outline == nil ? 0 : 2
                layer.borderColor = outline
                if previous == nil || !fades { layer.backgroundColor = fill }
            }
            for (index, rect) in paint.rects.enumerated() where paint.underlined && outline == nil {
                thread.lines[index].frame = NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
                thread.lines[index].backgroundColor = lineColor
            }
            CATransaction.commit()
            guard previous != nil, fades else { continue }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            CATransaction.setAnimationTimingFunction(CommentPalette.easeOut)
            thread.fills.forEach { $0.backgroundColor = fill }
            CATransaction.commit()
        }
        paints = next
    }

    private func resize(_ layers: inout [CALayer], to count: Int, in parent: CALayer) {
        while layers.count > count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < count {
            let layer = CALayer()
            layer.actions = ["position": NSNull(), "bounds": NSNull()]
            parent.addSublayer(layer)
            layers.append(layer)
        }
    }

    // MARK: - Motion (doc 25 §3.5)

    /// Your own new comment: the gold sweeps in left to right (one segment,
    /// 450 ms) or deepens from rest (several, 200 ms).
    func playArrival(of id: String) {
        guard !CommentPalette.reducesMotion, let thread = threadLayers[id], !thread.fills.isEmpty else { return }
        if thread.fills.count == 1, let fill = thread.fills.first {
            let mask = CALayer()
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            mask.anchorPoint = CGPoint(x: 0, y: 0.5)
            mask.frame = fill.bounds
            fill.mask = mask
            let sweep = CABasicAnimation(keyPath: "bounds.size.width")
            sweep.fromValue = 0
            sweep.toValue = fill.bounds.width
            sweep.duration = 0.45
            sweep.timingFunction = CommentPalette.snap
            CATransaction.begin()
            CATransaction.setCompletionBlock { fill.mask = nil }
            mask.add(sweep, forKey: "stroke-in")
            CATransaction.commit()
        } else {
            for fill in thread.fills {
                let deepen = CABasicAnimation(keyPath: "opacity")
                deepen.fromValue = CommentPalette.restAlpha / CommentPalette.activeAlpha
                deepen.toValue = 1
                deepen.duration = 0.2
                deepen.timingFunction = CommentPalette.easeOut
                fill.add(deepen, forKey: "deepen")
            }
        }
    }

    /// Resolve: after the card's 240 ms check, the gold wipes out to the right
    /// (one segment) or fades (several), 198 ms; then `completion`.
    func playResolve(of id: String, completion: @escaping () -> Void) {
        guard !CommentPalette.reducesMotion, let thread = threadLayers[id], !thread.fills.isEmpty else { return completion() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let parts = thread.fills + thread.lines
        if thread.fills.count == 1 {
            for part in parts {
                let mask = CALayer()
                mask.backgroundColor = CGColor(gray: 0, alpha: 1)
                mask.anchorPoint = CGPoint(x: 1, y: 0.5)
                mask.frame = part.bounds
                part.mask = mask
                let wipe = CABasicAnimation(keyPath: "bounds.size.width")
                wipe.fromValue = part.bounds.width
                wipe.toValue = 0
                wipe.beginTime = CACurrentMediaTime() + 0.24
                wipe.duration = 0.198
                wipe.timingFunction = CommentPalette.exit
                wipe.fillMode = .both
                wipe.isRemovedOnCompletion = false
                mask.add(wipe, forKey: "stroke-out")
            }
        } else {
            for part in parts {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.beginTime = CACurrentMediaTime() + 0.24
                fade.duration = 0.198
                fade.timingFunction = CommentPalette.exit
                fade.fillMode = .both
                fade.isRemovedOnCompletion = false
                part.add(fade, forKey: "fade-out")
            }
        }
        CATransaction.commit()
    }
}
