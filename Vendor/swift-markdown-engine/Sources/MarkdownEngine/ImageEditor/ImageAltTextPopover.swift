import AppKit

final class ImageAltTextPopover: NSView, NSTextViewDelegate {
    var onSave: ((String) -> Void)?
    var onClose: (() -> Void)?
    let editor = NSTextView(frame: .zero)
    private let save = ActionButton(title: "Save", target: nil, action: nil)
    private let cancel = ActionButton(title: "Cancel", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var entered = ProcessInfo.processInfo.systemUptime
    private var closed = false
    private weak var previousResponder: NSResponder?

    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Edit alt text")
        let title = NSTextField(labelWithString: "Alt text")
        title.font = .systemFont(ofSize: 13, weight: .medium); title.frame = NSRect(x: 16, y: 16, width: 328, height: 18); addSubview(title)
        let hint = NSTextField(wrappingLabelWithString: "Describe the image for people who can't see it.")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 38, width: 328, height: 32); addSubview(hint)
        editor.string = text; editor.font = .systemFont(ofSize: 13); editor.isRichText = false
        editor.isAutomaticSpellingCorrectionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.delegate = self; editor.setAccessibilityLabel("Alt text")
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 74, width: 328, height: 58))
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.documentView = editor
        editor.frame = scroll.contentView.bounds; editor.autoresizingMask = [.width]; editor.isVerticallyResizable = true
        addSubview(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 16, y: 138, width: 328, height: 16); addSubview(status)
        save.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        save.target = self; save.action = #selector(saveText); save.bezelStyle = .rounded
        cancel.target = self; cancel.action = #selector(cancelText); cancel.bezelStyle = .rounded
        save.frame = NSRect(x: 272, y: 166, width: 72, height: 28)
        cancel.frame = NSRect(x: 192, y: 166, width: 72, height: 28)
        addSubview(save); addSubview(cancel)
        save.nextKeyView = editor; editor.nextKeyView = cancel; cancel.nextKeyView = save
        updateStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    override var isFlipped: Bool { true }

    func present(in host: NSView, imageRect: NSRect) {
        previousResponder = host.window?.firstResponder
        let width = min(360, host.bounds.width - 16)
        var rect = imageRect
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        let x = min(max(rect.midX - width / 2, 8), host.bounds.width - width - 8)
        let y = rect.minY >= 212 ? rect.minY - 218 : rect.maxY + 8
        let top = NSRect(x: x, y: min(max(y, 8), host.bounds.height - 218), width: width, height: 210)
        frame = host.isFlipped ? top : NSRect(x: top.minX, y: host.bounds.height - top.maxY, width: width, height: top.height)
        // Keep the field usable in a narrow editor.
        for child in subviews where child.frame.minX == 16 { child.setFrameSize(NSSize(width: max(40, width - 32), height: child.frame.height)) }
        save.frame.origin.x = width - 88; cancel.frame.origin.x = width - 168
        host.addSubview(self, positioned: .above, relativeTo: nil)
        host.window?.makeFirstResponder(editor); editor.selectAll(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.close(restoreFocus: false) }
            return event
        }
    }

    private func updateStatus() {
        save.isEnabled = !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        status.stringValue = (editor.string as NSString).length >= 2048 ? "Alt text can be up to 2,048 characters." : ""
    }
    func textDidChange(_ notification: Notification) { updateStatus() }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        (textView.string as NSString).length - affectedCharRange.length + ((replacementString ?? "") as NSString).length <= 2048
    }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(restoreFocus: true); return true }
        if selector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() { saveText(); return true }
        if selector == #selector(NSResponder.insertTab(_:)) { window?.selectNextKeyView(textView); return true }
        if selector == #selector(NSResponder.insertBacktab(_:)) { window?.selectPreviousKeyView(textView); return true }
        return false
    }
    @objc private func saveText() {
        guard !closed, ProcessInfo.processInfo.systemUptime - entered >= 0.25, !editor.hasMarkedText() else { return }
        guard save.isEnabled else { MarkdownTableEditingSession.announce("Add alt text to save."); return }
        onSave?(editor.string); close(restoreFocus: true)
    }
    @objc private func cancelText() {
        guard ProcessInfo.processInfo.systemUptime - entered >= 0.25 else { return }; close(restoreFocus: true)
    }
    func close(restoreFocus: Bool) {
        guard !closed else { return }; closed = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let window = window; removeFromSuperview()
        if restoreFocus { window?.makeFirstResponder(previousResponder) }
        onClose?()
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        ChromePalette.surface.setFill(); outline.fill(); ChromePalette.border.setStroke(); outline.lineWidth = 1; outline.stroke()
        ChromePalette.applyBarShadow(to: layer!, dark: ChromePalette.isDark(effectiveAppearance))
    }
}
