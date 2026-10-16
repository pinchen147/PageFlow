import AppKit

/// the reference editor's bar dropdown, the "selmenu" family (doc 24 §6.6, §6.13):
/// radius 12, padding 4, min width 140; 28 pt rows with a 12 pt glyph or a
/// 16 pt symbol, a 13 pt label, a hint and a ✓ on the current row. It opens on
/// mouse-down under its trigger, takes the keyboard (↑/↓, Return, Escape) and
/// closes on a choice, Escape or a click outside. It does not animate.
final class ChromeMenuView: NSView {
    struct Row {
        enum Leading { case glyph(String), symbol(String), none }
        let title: String
        let leading: Leading
        let shortcut: String?
        let checked: Bool
        let isSeparator: Bool
        let action: (() -> Void)?

        init(title: String, glyph: String, shortcut: String? = nil, checked: Bool, action: @escaping () -> Void) {
            self.title = title
            leading = .glyph(glyph)
            self.shortcut = shortcut
            self.checked = checked
            isSeparator = false
            self.action = action
        }

        init(title: String, symbol: String, shortcut: String? = nil, checked: Bool, action: @escaping () -> Void) {
            self.title = title
            leading = .symbol(symbol)
            self.shortcut = shortcut
            self.checked = checked
            isSeparator = false
            self.action = action
        }

        private init() {
            title = ""
            leading = .none
            shortcut = nil
            checked = false
            isSeparator = true
            action = nil
        }

        static let separator = Row()
    }

    private let rows: [Row]
    private var rowFrames: [NSRect] = []
    private var focused: Int?
    private var onClose: (() -> Void)?
    private var monitor: Any?
    private weak var previousResponder: NSResponder?

    private init(rows: [Row]) {
        self.rows = rows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    /// Open `rows` 4 pt below `trigger` inside `host`; `onClose` runs once when it closes.
    @discardableResult
    static func present(_ rows: [Row], below trigger: NSView, in host: NSView, onClose: @escaping () -> Void) -> ChromeMenuView {
        let menu = ChromeMenuView(rows: rows)
        menu.onClose = onClose
        menu.layoutRows()
        let anchor = trigger.convert(trigger.bounds, to: host)
        var frame = NSRect(x: anchor.minX, y: 0, width: menu.frame.width, height: menu.frame.height)
        if host.isFlipped {
            frame.origin.y = anchor.maxY + 4
            if frame.maxY > host.bounds.height - 8 { frame.origin.y = anchor.minY - 4 - frame.height }
        } else {
            frame.origin.y = anchor.minY - 4 - frame.height
            if frame.minY < 8 { frame.origin.y = anchor.maxY + 4 }
        }
        frame.origin.x = max(8, min(frame.minX, host.bounds.width - frame.width - 8))
        menu.frame = frame
        host.addSubview(menu, positioned: .above, relativeTo: nil)
        menu.previousResponder = host.window?.firstResponder
        host.window?.makeFirstResponder(menu)
        menu.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak menu] event in
            guard let menu else { return event }
            if event.window !== menu.window || !menu.bounds.contains(menu.convert(event.locationInWindow, from: nil)) {
                menu.close(restoreFocus: false)
            }
            return event
        }
        return menu
    }

    private func layoutRows() {
        let font = NSFont.systemFont(ofSize: 13)
        let hintFont = NSFont.systemFont(ofSize: 12)
        var width: CGFloat = 140
        for row in rows where !row.isSeparator {
            let label = (row.title as NSString).size(withAttributes: [.font: font]).width
            let hint = row.shortcut.map { ($0 as NSString).size(withAttributes: [.font: hintFont]).width + 12 } ?? 0
            width = max(width, 4 + 8 + 16 + 8 + label + hint + 8 + 12 + 8 + 4)
        }
        var y: CGFloat = 4
        rowFrames = rows.map { row in
            let height: CGFloat = row.isSeparator ? 1 + 3 + 4 : 28
            defer { y += height }
            return NSRect(x: 4, y: y, width: width - 8, height: height)
        }
        setFrameSize(NSSize(width: ceil(width), height: y + 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = ChromePalette.isDark(effectiveAppearance)
        ChromePalette.surface.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        outline.fill()
        ChromePalette.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.24 : 0.08
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -12)
        for (index, row) in rows.enumerated() {
            let frame = rowFrames[index]
            if row.isSeparator {
                ChromePalette.border.setFill()
                NSRect(x: frame.minX, y: frame.minY + 3, width: frame.width, height: 1).fill()
                continue
            }
            if index == focused {
                ChromePalette.hover.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            } else if row.checked {
                ChromePalette.current.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
            var x = frame.minX + 8
            switch row.leading {
            case .glyph(let glyph):
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                                  .foregroundColor: ChromePalette.text]
                let size = (glyph as NSString).size(withAttributes: attributes)
                (glyph as NSString).draw(at: NSPoint(x: x + (16 - size.width) / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
                x += 16 + 8
            case .symbol(let name):
                SelectionBarButton.drawSymbol(name, size: 16, in: NSRect(x: x, y: frame.midY - 8, width: 16, height: 16), color: ChromePalette.text)
                x += 16 + 8
            case .none:
                break
            }
            let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ChromePalette.text]
            let labelSize = (row.title as NSString).size(withAttributes: labelAttributes)
            (row.title as NSString).draw(at: NSPoint(x: x, y: frame.midY - labelSize.height / 2), withAttributes: labelAttributes)
            var right = frame.maxX - 8
            if row.checked {
                SelectionBarButton.drawSymbol("checkmark", size: 12, in: NSRect(x: right - 12, y: frame.midY - 6, width: 12, height: 12),
                                              color: ChromePalette.text)
            }
            right -= 12 + 8
            if let shortcut = row.shortcut {
                let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                                     .foregroundColor: ChromePalette.text.withAlphaComponent(0.55)]
                let size = (shortcut as NSString).size(withAttributes: hintAttributes)
                (shortcut as NSString).draw(at: NSPoint(x: right - size.width, y: frame.midY - size.height / 2), withAttributes: hintAttributes)
            }
        }
    }

    // MARK: - Input

    private func row(at point: NSPoint) -> Int? {
        rowFrames.indices.first { rowFrames[$0].contains(point) && !rows[$0].isSeparator }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = row(at: convert(event.locationInWindow, from: nil))
        if hovered != focused { focused = hovered; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        focused = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return }
        choose(index)
    }

    override func keyDown(with event: NSEvent) {
        let selectable = rows.indices.filter { !rows[$0].isSeparator }
        switch event.keyCode {
        case 125: // ↓
            let next = focused.flatMap { current in selectable.first { $0 > current } } ?? selectable.first
            focused = next
            needsDisplay = true
        case 126: // ↑
            let previous = focused.flatMap { current in selectable.last { $0 < current } } ?? selectable.last
            focused = previous
            needsDisplay = true
        case 36, 76, 49: // Return, Enter, Space
            if let focused { choose(focused) }
        case 53: // Escape
            close(restoreFocus: true)
        default:
            break
        }
    }

    private func choose(_ index: Int) {
        let action = rows[index].action
        close(restoreFocus: true)
        action?()
    }

    func close(restoreFocus: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let window = self.window
        removeFromSuperview()
        if restoreFocus, let previousResponder, window?.firstResponder !== previousResponder {
            window?.makeFirstResponder(previousResponder)
        }
        let close = onClose
        onClose = nil
        close?()
    }
}
