import AppKit

/// the reference editor's docked table scroller (doc 24 §5.2.4): when a wide table's
/// own scroller is below the window, a copy pins to the editor's bottom edge.
/// It shows for the first wide table that overflows by more than 1 pt, whose
/// top is at least 72 pt above the viewport's bottom and whose bottom is below
/// it. The two scrollers follow each other, one observer each way, writing
/// only a change of 1 pt or more.
final class TableProxyScroller {
    private weak var coordinator: NativeTextViewCoordinator?
    private weak var scrollView: NSScrollView?
    let scroller = SubtleScroller()
    /// The table the docked scroller drives now.
    private(set) weak var overlay: WideTableOverlay?
    /// Set while this side writes, so the other side's echo is ignored.
    private var syncing = false
    private var observers: [NSObjectProtocol] = []

    init(coordinator: NativeTextViewCoordinator, scrollView: NSScrollView) {
        self.coordinator = coordinator
        self.scrollView = scrollView
        scroller.scrollerStyle = .legacy
        scroller.isEnabled = true
        scroller.isHidden = true
        scroller.target = self
        scroller.action = #selector(scrolled(_:))
        scroller.setAccessibilityLabel("Table scroller")
        scrollView.addSubview(scroller, positioned: .above, relativeTo: nil)
        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
        scrollView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView,
                                            queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.update() } })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func uninstall() { scroller.removeFromSuperview() }

    /// Picks the table, places the docked scroller and copies the table's offset.
    func update() {
        guard !syncing, let scrollView, let main = coordinator?.textView as? NativeTextView, main.window != nil else { return }
        let visible = main.visibleRect
        let bottom = visible.maxY
        let candidates = main.wideTableOverlays.values.compactMap { overlay -> (WideTableOverlay, NSRect)? in
            guard !overlay.isHidden, let superview = overlay.superview, let document = overlay.documentView else { return nil }
            let overflow = document.frame.width - overlay.contentView.bounds.width
            guard overflow > 1 else { return nil }
            return (overlay, superview.convert(overlay.frame, to: main))
        }.sorted { $0.1.minY < $1.1.minY }
        guard let (overlay, frame) = candidates.first(where: { $0.1.minY <= bottom - 72 && $0.1.maxY > bottom + 0.5 }) else {
            scroller.isHidden = true
            self.overlay = nil
            return
        }
        self.overlay = overlay
        // In the scroll view: from the table's 48 pt gutter to 2 pt short of its right edge, on the bottom edge.
        let inScroll = main.convert(frame, to: scrollView)
        let height = SubtleScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let x = inScroll.minX + 48
        let width = max(0, inScroll.width - 48 - 2)
        let y: CGFloat = scrollView.isFlipped ? scrollView.bounds.height - height : 0
        let target = NSRect(x: x, y: y, width: width, height: height)
        if scroller.frame != target { scroller.frame = target }
        scroller.isHidden = false
        copyOffset(from: overlay)
    }

    /// The table scrolled: the docked scroller follows.
    func tableDidScroll(_ overlay: WideTableOverlay) {
        guard !syncing, overlay === self.overlay else { return update() }
        copyOffset(from: overlay)
    }

    private func copyOffset(from overlay: WideTableOverlay) {
        guard let document = overlay.documentView else { return }
        let visible = overlay.contentView.bounds.width
        let range = document.frame.width - visible
        guard range > 0 else { return }
        let proportion = min(1, max(0.05, visible / document.frame.width))
        let value = min(1, max(0, overlay.horizontalOffset / range))
        if abs(scroller.knobProportion - proportion) > 0.001 { scroller.knobProportion = proportion }
        if abs((scroller.doubleValue - value) * range) >= 1 { scroller.doubleValue = value }
    }

    /// The docked scroller moved: the table follows.
    @objc private func scrolled(_ sender: NSScroller) {
        guard let overlay, let document = overlay.documentView else { return }
        let visible = overlay.contentView.bounds.width
        let range = document.frame.width - visible
        guard range > 0 else { return }
        var value = sender.doubleValue
        switch sender.hitPart {
        case .decrementPage: value -= visible / range
        case .incrementPage: value += visible / range
        default: break
        }
        value = min(1, max(0, value))
        let offset = value * range
        guard abs(offset - overlay.horizontalOffset) >= 1 else { return }
        syncing = true
        overlay.horizontalOffset = offset
        syncing = false
        sender.doubleValue = value
    }
}
