import AppKit

/// the reference editor's tooltip (doc 24 §6.9, §6.13): 24 tall, padding 0 8, radius 6,
/// 13 pt label, shown 400 ms after the pointer rests on a control, 4 above it
/// (below when that would leave the editor), with no fade.
final class ChromeTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addSubview(label)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ChromePalette.tooltipFill.cgColor
            label.textColor = ChromePalette.tooltipText
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = ChromePalette.isDark(effectiveAppearance) ? 0.24 : 0.08
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    /// Show `text` for `control` after the 400 ms delay, unless cancelled first.
    func schedule(_ text: String, for control: NSView, in host: NSView) {
        cancel()
        let work = DispatchWorkItem { [weak self, weak control, weak host] in
            guard let self, let control, let host, control.window != nil else { return }
            self.show(text, for: control, in: host)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        isHidden = true
    }

    private func show(_ text: String, for control: NSView, in host: NSView) {
        if superview !== host { host.addSubview(self, positioned: .above, relativeTo: nil) }
        label.stringValue = text
        // Wraps at 240 when the label is longer than 48 characters.
        let maxWidth: CGFloat = text.count > 48 ? 240 : 10_000
        let size = label.sizeThatFits(NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let width = ceil(size.width) + 16
        let height = max(24, ceil(size.height) + 6)
        label.frame = NSRect(x: 8, y: (height - ceil(size.height)) / 2, width: ceil(size.width), height: ceil(size.height))
        let rect = control.convert(control.bounds, to: host)
        let topDown = { (r: NSRect) -> NSRect in host.isFlipped ? r : NSRect(x: r.minX, y: host.bounds.height - r.maxY, width: r.width, height: r.height) }
        let control = topDown(rect)
        var y = control.minY - 4 - height
        if y < 8 { y = control.maxY + 4 }
        let x = max(8, min(control.midX - width / 2, host.bounds.width - width - 8))
        let frame = NSRect(x: x, y: y, width: width, height: height)
        self.frame = host.isFlipped ? frame : NSRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: width, height: height)
        isHidden = false
        needsDisplay = true
    }
}
