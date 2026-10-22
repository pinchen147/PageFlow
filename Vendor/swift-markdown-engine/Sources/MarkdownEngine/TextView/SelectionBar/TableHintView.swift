import AppKit

/// the reference editor's one-time table hint (doc 24 §5.3.7): the first time the
/// caret enters a cell it says how to reach the row and column commands,
/// right-aligned 6 pt above the table, for 4 s and a 200 ms fade. A key, a
/// click or a scroll dismisses it (within the first second it re-arms); a
/// right-click in a table or opening Cell actions latches it off. Once per
/// app session (the reference editor: once per page load).
final class TableHintView: NSView {
    static let text = "Right-click a cell\u{2019}s blank space, or press \u{21E7}F10, for row and column options"
    /// Latched for the rest of the app session.
    nonisolated(unsafe) static var latched = false

    private let label = NSTextField(labelWithString: TableHintView.text)
    private var shownAt: CFAbsoluteTime?
    private var timer: Timer?
    private var monitor: Any?
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        addSubview(label)
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

    var isShowing: Bool { superview != nil && shownAt != nil }

    /// Shows the hint for a table (`table`: its rect, `cell`: the focused
    /// cell's, both in `host`'s top-down coordinates), unless latched.
    func show(table: NSRect, cell: NSRect, in host: NSScrollView) {
        guard !Self.latched, !isShowing else { return }
        let available = host.bounds.width - 16
        let size = label.sizeThatFits(NSSize(width: available - 16, height: .greatestFiniteMagnitude))
        let width = min(ceil(size.width) + 16, available)
        let height = max(24, ceil(size.height) + 6)
        label.frame = NSRect(x: 8, y: (height - ceil(size.height)) / 2, width: width - 16, height: ceil(size.height))
        var origin = NSPoint(x: table.maxX - width, y: table.minY - 6 - height)
        if origin.y < 8 {
            // Too close to the top: 6 below the focused cell, left-aligned to it.
            origin = NSPoint(x: cell.minX, y: cell.maxY + 6)
        }
        origin.x = max(8, min(origin.x, host.bounds.width - width - 8))
        let topDown = NSRect(origin: origin, size: NSSize(width: width, height: height))
        frame = host.isFlipped ? topDown : NSRect(x: topDown.minX, y: host.bounds.height - topDown.maxY, width: width, height: height)
        alphaValue = 1
        host.addSubview(self, positioned: .above, relativeTo: nil)
        shownAt = CFAbsoluteTimeGetCurrent()
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: Self.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.dismiss()
            return event
        }
        host.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: host.contentView,
                                                          queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The hint's life ran out: a 200 ms fade, then it is gone for the session.
    private func expire() {
        Self.latched = true
        tearDown()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        })
    }

    /// Ends the 4 s life now (tests).
    func expireNow() { expire() }

    /// A key, click or scroll: gone now; within the first second it may show again.
    func dismiss() {
        guard let shownAt else { return }
        if CFAbsoluteTimeGetCurrent() - shownAt >= 1 { Self.latched = true }
        tearDown()
        removeFromSuperview()
    }

    /// A right-click in a table or Cell actions: never again this session.
    func latch() {
        Self.latched = true
        if isShowing { dismiss() }
    }

    private func tearDown() {
        shownAt = nil
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
