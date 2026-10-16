import AppKit

/// the reference editor's link dialog (doc 24 §6.7). Edit mode has Text and Link fields
/// with Cancel and Save; actions mode offers Open, Copy, Edit and Remove for
/// an existing link. It sits 8 above the selection (below near the top),
/// centred and kept 8 from the editor's sides, in the editor's scroll view.
final class MarkdownLinkPopover: NSView, NSTextFieldDelegate {
    enum Mode { case edit, actions }

    struct Target {
        /// The source range the dialog rewrites: the selection, or the whole link.
        var range: NSRange
        var text: String
        var url: String
        var isExistingLink: Bool
    }

    private(set) var mode: Mode
    private(set) var target: Target
    var onSave: ((String, String) -> Void)?
    var onRemove: (() -> Void)?
    var onClose: (() -> Void)?

    private let textField = NSTextField()
    private let linkField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []
    private var monitor: Any?

    init(mode: Mode, target: Target) {
        self.mode = mode
        self.target = target
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Link")
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        buttons = []
        let width: CGFloat = 360
        switch mode {
        case .edit:
            var y: CGFloat = 12
            for (title, field, value, label) in [("Text", textField, target.text, "Link text"), ("Link", linkField, target.url, "Link URL")] {
                let caption = NSTextField(labelWithString: title)
                caption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                caption.textColor = ChromePalette.secondaryText
                caption.frame = NSRect(x: 12, y: y, width: width - 24, height: 16)
                addSubview(caption)
                y += 18
                field.stringValue = value
                field.font = NSFont.systemFont(ofSize: 14)
                field.bezelStyle = .roundedBezel
                field.focusRingType = .default
                field.delegate = self
                field.setAccessibilityLabel(label)
                field.frame = NSRect(x: 12, y: y, width: width - 24, height: 28)
                addSubview(field)
                y += 28 + 10
            }
            linkField.placeholderString = "Paste a link"
            (linkField.cell as? NSTextFieldCell)?.isScrollable = true
            textField.isEnabled = (target.text as NSString).length <= 400
            if !textField.isEnabled { textField.toolTip = "This link's text is too long to edit here." }
            errorLabel.textColor = .systemRed
            errorLabel.font = NSFont.systemFont(ofSize: 12)
            errorLabel.frame = NSRect(x: 12, y: y, width: width - 24, height: 16)
            errorLabel.isHidden = true
            addSubview(errorLabel)
            y += 4
            let save = makeButton("Save", action: #selector(save(_:)))
            save.keyEquivalent = "\r"
            save.bezelColor = ChromePalette.accent
            let cancel = makeButton("Cancel", action: #selector(cancel(_:)))
            cancel.keyEquivalent = "\u{1b}"
            save.frame = NSRect(x: width - 12 - 72, y: y + 14, width: 72, height: 28)
            cancel.frame = NSRect(x: save.frame.minX - 8 - 72, y: y + 14, width: 72, height: 28)
            setFrameSize(NSSize(width: width, height: y + 14 + 28 + 12))
            updateSaveEnabled()
        case .actions:
            let display = NSTextField(labelWithString: Self.displayURL(target.url))
            display.font = NSFont.systemFont(ofSize: 13)
            display.textColor = ChromePalette.text
            display.lineBreakMode = .byTruncatingMiddle
            display.toolTip = target.url
            display.frame = NSRect(x: 12, y: 10, width: width - 24, height: 18)
            addSubview(display)
            let rows: [(String, Selector)] = [("Open link", #selector(openLink(_:))), ("Copy link", #selector(copyLink(_:))),
                                              ("Edit link", #selector(editLink(_:))), ("Remove link", #selector(removeLink(_:)))]
            var x: CGFloat = 12
            for (title, action) in rows {
                let button = makeButton(title, action: action)
                button.sizeToFit()
                button.frame = NSRect(x: x, y: 36, width: button.frame.width + 8, height: 28)
                x = button.frame.maxX + 6
            }
            setFrameSize(NSSize(width: max(width, x + 6), height: 36 + 28 + 10))
        }
        needsDisplay = true
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        addSubview(button)
        buttons.append(button)
        return button
    }

    /// The host plus a truncated path: what the reference editor shows for a link.
    static func displayURL(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        let path = parsed.path.count > 24 ? String(parsed.path.prefix(24)) + "…" : parsed.path
        return host + (path == "/" ? "" : path)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        ChromePalette.surface.setFill()
        outline.fill()
        ChromePalette.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = ChromePalette.isDark(effectiveAppearance) ? 0.32 : 0.12
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    // MARK: - Presenting

    /// Shows the dialog in `host`, anchored to `anchor` (top-down host points).
    func present(in host: NSView, anchor: NSRect, topInset: CGFloat) {
        let width = min(frame.width, host.bounds.width - 16)
        setFrameSize(NSSize(width: width, height: frame.height))
        let x = max(8, min(anchor.midX - width / 2, host.bounds.width - width - 8))
        var y = anchor.minY - 8 - frame.height
        if anchor.minY < topInset + frame.height + 8 { y = anchor.maxY + 8 }
        let topDown = NSRect(x: x, y: y, width: width, height: frame.height)
        frame = host.isFlipped ? topDown : NSRect(x: x, y: host.bounds.height - topDown.maxY, width: width, height: frame.height)
        host.addSubview(self, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(mode == .edit ? (target.text.isEmpty ? textField : linkField) : buttons.first)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.type == .scrollWheel || event.window !== self.window
                || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                self.close()
            }
            return event
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        removeFromSuperview()
        let done = onClose
        onClose = nil
        done?()
    }

    // MARK: - Edit mode

    func controlTextDidChange(_ notification: Notification) {
        errorLabel.isHidden = true
        updateSaveEnabled()
    }

    private func updateSaveEnabled() {
        buttons.first { $0.title == "Save" }?.isEnabled = !linkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { save(nil); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancel(nil); return true }
        return false
    }

    @objc private func save(_ sender: Any?) {
        switch MarkdownLinkURL.normalize(linkField.stringValue) {
        case .success(let url):
            let text = textField.stringValue.isEmpty ? url : textField.stringValue
            let save = onSave
            close()
            save?(text, url)
        case .failure(.tooLong):
            show("Link too long")
        case .failure(.notALink):
            show("That doesn't look like a link")
        }
    }

    private func show(_ error: String) {
        errorLabel.stringValue = error
        errorLabel.isHidden = false
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func cancel(_ sender: Any?) { close() }

    // MARK: - Testing seams

    func saveForTesting(text: String, url: String) {
        textField.stringValue = text
        linkField.stringValue = url
        save(nil)
    }

    func removeForTesting() { removeLink(nil) }

    var errorForTesting: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    // MARK: - Actions mode

    @objc private func openLink(_ sender: Any?) {
        if let url = URL(string: target.url) { NSWorkspace.shared.open(url) }
        close()
    }

    @objc private func copyLink(_ sender: Any?) {
        let board = NSPasteboard.general
        board.clearContents()
        if let url = URL(string: target.url) { board.writeObjects([url as NSURL]) }
        board.setString(target.url, forType: .string)
        close()
    }

    @objc private func editLink(_ sender: Any?) {
        mode = .edit
        build()
        if let host = superview {
            let anchor = frame
            removeFromSuperview()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            present(in: host, anchor: host.isFlipped ? anchor : NSRect(x: anchor.minX, y: host.bounds.height - anchor.maxY,
                                                                          width: anchor.width, height: anchor.height), topInset: 0)
        }
    }

    @objc private func removeLink(_ sender: Any?) {
        let remove = onRemove
        close()
        remove?()
    }
}
