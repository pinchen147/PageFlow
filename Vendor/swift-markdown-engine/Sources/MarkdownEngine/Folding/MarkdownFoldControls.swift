import AppKit

/// Reuses controls for laid-out headings only. No source parsing or offscreen layout.
final class MarkdownFoldControls {
    weak var coordinator: NativeTextViewCoordinator?
    weak var view: NativeTextView?
    private var buttons: [Int: (chevron: FoldButton, summary: FoldButton)] = [:]
    private var refreshing = false
    private var scheduled = false

    func setNeedsRefresh() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.refresh()
        }
    }

    init(coordinator: NativeTextViewCoordinator, view: NativeTextView) {
        self.coordinator = coordinator
        self.view = view
    }

    func refresh() {
        guard !refreshing, let coordinator, let view, let layout = view.textLayoutManager,
              let content = layout.textContentManager, let storage = view.textStorage,
              !coordinator.isUpdatingSourceOrStyle, !storage.editedMask.contains(.editedCharacters) else { return }
        refreshing = true
        defer { refreshing = false }
        let session = coordinator.foldSession
        let regions = session.index.regions
        let visible = view.visibleRect.insetBy(dx: 0, dy: -40)
        let origin = view.textContainerOrigin
        var present: Set<Int> = []
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return }
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > visible.maxY { return false }
            guard frame.maxY >= visible.minY else { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            var low = 0, high = regions.count
            while low < high {
                let middle = (low + high) / 2
                if regions[middle].heading.location < offset { low = middle + 1 } else { high = middle }
            }
            guard low < regions.count, regions[low].heading.location == offset,
                  coordinator.foldLayout.hiddenRange(containing: offset) == nil else { return true }
            let region = regions[low]
            guard NSMaxRange(region.heading) <= storage.length else { return true }
            let closed = session.collapsedHeadings.contains(offset)
            let pair: (chevron: FoldButton, summary: FoldButton)
            if let existing = self.buttons[offset] { pair = existing }
            else {
                let action: () -> Void = { [weak coordinator] in _ = coordinator?.performFolding(.toggleFold, heading: offset) }
                pair = (FoldButton(summary: false, action: action), FoldButton(summary: true, action: action))
                self.buttons[offset] = pair
                view.addSubview(pair.chevron)
                view.addSubview(pair.summary)
            }
            present.insert(offset)
            let title = view.textStorage?.mutableString.substring(with: region.heading)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Section"
            let enabled = coordinator.foldingInteractionAllowed
            pair.chevron.configure(closed: closed, count: region.hiddenBlockCount, title: title, enabled: enabled)
            pair.summary.configure(closed: closed, count: region.hiddenBlockCount, title: title, enabled: enabled)
            let line = fragment.textLineFragments.first?.typographicBounds ?? .zero
            pair.chevron.frame = NSRect(x: max(0, origin.x - 30), y: frame.minY + line.midY - 12, width: 24, height: 24)
            pair.summary.frame = NSRect(x: origin.x, y: frame.maxY - MarkdownFoldLayout.rowHeight,
                                       width: max(0, view.textContainer?.size.width ?? view.bounds.width),
                                       height: MarkdownFoldLayout.rowHeight)
            pair.summary.isHidden = !closed || !coordinator.configuration.showsHiddenContentRow
            let headingLines = fragment.textLineFragments.reduce(NSRect.null) { $0.union($1.typographicBounds) }
            let heading = NSRect(x: origin.x, y: frame.minY + headingLines.minY,
                                 width: pair.summary.frame.width, height: headingLines.height)
            pair.chevron.trackHeading(in: view, rect: heading.union(pair.chevron.frame))
            return true
        }
        for offset in Array(buttons.keys) where !present.contains(offset) {
            buttons.removeValue(forKey: offset).map {
                $0.chevron.stopTrackingHeading()
                $0.chevron.removeFromSuperview()
                $0.summary.removeFromSuperview()
            }
        }
    }

    /// Resolve native text-view cursor callbacks before they can replace the button's hand.
    func applyCursor(for event: NSEvent) -> Bool {
        guard let view else { return false }
        let point = view.convert(event.locationInWindow, from: nil)
        for pair in buttons.values {
            for button in [pair.chevron, pair.summary] where button.isEnabled && !button.isHiddenOrHasHiddenAncestor {
                if button.frame.contains(point) {
                    NSCursor.pointingHand.set()
                    return true
                }
            }
        }
        return false
    }

    var accessibilityControls: [NSButton] {
        buttons.keys.sorted().flatMap { offset -> [NSButton] in
            guard let pair = buttons[offset] else { return [] }
            return [pair.chevron, pair.summary].filter { !$0.isHiddenOrHasHiddenAncestor }
        }
    }

    func uninstall() {
        for pair in buttons.values {
            pair.chevron.stopTrackingHeading()
            pair.chevron.removeFromSuperview()
            pair.summary.removeFromSuperview()
        }
        buttons.removeAll()
    }
}

/// A stable native button; hover changes ink, never geometry or document metrics.
private final class FoldButton: NSButton {
    let summary: Bool
    let actionHandler: () -> Void
    private var closed = false
    private var count = 0
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var headingHovered = false { didSet { if oldValue != headingHovered { needsDisplay = true } } }
    private weak var headingView: NSView?
    private var headingTracking: NSTrackingArea?

    init(summary: Bool, action: @escaping () -> Void) {
        self.summary = summary
        self.actionHandler = action
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        self.action = #selector(pressed)
        focusRingType = .default
        setAccessibilityRole(summary ? .button : .disclosureTriangle)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func configure(closed: Bool, count: Int, title: String, enabled: Bool) {
        self.closed = closed
        self.count = count
        if isEnabled != enabled {
            isEnabled = enabled
            window?.invalidateCursorRects(for: self)
        }
        let heading = title.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\r\n"))
        let hidden = closed ? ", \(count) \(count == 1 ? "block" : "blocks") hidden" : ""
        setAccessibilityLabel("\(closed ? "Expand" : "Collapse") \(heading)\(hidden)")
        if !summary { setAccessibilityValue(NSNumber(value: !closed)) }
        needsDisplay = true
    }

    @objc private func pressed() { if isEnabled { actionHandler() } }
    override func accessibilityPerformPress() -> Bool { guard isEnabled else { return false }; actionHandler(); return true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self))
    }
    func trackHeading(in view: NSView, rect: NSRect) {
        guard headingView !== view || headingTracking?.rect != rect else { return }
        stopTrackingHeading()
        headingView = view
        let tracking = NSTrackingArea(rect: rect, options: [.activeInKeyWindow, .mouseEnteredAndExited],
                                      owner: self, userInfo: ["heading": true])
        headingTracking = tracking
        view.addTrackingArea(tracking)
        if let window, window.isKeyWindow {
            headingHovered = rect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    func stopTrackingHeading() {
        if let headingTracking { headingView?.removeTrackingArea(headingTracking) }
        headingTracking = nil
        headingView = nil
        headingHovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea?.userInfo?["heading"] as? Bool == true { headingHovered = true }
        else {
            hovered = true
            if isEnabled { NSCursor.pointingHand.set() }
        }
    }
    override func mouseExited(with event: NSEvent) {
        if event.trackingArea?.userInfo?["heading"] as? Bool == true { headingHovered = false }
        else { hovered = false }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: summary ? 4 : 6, yRadius: summary ? 4 : 6).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let active = hovered || focused
        let muted = dark ? NSColor(srgbRed: 147/255, green: 147/255, blue: 141/255, alpha: 1)
                         : NSColor(srgbRed: 119/255, green: 119/255, blue: 115/255, alpha: 1)
        let emphasized = dark ? NSColor(srgbRed: 195/255, green: 194/255, blue: 183/255, alpha: 1)
                              : NSColor(srgbRed: 82/255, green: 81/255, blue: 78/255, alpha: 1)
        let color = (active && isEnabled ? emphasized : muted).withAlphaComponent(isEnabled ? 1 : 0.3)
        if summary {
            NSColor.labelColor.withAlphaComponent(active && isEnabled ? 0.07 : (dark ? 0.055 : 0.035)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 4, yRadius: 4).fill()
            let text = "\(count) \(count == 1 ? "block" : "blocks") hidden" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            if (hovered || focused), bounds.width > 230 {
                let expand = "Expand" as NSString
                let size = expand.size(withAttributes: attrs)
                expand.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: (bounds.height - size.height) / 2), withAttributes: attrs)
            }
        } else if closed || headingHovered || active {
            if active && isEnabled {
                (dark ? NSColor.white : NSColor(srgbRed: 11/255, green: 11/255, blue: 11/255, alpha: 1))
                    .withAlphaComponent(dark ? 19/255 : 13/255).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            // Same 12-unit path, 10-point box and round stroke as the approved prototype.
            let path = NSBezierPath()
            for (index, point) in [NSPoint(x: 4, y: 2), NSPoint(x: 8, y: 6), NSPoint(x: 4, y: 10)].enumerated() {
                let oriented = closed ? point : NSPoint(x: 12 - point.y, y: point.x)
                let mapped = NSPoint(x: 7 + oriented.x * 10/12, y: 7 + oriented.y * 10/12)
                if index == 0 { path.move(to: mapped) } else { path.line(to: mapped) }
            }
            path.lineWidth = 1.25
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}
