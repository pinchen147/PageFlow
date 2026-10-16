import AppKit

/// the reference editor's "…" button (doc 24 §5.3.5, §5.4.2): 28 pt, radius 8, beside
/// the table's visible right edge (22 pt out, or 34 pt in when the editor has
/// less than 50 pt to spare). It opens "Table actions": Edit table source and
/// Delete table. It lives in the editor's scroll view, above the text.
final class TableActionsButton: NSView {
    weak var controller: TableActionsController?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isMenuOpen = false { didSet { if isMenuOpen != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("More actions")
        toolTip = "More actions (⌘F6)"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    // AXButton "More actions" with its menu (AXShowMenu) and expanded state.
    override func accessibilityPerformPress() -> Bool {
        controller?.toggleMenu(fromKeyboard: true, lastRow: false)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool { accessibilityPerformPress() }
    override func isAccessibilityExpanded() -> Bool { isMenuOpen }
    override func accessibilityHelp() -> String? { toolTip }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ChromePalette.surface.setFill()
        box.fill()
        let active = isHovered || isMenuOpen
        if active {
            ChromePalette.hover.setFill()
            box.fill()
        }
        ChromePalette.border.setStroke()
        box.lineWidth = 1
        box.stroke()
        SelectionBarButton.drawSymbol("ellipsis", size: 14, in: NSRect(x: 7, y: 7, width: 14, height: 14),
                                      color: active ? ChromePalette.text : ChromePalette.secondaryText)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// the reference editor acts on click; the press itself leaves focus where it is.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        controller?.toggleMenu(fromKeyboard: false, lastRow: false)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 49, 125: controller?.toggleMenu(fromKeyboard: true, lastRow: false)   // Return, Enter, Space, ↓
        case 126: controller?.toggleMenu(fromKeyboard: true, lastRow: true)                // ↑
        case 53, 48: controller?.focusText()                                                // Escape, Tab
        default: super.keyDown(with: event)
        }
    }
}

/// Places and shows the "…" button for the table that has the caret or a
/// range (and, from Phase 5 hover, the pointer), and runs its menu.
final class TableActionsController {
    private weak var coordinator: NativeTextViewCoordinator?
    private weak var scrollView: NSScrollView?
    let button = TableActionsButton()
    private(set) var menu: TableMenuView?
    /// The table under the pointer, set by the hover chrome.
    var hoveredTable: NSRange? { didSet { if hoveredTable != oldValue { update() } } }
    /// Set when the menu closed without returning focus to the button; the
    /// next caret change in a table clears it (the reference editor's "dismissed").
    private var dismissed = false
    private var observers: [NSObjectProtocol] = []
    /// Off only in tests, whose windows cannot become key.
    var requiresKeyWindow = true

    init(coordinator: NativeTextViewCoordinator, scrollView: NSScrollView) {
        self.coordinator = coordinator
        self.scrollView = scrollView
        button.controller = self
        button.isHidden = true
        scrollView.addSubview(button, positioned: .above, relativeTo: nil)
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSWindow) === self.scrollView?.window else { return }
                    self.update()
                }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func uninstall() {
        menu?.close(.dismissed)
        button.removeFromSuperview()
    }

    /// The caret moved inside a table: the button may show again.
    func caretMoved() {
        dismissed = false
        update()
    }

    /// The table the button belongs to now (the reference editor's resolver, first match wins).
    private var targetTable: NSRange? {
        guard let coordinator, let main = coordinator.textView, let window = main.window else { return nil }
        let session = coordinator.tableEditingSession
        if menu != nil || window.firstResponder === button { return session.table?.range ?? hoveredTable }
        if let hoveredTable { return hoveredTable }
        let focused = (window.isKeyWindow || !requiresKeyWindow) && [main, session.editor].contains { window.firstResponder === $0 }
        guard session.isActive, !dismissed, focused else { return nil }
        return session.table?.range
    }

    /// Show, hide and place the button.
    func update() {
        guard let scrollView, let coordinator, let main = coordinator.textView as? NativeTextView,
              let range = targetTable, let rect = tableRect(range, main: main, in: scrollView) else {
            if menu == nil, button.window?.firstResponder !== button { button.isHidden = true }
            return
        }
        // Outside the table when 50 pt remain to the editor's right edge, else inside its top-right corner.
        let outside = scrollView.bounds.width - rect.visibleRight >= 50
        let x = outside ? ceil(rect.visibleRight) + 22 : rect.visibleRight - 34
        let top = outside ? rect.top : rect.top + 6
        let frame = NSRect(x: x, y: scrollView.isFlipped ? top : scrollView.bounds.height - top - 28, width: 28, height: 28)
        if button.frame != frame { button.frame = frame }
        button.isHidden = false
    }

    /// The table's top and visible right edge in the scroll view's top-down coordinates.
    private func tableRect(_ range: NSRange, main: NativeTextView, in scrollView: NSScrollView) -> (top: CGFloat, visibleRight: CGFloat)? {
        guard let canvas = main.tableCanvas(forTableAt: range),
              let geometry = coordinator?.tableEditingSession.geometry(forTableAt: range) else { return nil }
        let size = geometry.size
        let local = NSRect(x: canvas.origin.x, y: canvas.origin.y, width: size.width, height: size.height)
        let full = canvas.view.convert(local, to: scrollView)
        let visible = canvas.view.convert(local.intersection(canvas.view.visibleRect), to: scrollView)
        let top = scrollView.isFlipped ? full.minY : scrollView.bounds.height - full.maxY
        let right = visible.isEmpty ? full.maxX : visible.maxX
        return (top, right)
    }

    // MARK: - Menu

    func toggleMenu(fromKeyboard: Bool, lastRow: Bool) {
        if let menu {
            menu.close(.dismissed)
            return
        }
        guard let scrollView, let coordinator else { return }
        let session = coordinator.tableEditingSession
        typealias Item = TableMenuView.Item
        var items: [Item] = []
        // the reference editor's table "…": Comment first, on the whole table.
        if let comments = coordinator.comments, let range = session.table?.range ?? hoveredTable {
            items += [
                Item("Comment", symbol: "plus.bubble") { [weak comments] in
                    MainActor.assumeIsolated { comments?.beginTableComment(range) }
                },
                .separator,
            ]
        }
        items += [
            Item("Edit table source", symbol: nil) { [weak session] in session?.editTableSource(nil) },
            .separator,
            Item("Delete table", symbol: nil, isDanger: true) { [weak session] in
                guard let session else { return }
                session.setCellSelection(nil)
                // the reference editor always announces this one, even from a click.
                if session.deleteTable() { MarkdownTableEditingSession.announce("Table deleted") }
            },
        ]
        let anchor = scrollView.isFlipped ? button.frame
            : NSRect(x: button.frame.minX, y: scrollView.bounds.height - button.frame.maxY, width: 28, height: 28)
        button.isMenuOpen = true
        menu = TableMenuView.present(items, family: .object, label: "Table actions", placement: .below(anchor, rightAligned: true),
                                     in: scrollView, fromKeyboard: fromKeyboard,
                                     returningFocusTo: session.isActive ? session.editor : coordinator.textView) { [weak self] reason in
            guard let self else { return }
            self.menu = nil
            self.button.isMenuOpen = false
            // Escape returns to the button; anything else leaves it until the caret moves.
            if reason == .escape {
                self.button.window?.makeFirstResponder(self.button)
            } else {
                self.dismissed = true
            }
            self.update()
        }
        if fromKeyboard, lastRow { menu?.focusLast() }
    }

    /// F6 with the caret in a table and no selection bar: the button takes focus.
    @discardableResult
    func focusButton() -> Bool {
        dismissed = false
        update()
        guard !button.isHidden else { return false }
        return button.window?.makeFirstResponder(button) == true
    }

    func focusText() {
        guard let coordinator else { return }
        let session = coordinator.tableEditingSession
        button.window?.makeFirstResponder(session.isActive ? session.editor : coordinator.textView)
        update()
    }
}
