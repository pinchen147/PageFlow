import AppKit
import MarkdownEngine

/// One native surface per displayed document; the empty overlay never owns events.
@MainActor
final class NavigationRailView: NSView {
    enum Kind { case pdf, markdown }
    private(set) var geometry = NavigationRailGeometry(totalRanks: 0, height: 0)
    private(set) var generation = 0
    private(set) var panel: NSView?
    private(set) var presentedTarget: NavigationRailTarget?
    var targetAtRank: ((Int) -> NavigationRailTarget?)?
    var makePreview: ((NavigationRailTarget) -> NSView?)?
    var updatePreview: ((NavigationRailTarget) -> Void)?
    var onActivate: ((NavigationRailTarget, Int) -> Void)?
    var onShowSidebar: (() -> Void)?
    var reservedNativeHit: ((NSPoint) -> NSView?)?
    var paintExclusions: (() -> [NSRect])?
    private(set) var kind: Kind = .pdf
    private(set) var eligible = false
    private var count = 0
    private var visible: Set<Int> = []
    private var identity: AnyHashable?
    private var topInset: CGFloat = 0
    private var hoveredRank: Int?
    private var pressed: (target: NavigationRailTarget, generation: Int)?
    private var requiresFreshEntry = false
    private var pointerInRegion = false
    private var exitWork: DispatchWorkItem?
    private var escapeMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuTracking = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        eligible && !geometry.marks.isEmpty && !isHiddenOrHasHiddenAncestor
            && window?.canBecomeKey == true
    }
    // Clicks preserve editor input; keyboard traversal can still focus the rail.
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show document sidebar")
        setAccessibilityHelp("Open the sidebar for exact document navigation")
    }
    required init?(coder: NSCoder) { nil }

    deinit {
        exitWork?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func configure(kind: Kind, count: Int, visible: Set<Int>, identity: AnyHashable,
                   eligible: Bool, topInset: CGFloat) {
        let changed = self.kind != kind || self.count != count || self.identity != identity
            || self.eligible != eligible || self.topInset != topInset
        self.kind = kind
        self.count = count
        self.visible = visible
        self.identity = identity
        self.eligible = eligible
        self.topInset = topInset
        if changed { invalidate() }
        geometry = NavigationRailGeometry(totalRanks: eligible ? count : 0, height: bounds.height, topInset: topInset)
        isHidden = !eligible
        setAccessibilityElement(eligible && count > 0)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func invalidate() {
        generation &+= 1
        requiresFreshEntry = requiresFreshEntry || pointerInRegion || pointerIsInLane
        pressed = nil
        closePreview()
    }

    /// Dismantling retires callbacks as well as presentation, even if a client still
    /// holds the former accessibility element until its next refresh.
    func retire() {
        eligible = false
        isHidden = true
        invalidate()
        removeObservers()
        makePreview = nil
        onActivate = nil
        onShowSidebar = nil
        targetAtRank = nil
        reservedNativeHit = nil
        paintExclusions = nil
    }

    private var lane: NSRect {
        NSRect(x: 0, y: min(bounds.height, max(0, topInset)), width: min(44, bounds.width),
               height: max(0, bounds.height - topInset))
    }
    private var pointerIsInLane: Bool {
        guard let window else { return false }
        return lane.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            invalidate()
            geometry = NavigationRailGeometry(totalRanks: eligible ? count : 0, height: bounds.height, topInset: topInset)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidate()
        removeObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        })
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel != nil, let window = self.window,
                      !self.combinedRegionContains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
                self.scheduleExit()
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard eligible, !isHiddenOrHasHiddenAncestor, window != nil else { return nil }
        let local = convert(point, from: superview)
        if let panel, panel.frame.contains(local) { return panel.hitTest(local) ?? panel }
        guard !geometry.marks.isEmpty, lane.contains(local), reservedNativeHit?(convert(local, to: nil)) == nil else { return nil }
        return self
    }

    override func accessibilityFrame() -> NSRect {
        guard eligible, let window else { return .zero }
        return window.convertToScreen(convert(lane, to: nil))
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        guard eligible, let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: point)
        let local = convert(windowPoint, from: nil)
        if let panel, panel.frame.contains(local) { return panel.accessibilityHitTest(point) }
        guard lane.contains(local), reservedNativeHit?(windowPoint) == nil else { return nil }
        return self
    }

    override func resetCursorRects() {
        guard eligible else { return }
        // Cursor admission is decided at the actual native point; fold/grip cursors win.
        if pointerIsInLane, let window, reservedNativeHit?(window.mouseLocationOutsideOfEventStream) == nil {
            addCursorRect(lane, cursor: .pointingHand)
        }
    }

    override func mouseEntered(with event: NSEvent) { trackCurrentPointer() }
    override func mouseMoved(with event: NSEvent) { trackCurrentPointer() }
    override func mouseExited(with event: NSEvent) { trackCurrentPointer() }
    override func mouseDragged(with event: NSEvent) { pressed = nil; closePreview() }

    private func trackCurrentPointer() {
        guard let window else { return }
        pointerMoved(to: convert(window.mouseLocationOutsideOfEventStream, from: nil),
                     dragging: NSEvent.pressedMouseButtons != 0)
    }

    func pointerMoved(to point: NSPoint, dragging: Bool = false) {
        let inside = combinedRegionContains(point)
        pointerInRegion = inside
        if !inside {
            requiresFreshEntry = false
            hoveredRank = nil
            needsDisplay = true
            scheduleExit()
            return
        }
        exitWork?.cancel()
        exitWork = nil
        guard eligible, window?.isKeyWindow == true, !dragging, !requiresFreshEntry,
              !isHiddenOrHasHiddenAncestor, !geometry.marks.isEmpty else { return }
        if panel?.frame.contains(point) == true { return }
        guard lane.contains(point) else { return }
        guard reservedNativeHit?(convert(point, to: nil)) == nil else {
            if kind == .markdown && panelOwnsInteraction { return }
            window?.invalidateCursorRects(for: self)
            closePreview()
            return
        }
        guard let rank = geometry.representative(at: point.y), let target = target(for: rank) else { return }
        // Native pointer events often repeat within the same marker. Avoid
        // repaint, cursor resets and accessibility traversal until it changes.
        if hoveredRank == rank, presentedTarget == target, panel != nil { return }
        // Passive movement cannot replace or dismiss a card being used through
        // the keyboard or accessibility. Explicit commands still supersede it.
        if kind == .markdown && panelOwnsInteraction { return }
        hoveredRank = rank
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        present(target, at: rank)
    }

    private func target(for rank: Int) -> NavigationRailTarget? {
        if let targetAtRank { return targetAtRank(rank) }
        return kind == .pdf ? .page(rank) : nil
    }

    private func combinedRegionContains(_ point: NSPoint) -> Bool {
        if lane.contains(point) { return true }
        guard let panel else { return false }
        let bridge = NSRect(x: lane.maxX, y: panel.frame.minY, width: max(0, panel.frame.minX - lane.maxX), height: panel.frame.height)
        return panel.frame.contains(point) || bridge.contains(point)
    }

    private func present(_ target: NavigationRailTarget, at rank: Int) {
        if presentedTarget == target, panel != nil { return }
        // Keep the lazy PDF grid mounted while revealing each hovered page.
        if kind == .pdf, panel != nil {
            presentedTarget = target
            updatePreview?(target)
            return
        }
        guard let next = makePreview?(target) else { closePreview(); return }
        panel?.removeFromSuperview()
        panel = next
        presentedTarget = target
        let x = min(52, max(0, bounds.width - 24))
        let width = max(0, min(kind == .pdf ? DesignTokens.sidebarWidth : 352, bounds.width - x - 12))
        let available = max(0, bounds.height - topInset - 24)
        let height = kind == .pdf ? available : min(104, available)
        let y = kind == .pdf ? topInset + 12 : max(topInset + 12, min(bounds.height - height - 12,
            (geometry.marks.first { $0.representative == rank }?.y ?? topInset) - height / 2))
        next.frame = NSRect(x: x, y: y, width: width, height: height)
        addSubview(next)
        installEscapeMonitor()
    }

    private func scheduleExit() {
        guard panel != nil, exitWork == nil else { return }
        let expected = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, let window = self.window else { return }
            self.exitWork = nil
            guard !self.combinedRegionContains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                  !self.panelOwnsInteraction else { return }
            self.closePreview()
        }
        exitWork = work
        // Defer one main-queue turn to tolerate interleaved native tracking
        // callbacks, then check the live combined region without a linger timer.
        DispatchQueue.main.async(execute: work)
    }

    private var panelOwnsInteraction: Bool {
        guard let panel else { return false }
        func contains(_ view: NSView) -> Bool { view === panel || view.isDescendant(of: panel) }
        if let responder = window?.firstResponder as? NSView {
            if contains(responder) { return true }
            if let fieldEditor = responder as? NSTextView, fieldEditor.isFieldEditor,
               let control = fieldEditor.delegate as? NSView, contains(control) { return true }
        }
        // SwiftUI can expose virtual accessibility nodes, so follow their parents
        // instead of requiring the focused element itself to be an NSView.
        var focused = NSApp.accessibilityApplicationFocusedUIElement()
        for _ in 0..<32 {
            if let view = focused as? NSView, contains(view) { return true }
            guard let element = focused as? any NSAccessibilityProtocol else { return false }
            focused = element.accessibilityParent()
        }
        return false
    }

    private func closePreview() {
        exitWork?.cancel()
        exitWork = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        panel?.removeFromSuperview()
        panel = nil
        updatePreview = nil
        presentedTarget = nil
        hoveredRank = nil
        needsDisplay = true
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window, event.keyCode == 53,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
                return self.handleEscape()
            }
            return consumed ? nil : event
        }
    }

    @discardableResult
    func handleEscape() -> Bool {
        guard panel != nil, window?.isKeyWindow == true, !menuTracking else { return false }
        if let input = window?.firstResponder as? NSTextInputClient, input.hasMarkedText() { return false }
        requiresFreshEntry = true
        pressed = nil
        closePreview()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard eligible, window?.isKeyWindow == true, lane.contains(point),
              reservedNativeHit?(event.locationInWindow) == nil,
              let rank = geometry.representative(at: point.y), let target = target(for: rank) else { return }
        requiresFreshEntry = false
        present(target, at: rank)
        // Retain the exact immutable value shown at press time, not a later rank lookup.
        pressed = (target, generation)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, pressed.generation == generation, eligible,
              window?.isKeyWindow == true, lane.contains(convert(event.locationInWindow, from: nil)),
              reservedNativeHit?(event.locationInWindow) == nil else { return }
        onActivate?(pressed.target, pressed.generation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard eligible, window != nil, !isHiddenOrHasHiddenAncestor, let onShowSidebar else { return false }
        closePreview()
        onShowSidebar()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard eligible else { return }
        let exclusions = paintExclusions?() ?? []
        let hoveredIndex = hoveredRank.flatMap { rank in geometry.marks.firstIndex { $0.representative == rank } }
        for (index, mark) in geometry.marks.enumerated() {
            let active = mark.isActive(visible)
            var length: CGFloat = kind == .pdf ? (active ? 18 : 12) : 6
            if kind == .markdown {
                if case .section(let section) = targetAtRank?(mark.representative) {
                    length = CGFloat(24 - 3 * section.level)
                }
                if let hoveredIndex {
                    let distance = abs(index - hoveredIndex)
                    if distance < 5 { length = max(length, [28, 22, 16, 11, 8][distance]) }
                }
            }
            (active || index == hoveredIndex ? NSColor.labelColor : NSColor.tertiaryLabelColor).setFill()
            var pieces = [NSRect(x: 12, y: mark.y - 1, width: length, height: 2)]
            // Subtract each native control conservatively. Unlike an even-odd clip,
            // overlapping controls cannot put rail ink back over a native glyph.
            for exclusion in exclusions {
                pieces = pieces.flatMap { piece in
                    guard piece.intersects(exclusion) else { return [piece] }
                    var remainder: [NSRect] = []
                    if piece.minX < exclusion.minX {
                        remainder.append(NSRect(x: piece.minX, y: piece.minY, width: exclusion.minX - piece.minX, height: 2))
                    }
                    if piece.maxX > exclusion.maxX {
                        remainder.append(NSRect(x: exclusion.maxX, y: piece.minY, width: piece.maxX - exclusion.maxX, height: 2))
                    }
                    return remainder
                }
            }
            for piece in pieces { NSBezierPath(roundedRect: piece, xRadius: 1, yRadius: 1).fill() }
        }
    }
}

enum NavigationRailTarget: Hashable {
    case page(Int)
    case section(MarkdownSectionTarget)
}
