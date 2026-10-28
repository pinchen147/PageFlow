import AppKit
import MarkdownEngine

/// Plain text only: fixed height, bounded engine excerpt, no extra renderer or resource loading.
final class MarkdownSectionPreviewView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private var pressed = false
    var onActivate: (() -> Void)?
    override var isFlipped: Bool { true }

    init(preview: MarkdownSectionPreview) {
        super.init(frame: NSRect(x: 0, y: 0, width: 352, height: 104))
        title.stringValue = preview.title
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        excerpt.stringValue = preview.body
        excerpt.font = .systemFont(ofSize: 13)
        excerpt.textColor = .secondaryLabelColor
        excerpt.maximumNumberOfLines = 3
        excerpt.lineBreakMode = .byTruncatingTail
        addSubview(title)
        addSubview(excerpt)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(preview.title)
        setAccessibilityHelp(preview.body)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: 18)
        excerpt.frame = NSRect(x: 12, y: 36, width: max(0, bounds.width - 24), height: min(56, max(0, bounds.height - 48)))
    }
    override func draw(_ dirtyRect: NSRect) {
        // Opaque semantic material is the Reduce Transparency path in every appearance;
        // feedback is immediate, so Reduce Motion never needs a separate animation.
        NSColor.windowBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }
    override func mouseDragged(with event: NSEvent) { pressed = false }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return onActivate != nil }
}
