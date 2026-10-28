import AppKit
import Testing
@testable import PageFlow

@Suite("Navigation rail geometry")
struct NavigationRailGeometryTests {
    @Test("Ranks remain finite and bounded at empty, compact and large document sizes",
          arguments: [0, 1, 20_000], [0.0, 10.0, 80.0, 600.0, 10_000.0])
    func boundedGeometry(count: Int, height: Double) {
        let geometry = NavigationRailGeometry(totalRanks: count, height: height)
        if count == 0 || height < 40 { #expect(geometry.marks.isEmpty); return }
        #expect(!geometry.marks.isEmpty)
        #expect(geometry.marks.count <= 256)
        #expect(geometry.marks.first?.ranks.lowerBound == 0)
        #expect(geometry.marks.last?.ranks.upperBound == count)
        #expect(geometry.marks.allSatisfy { $0.y.isFinite && $0.y >= 20 && $0.y <= height - 20 })
        for pair in zip(geometry.marks, geometry.marks.dropFirst()) {
            #expect(pair.1.y - pair.0.y >= 4)
            #expect(pair.0.ranks.upperBound == pair.1.ranks.lowerBound)
        }
    }

    @Test("Preferred pitch, compressed pitch and first-member group targets are stable")
    func rankTargets() throws {
        let compact = NavigationRailGeometry(totalRanks: 3, height: 600, topInset: 60)
        #expect(compact.marks.map(\.y) == [80, 91, 102])
        let compressed = NavigationRailGeometry(totalRanks: 20, height: 140)
        #expect(compressed.marks.count == 20)
        #expect(compressed.marks.last?.y == 120)
        let grouped = NavigationRailGeometry(totalRanks: 20_000, height: 600)
        for mark in grouped.marks {
            #expect(grouped.representative(at: mark.y) == mark.ranks.lowerBound)
            #expect(mark.isActive([mark.ranks.upperBound - 1]))
            #expect(mark.isActive(Set(mark.ranks)))
            #expect(!mark.isActive([20_001]))
        }
        #expect(NavigationRailGeometry(totalRanks: 20_000, height: 300) != grouped)
        #expect(grouped.representative(at: -100) == grouped.marks.first?.representative)
        #expect(grouped.representative(at: 2000) == grouped.marks.last?.representative)
    }
}

@MainActor
@Suite("Mounted navigation rail", .serialized)
struct NavigationRailTests {
    private final class TrackingWindow: NSWindow {
        var replayedPointer = NSPoint(x: 600, y: 300)
        private(set) var keyResignations = 0
        override var mouseLocationOutsideOfEventStream: NSPoint { replayedPointer }
        override func resignKey() { keyResignations += 1; super.resignKey() }
    }

    private func mount() async throws -> (NSWindow, NavigationRailView, NSTextView) {
        let window = TrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let native = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(native)
        let rail = NavigationRailView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(rail)
        rail.makePreview = { _ in NSView(frame: NSRect(x: 0, y: 0, width: 352, height: 104)) }
        rail.configure(kind: .pdf, count: 100, visible: [2], identity: "doc", eligible: true, topInset: 60)
        var stableGeneration: Int?
        var settled = false
        for _ in 0..<60 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            // Key status can be true synchronously while AppKit still has an
            // activation/attachment transition queued. Require a settled turn.
            try await Task.sleep(for: .milliseconds(50))
            if window.isKeyWindow, stableGeneration == rail.generation { settled = true; break }
            stableGeneration = window.isKeyWindow ? rail.generation : nil
        }
        try #require(settled, "Mounted fixture must establish stable native key-window ownership")
        window.makeFirstResponder(native)
        window.contentView?.layoutSubtreeIfNeeded()
        rail.pointerMoved(to: NSPoint(x: 500, y: 500))
        return (window, rail, native)
    }

    private func event(_ type: NSEvent.EventType, in rail: NavigationRailView, point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: rail.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: rail.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @Test("Blank overlay passes through; rail and actual panel alone receive hits without focus theft")
    func nativeHitsAndBridge() async throws {
        let (window, rail, native) = try await mount()
        defer { window.close() }
        let parent = try #require(rail.superview)
        #expect(rail.hitTest(parent.convert(NSPoint(x: 500, y: 300), from: rail)) == nil)
        #expect(rail.accessibilityFrame().width == 44)
        #expect(rail.accessibilityHitTest(window.convertPoint(toScreen: rail.convert(NSPoint(x: 500, y: 300), to: nil))) == nil)
        let point = NSPoint(x: 20, y: 100)
        #expect(rail.hitTest(parent.convert(point, from: rail)) === rail)
        rail.pointerMoved(to: point)
        let panel = try #require(rail.panel)
        #expect(window.firstResponder === native)
        #expect(rail.hitTest(parent.convert(NSPoint(x: 48, y: panel.frame.midY), from: rail)) == nil)
        rail.pointerMoved(to: NSPoint(x: 48, y: panel.frame.midY))
        #expect(rail.panel === panel)
        rail.pointerMoved(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        #expect(rail.panel === panel)
        #expect(rail.hitTest(parent.convert(NSPoint(x: panel.frame.midX, y: panel.frame.midY), from: rail)) === panel)
        #expect(window.firstResponder === native)
    }

    @Test("Keyboard traversal and Space or Return still open the exact-access sidebar",
          arguments: [UInt16(49), UInt16(36)])
    func keyboardSidebar(keyCode: UInt16) async throws {
        let (window, rail, native) = try await mount()
        defer { native.nextKeyView = nil; rail.nextKeyView = nil; window.close() }
        var opened = 0
        rail.onShowSidebar = { opened += 1 }
        window.autorecalculatesKeyViewLoop = false
        native.nextKeyView = rail
        rail.nextKeyView = native
        #expect(rail.canBecomeKeyView)
        #expect(native.nextValidKeyView === rail)
        window.selectKeyView(following: native)
        try #require(window.firstResponder === rail)
        let characters = keyCode == 49 ? " " : "\r"
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode))
        window.sendEvent(key)
        #expect(opened == 1)
        #expect(native.string.isEmpty)
    }

    @Test("Unavailable rails stay outside the native keyboard loop")
    func unavailableKeyboardTargets() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let parent = NSView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(parent)
        let rail = NavigationRailView(frame: parent.bounds)
        parent.addSubview(rail)
        rail.configure(kind: .pdf, count: 100, visible: [], identity: "doc", eligible: true, topInset: 0)
        #expect(rail.canBecomeKeyView)
        parent.isHidden = true
        #expect(!rail.canBecomeKeyView)
        parent.isHidden = false
        rail.configure(kind: .pdf, count: 100, visible: [], identity: "doc", eligible: false, topInset: 0)
        #expect(!rail.canBecomeKeyView)
        rail.configure(kind: .pdf, count: 0, visible: [], identity: "doc", eligible: true, topInset: 0)
        #expect(!rail.canBecomeKeyView)
        rail.configure(kind: .pdf, count: 100, visible: [], identity: "doc", eligible: true, topInset: 0)
        rail.setFrameSize(NSSize(width: 800, height: 10))
        #expect(!rail.canBecomeKeyView)
        rail.setFrameSize(parent.bounds.size)
        #expect(rail.canBecomeKeyView)
        rail.removeFromSuperview()
        #expect(!rail.canBecomeKeyView)
    }

    @Test("Escape and policy invalidation require fresh entry and leave exact-access sidebar available")
    func dismissalAndEligibility() async throws {
        let (window, rail, native) = try await mount()
        defer { window.close() }
        var opened = 0
        rail.onShowSidebar = { opened += 1 }
        let point = NSPoint(x: 20, y: 100)
        rail.pointerMoved(to: point)
        #expect(rail.handleEscape())
        rail.pointerMoved(to: point)
        #expect(rail.panel == nil)
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.pointerMoved(to: point)
        #expect(rail.panel != nil)
        rail.configure(kind: .pdf, count: 100, visible: [2], identity: "doc", eligible: false, topInset: 60)
        #expect(rail.panel == nil)
        rail.configure(kind: .pdf, count: 100, visible: [2], identity: "doc", eligible: true, topInset: 60)
        rail.pointerMoved(to: point)
        #expect(rail.panel == nil)
        #expect(rail.accessibilityPerformPress())
        #expect(opened == 1)
        #expect(window.firstResponder === native)
    }

    @Test("Mouse-up retains the pressed token and rejects resize, replacement and eligibility races",
          arguments: ["none", "resize", "replace", "disable"])
    func pressedIdentity(reason: String) async throws {
        let (window, rail, _) = try await mount()
        defer { window.close() }
        var activated: [NavigationRailTarget] = []
        rail.onActivate = { target, _ in activated.append(target) }
        let point = NSPoint(x: 20, y: 100)
        rail.pointerMoved(to: point)
        let shown = try #require(rail.presentedTarget)
        rail.mouseDown(with: try event(.leftMouseDown, in: rail, point: point))
        switch reason {
        case "resize": rail.setFrameSize(NSSize(width: 700, height: 300))
        case "replace": rail.configure(kind: .pdf, count: 100, visible: [2], identity: "new", eligible: true, topInset: 60)
        case "disable": rail.configure(kind: .pdf, count: 100, visible: [2], identity: "doc", eligible: false, topInset: 60)
        default: break
        }
        rail.mouseUp(with: try event(.leftMouseUp, in: rail, point: point))
        #expect(activated == (reason == "none" ? [shown] : []))
    }

    @Test("Drag and nonkey windows cannot open; source refresh closes stale cards; detached hosts release")
    func ownership() async throws {
        let (window, rail, _) = try await mount()
        defer { window.close() }
        rail.pointerMoved(to: NSPoint(x: 20, y: 100), dragging: true)
        #expect(rail.panel == nil)
        let other = NSWindow(contentRect: NSRect(x: 800, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        other.makeKey()
        for _ in 0..<100 where !other.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        #expect(other.isKeyWindow)
        rail.pointerMoved(to: NSPoint(x: 20, y: 100))
        #expect(rail.panel == nil)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        for _ in 0..<100 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.pointerMoved(to: NSPoint(x: 20, y: 100))
        #expect(rail.panel != nil)
        var sidebarOpens = 0
        rail.onShowSidebar = { sidebarOpens += 1 }
        rail.removeFromSuperview()
        #expect(rail.panel == nil)
        #expect(rail.presentedTarget == nil)
        #expect(!rail.accessibilityPerformPress())
        #expect(sidebarOpens == 0)
    }

    private final class CallbackOwner {
        let didCall: () -> Void
        init(didCall: @escaping () -> Void) { self.didCall = didCall }
    }

    private final class WeakCallbackOwner {
        weak var value: CallbackOwner?
        var isReleased: Bool { value == nil }
    }

    /// The helper's scope owns no reference after returning. Only the rail's
    /// production callbacks (and the deliberate negative control) retain it.
    private func installOwnedCallbacks(on rail: NavigationRailView,
                                       didCall: @escaping () -> Void) -> WeakCallbackOwner {
        let owner = CallbackOwner(didCall: didCall)
        let observation = WeakCallbackOwner()
        observation.value = owner
        rail.targetAtRank = { rank in owner.didCall(); return .page(rank) }
        rail.makePreview = { _ in
            owner.didCall()
            return NSView(frame: NSRect(x: 0, y: 0, width: 352, height: 104))
        }
        rail.updatePreview = { _ in owner.didCall() }
        rail.onActivate = { _, _ in owner.didCall() }
        rail.onShowSidebar = { owner.didCall() }
        rail.reservedNativeHit = { _ in owner.didCall(); return nil }
        rail.paintExclusions = { owner.didCall(); return [] }
        return observation
    }

    @Test("Marked input and queued dismissal survive until retirement clears presentation and callback ownership",
          arguments: [false, true])
    func dismissalAndComposition(retainingCallback: Bool) async throws {
        // Keep the native rail alive: retirement must release app ownership even
        // when AppKit or accessibility still holds the former native shell.
        let (window, rail, native) = try await mount()
        defer { window.close() }
        let replay = try #require(window as? TrackingWindow)
        let parent = try #require(rail.superview)
        var calls = 0
        let observation = installOwnedCallbacks(on: rail) { calls += 1 }
        try #require(!observation.isReleased)
        var retainedCallback = retainingCallback ? rail.onShowSidebar : nil
        let point = NSPoint(x: 20, y: 100)
        let outside = NSPoint(x: 500, y: 300)
        let hitPoint = parent.convert(point, from: rail)
        let screenPoint = window.convertPoint(toScreen: rail.convert(point, to: nil))
        let mouseUp = try event(.leftMouseUp, in: rail, point: point)
        replay.replayedPointer = rail.convert(point, to: nil)
        rail.pointerMoved(to: point)
        let panel = try #require(rail.panel)
        try #require(rail.presentedTarget != nil)

        native.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        try #require(native.hasMarkedText())
        #expect(!rail.handleEscape())
        #expect(rail.panel === panel)
        #expect(window.firstResponder === native)
        native.unmarkText()
        replay.replayedPointer = rail.convert(outside, to: nil)
        rail.pointerMoved(to: outside)
        #expect(rail.panel === panel)
        replay.replayedPointer = rail.convert(point, to: nil)
        rail.pointerMoved(to: point)
        await nextMainTurn()
        try #require(window.isKeyWindow)
        #expect(rail.panel === panel, "Re-entry must cancel the queued exit")

        // Leave both a pressed target and an exit callback pending at teardown.
        rail.mouseDown(with: try event(.leftMouseDown, in: rail, point: point))
        replay.replayedPointer = rail.convert(outside, to: nil)
        rail.pointerMoved(to: outside)
        let callsBeforeRetirement = calls
        rail.retire()
        #expect(rail.panel == nil)
        #expect(panel.superview == nil)
        #expect(rail.presentedTarget == nil)
        #expect(window.firstResponder === native)
        #expect(rail.hitTest(hitPoint) == nil)
        #expect(rail.accessibilityHitTest(screenPoint) == nil)
        #expect(rail.accessibilityFrame() == .zero)
        #expect(!rail.canBecomeKeyView)
        #expect(!rail.accessibilityPerformPress())
        withExtendedLifetime(retainedCallback) {
            #expect(observation.isReleased == !retainingCallback,
                    "The same release predicate must detect an externally retained production callback")
        }
        retainedCallback = nil
        #expect(observation.isReleased)

        rail.removeFromSuperview()
        rail.pointerMoved(to: point)
        rail.mouseUp(with: mouseUp)
        #expect(!rail.handleEscape())
        #expect(!rail.accessibilityPerformPress())
        window.update()
        await nextMainTurn()
        #expect(rail.panel == nil)
        #expect(rail.presentedTarget == nil)
        #expect(rail.hitTest(hitPoint) == nil)
        #expect(rail.accessibilityHitTest(screenPoint) == nil)
        #expect(window.firstResponder === native)
        #expect(calls == callsBeforeRetirement, "Late native work must not invoke retired callbacks")
        #expect(observation.isReleased)
    }

    @Test("Tracking callbacks preserve bridge travel and promptly dismiss departed passive previews",
          arguments: ["pdf", "markdown"])
    func trackingAndPromptExit(kind: String) async throws {
        let (window, rail, native) = try await mount()
        defer { window.close() }
        let replay = try #require(window as? TrackingWindow)
        rail.configure(kind: kind == "pdf" ? .pdf : .markdown, count: 100, visible: [0],
                       identity: kind, eligible: true, topInset: 60)
        rail.targetAtRank = { .page($0) }
        rail.pointerMoved(to: NSPoint(x: 600, y: 300))
        let staleEvent = try #require(NSEvent.enterExitEvent(with: .mouseEntered,
            location: rail.convert(NSPoint(x: 700, y: 500), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        replay.replayedPointer = rail.convert(NSPoint(x: 20, y: 100), to: nil)
        rail.mouseEntered(with: staleEvent)
        let panel = try #require(rail.panel)
        let generation = rail.generation
        let bridge = NSPoint(x: 48, y: panel.frame.midY)
        replay.replayedPointer = rail.convert(bridge, to: nil)
        rail.mouseExited(with: staleEvent)
        await nextMainTurn()
        #expect(window.isKeyWindow)
        #expect(rail.generation == generation)
        #expect(rail.panel === panel)
        replay.replayedPointer = rail.convert(NSPoint(x: panel.frame.midX, y: panel.frame.midY), to: nil)
        rail.mouseMoved(with: staleEvent)
        #expect(rail.panel === panel)

        // Interleaved native callbacks can briefly report departure before the
        // next callback observes the current pointer back over the bridge.
        replay.replayedPointer = rail.convert(NSPoint(x: 600, y: 300), to: nil)
        rail.mouseExited(with: staleEvent)
        replay.replayedPointer = rail.convert(bridge, to: nil)
        rail.mouseEntered(with: staleEvent)
        await nextMainTurn()
        #expect(rail.panel === panel)

        replay.replayedPointer = rail.convert(NSPoint(x: 600, y: 300), to: nil)
        rail.mouseExited(with: staleEvent)
        await nextMainTurn()
        #expect(rail.panel == nil, "A passive preview must not deliberately linger after confirmed departure")
        #expect(window.firstResponder === native)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Keyboard interaction holds the preview until focus leaves its panel",
          arguments: ["pdf", "markdown"])
    func panelKeyboardLifetime(kind: String) async throws {
        let (window, rail, native) = try await mount()
        defer { window.close() }
        let replay = try #require(window as? TrackingWindow)
        rail.configure(kind: kind == "pdf" ? .pdf : .markdown, count: 100, visible: [0],
                       identity: kind, eligible: true, topInset: 60)
        rail.targetAtRank = { .page($0) }
        rail.pointerMoved(to: NSPoint(x: 600, y: 300))
        rail.makePreview = { _ in NSTextView(frame: NSRect(x: 0, y: 0, width: 352, height: 104)) }
        rail.pointerMoved(to: NSPoint(x: 20, y: 100))
        let panel = try #require(rail.panel)
        #expect(window.makeFirstResponder(panel))
        replay.replayedPointer = rail.convert(NSPoint(x: 600, y: 300), to: nil)
        rail.pointerMoved(to: NSPoint(x: 600, y: 300))
        await nextMainTurn()
        #expect(window.isKeyWindow)
        #expect(rail.panel === panel)
        #expect(window.makeFirstResponder(native))
        window.update()
        await nextMainTurn()
        #expect(rail.panel == nil)
    }

    @Test("Passive Markdown hover preserves the interaction-owned card across ranks and native controls")
    func interactionOwnedMarkdownHover() async throws {
        let (window, rail, native) = try await mount()
        defer { window.close() }
        rail.configure(kind: .markdown, count: 100, visible: [0], identity: "sections", eligible: true, topInset: 60)
        rail.targetAtRank = { .page($0) }
        rail.makePreview = { _ in NSTextView(frame: NSRect(x: 0, y: 0, width: 352, height: 104)) }
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.pointerMoved(to: NSPoint(x: 20, y: 100))
        let panel = try #require(rail.panel)
        let target = try #require(rail.presentedTarget)
        #expect(window.makeFirstResponder(panel))
        rail.pointerMoved(to: NSPoint(x: 20, y: 400))
        #expect(rail.panel === panel)
        #expect(rail.presentedTarget == target)
        #expect(window.firstResponder === panel)
        rail.reservedNativeHit = { _ in native }
        rail.pointerMoved(to: NSPoint(x: 20, y: 200))
        #expect(rail.panel === panel)
        #expect(rail.presentedTarget == target)
        rail.reservedNativeHit = nil
        let pressedPoint = NSPoint(x: 20, y: 400)
        rail.mouseDown(with: try event(.leftMouseDown, in: rail, point: pressedPoint))
        #expect(rail.panel !== panel)
        #expect(rail.presentedTarget != target)
        let replacement = try #require(rail.panel)
        #expect(window.makeFirstResponder(replacement))
        #expect(rail.handleEscape())
        #expect(rail.panel == nil)
    }

}
