import AppKit

/// the reference editor's table menus (doc 24 §5.4, §5.10.3, §7.4.6): the floatmenu
/// family (grip menus, Cell actions, Insert block) and the objmenu family
/// ("…", Move row or column). Radius 12, padding 4, 32 pt rows of a 16 pt
/// icon and 14 pt label; separators, danger rows, and disabled rows that stay
/// focusable and explain themselves in a tooltip. Submenus replace the menu in
/// place. The menu takes the keyboard while it is open.
final class TableMenuView: NSView {
    enum Family { case float, object }

    struct Item {
        var title: String
        /// A 16 pt SF Symbol; nil leaves the 16 pt space empty.
        var symbol: String?
        var isDanger = false
        /// Set for a disabled row: the reason its tooltip gives.
        var disabledReason: String?
        /// Radio rows (objmenu) show a ✓ when true.
        var checked: Bool?
        /// A chord shown muted at the row's end ("Hide comments ⌥⇧C").
        var shortcut: String?
        var action: (() -> Void)?
        fileprivate var isSeparator = false

        init(_ title: String, symbol: String?, isDanger: Bool = false, disabledReason: String? = nil,
             checked: Bool? = nil, shortcut: String? = nil, action: (() -> Void)?) {
            self.shortcut = shortcut
            self.title = title
            self.symbol = symbol
            self.isDanger = isDanger
            self.disabledReason = disabledReason
            self.checked = checked
            self.action = action
        }

        static var separator: Item {
            var item = Item("", symbol: nil, action: nil)
            item.isSeparator = true
            return item
        }

        var isEnabled: Bool { disabledReason == nil && action != nil }
    }

    /// Where the menu opens, in the host's top-down coordinates.
    enum Placement {
        /// 4 below `rect`, flipped above when it does not fit; left-aligned,
        /// or right-aligned to `rect` (the "…" menu).
        case below(NSRect, rightAligned: Bool)
        /// At a point (Cell actions from the mouse), pushed inside the edges.
        case at(NSPoint)
    }

    /// Why the menu closed: callers decide where focus goes.
    enum CloseReason { case chosen, escape, tab, outside, dismissed }

    let family: Family
    private var items: [Item]
    private var rowFrames: [NSRect] = []
    private(set) var focused: Int?
    private var onClose: ((CloseReason) -> Void)?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Where focus returns when the menu closes on Tab or Escape.
    private weak var textResponder: NSResponder?
    /// The menu closes on any scroll of this view's document (not Cell actions).
    var closesOnScroll = true
    /// Cell actions closes on ⌘Z, ⌘Y and any printable key ("wake").
    var closesOnTyping = false

    private init(items: [Item], family: Family, label: String) {
        self.items = Self.tidy(items)
        self.family = family
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Drops leading, trailing and doubled separators (the reference editor).
    private static func tidy(_ items: [Item]) -> [Item] {
        var result: [Item] = []
        for item in items {
            if item.isSeparator, result.last?.isSeparator ?? true { continue }
            result.append(item)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }

    /// Opens `items` in `host` (usually the editor's scroll view). From the
    /// keyboard the first enabled row is focused; from the mouse, the menu.
    @discardableResult
    static func present(
        _ items: [Item], family: Family, label: String, minimumWidth: CGFloat? = nil, placement: Placement,
        in host: NSView, fromKeyboard: Bool, returningFocusTo text: NSResponder?,
        onClose: @escaping (CloseReason) -> Void
    ) -> TableMenuView {
        // One table menu at a time: a new one replaces any still open in this editor.
        for open in host.subviews.compactMap({ $0 as? TableMenuView }) { open.close(.dismissed) }
        let menu = TableMenuView(items: items, family: family, label: label)
        menu.onClose = onClose
        menu.textResponder = text
        menu.layoutRows(minimumWidth: minimumWidth ?? (family == .float ? 128 : 160), viewport: host.bounds.width)
        menu.place(placement, in: host)
        host.addSubview(menu, positioned: .above, relativeTo: nil)
        host.window?.makeFirstResponder(menu)
        // A right-click's own handling can hand the keyboard back to the text
        // after this runs; the menu takes it again once the event is done.
        DispatchQueue.main.async { [weak menu] in
            MainActor.assumeIsolated {
                guard let menu, menu.superview != nil, let window = menu.window, window.firstResponder !== menu else { return }
                window.makeFirstResponder(menu)
            }
        }
        if fromKeyboard { menu.focused = menu.items.indices.first { menu.items[$0].isEnabled } }
        menu.installDismissal(in: host)
        if family == .float, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // the reference editor's floatmenu fades in from .6 over 120 ms; objmenus do not animate.
            menu.alphaValue = 0.6
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                menu.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(element: menu, notification: .created)
        return menu
    }

    private func layoutRows(minimumWidth: CGFloat, viewport: CGFloat) {
        let font = NSFont.systemFont(ofSize: 14)
        var width = minimumWidth
        let checks = items.contains { $0.checked != nil }
        for item in items where !item.isSeparator {
            let label = (item.title as NSString).size(withAttributes: [.font: font]).width
            let chord = item.shortcut.map { 16 + ceil(($0 as NSString).size(withAttributes: [.font: font]).width) } ?? 0
            width = max(width, 4 + 10 + 16 + 8 + ceil(label) + chord + (checks ? 8 + 12 : 0) + 10 + 4)
        }
        width = min(width, min(320, viewport - 16))
        var y: CGFloat = 4
        rowFrames = items.map { item in
            let height: CGFloat = item.isSeparator ? 9 : 32
            defer { y += height }
            return NSRect(x: 4, y: y, width: width - 8, height: height)
        }
        setFrameSize(NSSize(width: ceil(width), height: y + 4))
    }

    private func place(_ placement: Placement, in host: NSView) {
        let visible = host.bounds
        let size = frame.size
        var origin: NSPoint
        switch placement {
        case .below(let rect, let rightAligned):
            origin = NSPoint(x: rightAligned ? rect.maxX - size.width : rect.minX, y: rect.maxY + 4)
            if origin.y + size.height > visible.height - 8 { origin.y = max(8, rect.minY - 4 - size.height) }
        case .at(let point):
            origin = point
            if origin.y + size.height > visible.height - 8 { origin.y = visible.height - 8 - size.height }
        }
        origin.x = max(8, min(origin.x, visible.width - size.width - 8))
        origin.y = max(8, origin.y)
        let topDown = NSRect(origin: origin, size: size)
        frame = host.isFlipped ? topDown : NSRect(x: topDown.minX, y: visible.height - topDown.maxY, width: size.width, height: size.height)
        addToolTips()
    }

    private func addToolTips() {
        removeAllToolTips()
        for (index, item) in items.enumerated() {
            if let reason = item.disabledReason { addToolTip(rowFrames[index], owner: reason as NSString, userData: nil) }
        }
    }

    private func installDismissal(in host: NSView) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            let inside = event.window === self.window && self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            if !inside {
                self.close(.outside)
            } else if event.type == .rightMouseDown {
                // A right mouse-down inside closes the menu too.
                self.close(self.family == .float ? .tab : .outside)
                return nil
            }
            return event
        } as Any)
        let center = NotificationCenter.default
        if let scroll = host as? NSScrollView ?? host.enclosingScrollView {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.closesOnScroll else { return }
                    self.close(.dismissed)
                }
            })
        }
        if let window = host.window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        // Cell actions survives a resize; every menu closes on deactivation.
                        if note.name == NSWindow.didResizeNotification, !self.closesOnScroll { return }
                        self.close(.dismissed)
                    }
                })
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = ChromePalette.isDark(effectiveAppearance)
        ChromePalette.surface.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        outline.fill()
        ChromePalette.border.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = family == .object && dark ? 0.32 : 0.12
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        for (index, item) in items.enumerated() {
            let frame = rowFrames[index]
            if item.isSeparator {
                ChromePalette.border.setFill()
                let inset: CGFloat = family == .float ? 10 : 0
                NSRect(x: frame.minX + inset, y: frame.minY + 4, width: frame.width - inset * 2, height: 1).fill()
                continue
            }
            let highlighted = index == focused
            let alpha: CGFloat = item.isEnabled ? 1 : 0.4
            if highlighted, item.isEnabled {
                (item.isDanger ? Self.dangerFill : ChromePalette.hover).setFill()
                NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
            }
            let textColor: NSColor = item.isDanger
                ? (highlighted && item.isEnabled ? .white : Self.dangerText)
                : ChromePalette.text
            let iconColor = item.isDanger || family == .float ? textColor : ChromePalette.secondaryText
            var x = frame.minX + 10
            if let symbol = item.symbol {
                SelectionBarButton.drawSymbol(symbol, size: 16, in: NSRect(x: x, y: frame.midY - 8, width: 16, height: 16),
                                              color: iconColor.withAlphaComponent(alpha))
            }
            x += 16 + 8
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
                                                             .foregroundColor: textColor.withAlphaComponent(alpha)]
            let size = (item.title as NSString).size(withAttributes: attributes)
            (item.title as NSString).draw(at: NSPoint(x: x, y: frame.midY - size.height / 2), withAttributes: attributes)
            if item.checked == true {
                SelectionBarButton.drawSymbol("checkmark", size: 12, in: NSRect(x: frame.maxX - 10 - 12, y: frame.midY - 6, width: 12, height: 12),
                                              color: textColor.withAlphaComponent(alpha))
            }
            if let shortcut = item.shortcut {
                let chord: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
                                                            .foregroundColor: ChromePalette.secondaryText.withAlphaComponent(alpha)]
                let chordSize = (shortcut as NSString).size(withAttributes: chord)
                (shortcut as NSString).draw(at: NSPoint(x: frame.maxX - 10 - chordSize.width, y: frame.midY - chordSize.height / 2),
                                            withAttributes: chord)
            }
        }
    }

    /// the reference editor's danger row: #ec7e7e / #8e2626 text; #d03b3b fill with white text when active.
    static let dangerText = NSColor(name: nil) { appearance in
        ChromePalette.isDark(appearance)
            ? NSColor(srgbRed: 0xEC / 255, green: 0x7E / 255, blue: 0x7E / 255, alpha: 1)
            : NSColor(srgbRed: 0x8E / 255, green: 0x26 / 255, blue: 0x26 / 255, alpha: 1)
    }
    private static let dangerFill = NSColor(srgbRed: 0xD0 / 255, green: 0x3B / 255, blue: 0x3B / 255, alpha: 1)

    // MARK: - Input

    private func row(at point: NSPoint) -> Int? {
        rowFrames.indices.first { rowFrames[$0].contains(point) && !items[$0].isSeparator }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

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
        activate(index)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let selectable = items.indices.filter { !items[$0].isSeparator }
        switch event.keyCode {
        case 125: // ↓ wraps
            focused = focused.flatMap { current in selectable.first { $0 > current } } ?? selectable.first
            needsDisplay = true
        case 126: // ↑ wraps
            focused = focused.flatMap { current in selectable.last { $0 < current } } ?? selectable.last
            needsDisplay = true
        case 115: focused = selectable.first; needsDisplay = true   // Home
        case 119: focused = selectable.last; needsDisplay = true    // End
        case 36, 76, 49: // Return, Enter, Space
            if let focused { activate(focused) } else if closesOnTyping { close(.tab) }
        case 53: close(.escape)
        case 48: close(.tab)
        default:
            // ⌘Z and ⌘Y never reach the document while a menu is open; Cell actions closes on them.
            if flags == .command, ["z", "y"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
                if closesOnTyping { close(.tab) }
                return
            }
            if closesOnTyping, flags.isDisjoint(with: [.command, .control]), event.characters?.isEmpty == false { close(.tab) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.contains(.command), ["z", "y"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Runs the row's action after closing, unless the row is disabled.
    private func activate(_ index: Int) {
        guard items.indices.contains(index), items[index].isEnabled, let action = items[index].action else { return }
        close(.chosen)
        action()
    }

    /// Focus the row titled `title` (the Column width menu's checked row).
    func focus(title: String) {
        focused = items.firstIndex { $0.title == title }
        needsDisplay = true
    }

    /// From ↑ on the "…" button: the last enabled row.
    func focusLast() {
        focused = items.indices.last { items[$0].isEnabled }
        needsDisplay = true
    }

    /// Activates the row titled `title` (tests).
    func activate(title: String) {
        if let index = items.firstIndex(where: { $0.title == title }) { activate(index) }
    }

    /// Row `index`'s frame, nil for a separator.
    func rowFrame(at index: Int) -> NSRect? {
        items.indices.contains(index) && !items[index].isSeparator ? rowFrames[index] : nil
    }

    /// Whether a radio row (the width menu) is checked; nil for an ordinary row.
    func isChecked(_ title: String) -> Bool? { items.first { $0.title == title }?.checked }

    /// The rows' titles, with "—" for a separator (tests).
    var titles: [String] { items.map { $0.isSeparator ? "—" : $0.title } }

    /// Whether the row titled `title` can run, and why not (tests).
    func disabledReason(of title: String) -> String? { items.first { $0.title == title }?.disabledReason }

    func close(_ reason: CloseReason) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        let window = self.window
        let wasFocused = window?.firstResponder === self
        removeFromSuperview()
        // Tab, Escape and a chosen row send focus back to the text (callers may move it on).
        if wasFocused, reason != .outside, let textResponder, let window { window.makeFirstResponder(textResponder) }
        let done = onClose
        onClose = nil
        done?(reason)
    }
}
