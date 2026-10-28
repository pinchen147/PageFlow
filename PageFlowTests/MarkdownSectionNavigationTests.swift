import AppKit
import SwiftUI
@testable import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
@Suite("Markdown rail integration", .serialized)
struct MarkdownSectionNavigationTests {
    @MainActor
    private final class Mounted {
        let content = MarkdownContent(documentId: UUID().uuidString)
        let window: NSWindow
        let container: MarkdownEditorSurfaceContainer
        var editor: MarkdownEditorView {
            MarkdownEditorView(text: Binding(get: { [weak self] in self?.content.documentManager.text ?? "" },
                set: { [weak self] in self?.content.documentManager.text = $0 }), documentId: content.documentId,
                editorController: content.editorController, bus: content.bus, isDisplayed: true, isFocused: true,
                undoManager: content.undoManager)
        }
        init(attach: Bool = true, source: String? = nil, height: CGFloat = 500) {
            content.documentManager.text = source ?? ("# First\nneedle\n" + String(repeating: "body paragraph\n\n", count: 100) + "# Last\ntail\n")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            container = MarkdownEditorSurfaceContainer(frame: window.contentView!.bounds)
            if attach { window.contentView = container }
            container.reconcile(content: content, editor: editor)
            if attach { window.makeKeyAndOrderFront(nil) }
            container.layoutSubtreeIfNeeded()
        }
        var native: NSTextView {
            func find(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                for child in view.subviews { if let text = find(child) { return text } }
                return nil
            }
            return find(content.retainedEditorSurface!.nativeView)!
        }
        var coordinator: NativeTextViewCoordinator { native.delegate as! NativeTextViewCoordinator }
        func close() { content.cleanup(); window.close() }
    }

    @Test("Back leaves both stacks untouched until native input settles and uses execution-time departure")
    func protectedHistory() async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(100))
        let content = mounted.content
        content.scrollToLine(190)
        let trail = content.navigationTrail
        #expect(trail.canGoBack)
        mounted.coordinator.textViewWritingToolsWillBegin(mounted.native)
        content.goBack()
        #expect(content.navigationTrail == trail)
        content.editorController.scroll(toOffset: 600)
        let departure = try #require(content.editorController.readingPosition)
        mounted.coordinator.textViewWritingToolsDidEnd(mounted.native)
        #expect(!content.canGoBack)
        #expect(content.navigationTrail.forwardStack.last == departure)
        content.goForward()
        #expect(content.canGoBack)
        #expect(!content.canGoForward)
    }

    @Test("Cancelled Back preserves history across hide, window transfer and superseding Find", arguments: ["hide", "transfer", "find"])
    func cancelledHistory(reason: String) async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(100))
        let content = mounted.content
        content.scrollToLine(190)
        let trail = content.navigationTrail
        mounted.coordinator.textViewWritingToolsWillBegin(mounted.native)
        content.goBack()
        let other = NSWindow(contentRect: mounted.window.frame, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        switch reason {
        case "hide":
            var editor = mounted.editor
            editor.isDisplayed = false
            mounted.container.reconcile(content: content, editor: editor)
            mounted.container.reconcile(content: content, editor: mounted.editor)
        case "transfer":
            let destination = MarkdownEditorSurfaceContainer(frame: mounted.container.frame)
            other.contentView = destination
            destination.reconcile(content: content, editor: mounted.editor)
        default: content.searchManager.clear()
        }
        mounted.coordinator.textViewWritingToolsDidEnd(mounted.native)
        #expect(content.navigationTrail == trail)
    }
    @Test("Native preview and activation share one canonical token and preserve input state")
    func railActivation() async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        NSApp.activate(ignoringOtherApps: true)
        mounted.window.makeKeyAndOrderFront(nil)
        mounted.window.makeKey()
        for _ in 0..<100 where !mounted.window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 0, onShowSidebar: {})
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        #expect(mounted.window.isKeyWindow)
        let snapshot = try #require(mounted.content.editorController.sectionNavigationSnapshot)
        let target = try #require(snapshot.targets.last)
        let point = NSPoint(x: 12, y: try #require(rail.geometry.marks.last).y)
        mounted.native.setSelectedRange(NSRange(location: 2, length: 3))
        let selection = mounted.native.selectedRanges
        let source = mounted.native.string
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        #expect(mounted.container.nativeControl(at: rail.convert(point, to: nil)) == nil)
        #expect(mounted.content.editorController.sectionPreview(for: target) != nil)
        rail.pointerMoved(to: point)
        #expect(rail.presentedTarget == .section(target))
        #expect(rail.panel is MarkdownSectionPreviewView)
        #expect(mounted.native.selectedRanges == selection)
        #expect(!mounted.content.canGoBack)
        let departure = try #require(mounted.content.editorController.readingPosition)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: rail.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        rail.mouseDown(with: down)
        rail.mouseUp(with: up)
        #expect(mounted.content.navigationTrail.backStack == [departure])
        #expect(mounted.native.string == source)
        #expect(mounted.native.selectedRanges == selection)
        #expect(!mounted.content.undoManager.canUndo)
        let generation = rail.generation
        mounted.content.editorController.scroll(toOffset: 0)
        #expect(rail.generation == generation)
        mounted.container.configureNavigationRail(content: mounted.content, eligible: false, topInset: 0, onShowSidebar: {})
        #expect(rail.panel == nil)
        #expect(mounted.content.editorController.sectionNavigationSnapshot == nil)
    }

    @Test("Existing native controls win lane hits and exclude their actual bounds from paint")
    func nativeControlPriority() async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        try await Task.sleep(for: .milliseconds(100))
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 0, onShowSidebar: {})
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        let exclusions = mounted.container.nativeControlRects(in: rail).filter { $0.intersects(NSRect(x: 0, y: 0, width: 44, height: 500)) }
        let rect = try #require(exclusions.first)
        let point = NSPoint(x: min(43, rect.midX), y: rect.midY)
        let windowPoint = rail.convert(point, to: nil)
        let native = try #require(mounted.container.nativeControl(at: windowPoint))
        let hit = mounted.container.hitTest(mounted.container.superview?.convert(windowPoint, from: nil) ?? windowPoint)
        #expect(hit === native)
        #expect(rail.hitTest(mounted.container.convert(point, from: rail)) == nil)
        rail.pointerMoved(to: point)
        #expect(rail.panel == nil)
    }

    @Test("Committed publication removes the rail without re-entering the producer during invalidation")
    func committedPublication() throws {
        let mounted = Mounted()
        defer { mounted.close() }
        let controller = mounted.content.editorController
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 60, onShowSidebar: {})
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        let initial = try #require(controller.sectionNavigationSnapshot)
        try #require(initial.targets.count == 2 && rail.eligible && rail.superview === mounted.container)
        let apply = try #require(controller.onSectionNavigationChange)
        var publications: [MarkdownSectionNavigationSnapshot?] = []
        controller.onSectionNavigationChange = { committed in
            publications.append(committed)
            apply(committed)
        }
        // Lifecycle retirement publishes nil before it clears the old parse receipt.
        // The editor stays mounted and enabled, so a producer read would repopulate it.
        mounted.coordinator.invalidateSectionNavigation()
        #expect(publications == [nil])
        #expect(mounted.coordinator.sectionNavigationState.snapshot == nil)
        #expect(!rail.eligible)
        #expect(rail.superview == nil)
        mounted.coordinator.refreshSectionNavigation()
        #expect(publications.count == 2)
        let committed = try #require(publications.last.flatMap { $0 })
        #expect(committed.targets.map(\.title) == ["First", "Last"])
        #expect(rail.eligible && rail.superview === mounted.container)
        #expect(rail.targetAtRank?(1) == .section(committed.targets[1]))
    }

    @Test("Publication starts when a preconfigured native host attaches to its window")
    func attachPublication() async throws {
        let mounted = Mounted(attach: false)
        defer { mounted.close() }
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 60, onShowSidebar: {})
        #expect(mounted.content.editorController.sectionNavigationSnapshot == nil)
        mounted.window.contentView = mounted.container
        mounted.window.makeKeyAndOrderFront(nil)
        for _ in 0..<50 where mounted.content.editorController.sectionNavigationSnapshot == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(mounted.content.editorController.sectionNavigationSnapshot?.targets.count == 2)
        #expect(mounted.container.navigationRailAdapter?.rail.window === mounted.window)
    }

    @Test("A stale card press cannot navigate after source replacement or protected-input disable", arguments: ["source", "disable"])
    func staleCard(reason: String) async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        NSApp.activate(ignoringOtherApps: true)
        mounted.window.makeKeyAndOrderFront(nil)
        mounted.window.makeKey()
        for _ in 0..<100 where !mounted.window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 60, onShowSidebar: {})
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.pointerMoved(to: NSPoint(x: 12, y: 400))
        let card = try #require(rail.panel as? MarkdownSectionPreviewView)
        let trail = mounted.content.navigationTrail
        if reason == "source" {
            mounted.content.documentManager.text = "# Replacement\nnew body"
            mounted.container.reconcile(content: mounted.content, editor: mounted.editor)
        } else {
            mounted.coordinator.textViewWritingToolsWillBegin(mounted.native)
            #expect(card.accessibilityPerformPress())
            #expect(mounted.content.navigationTrail == trail)
            mounted.container.configureNavigationRail(content: mounted.content, eligible: false, topInset: 60, onShowSidebar: {})
            mounted.coordinator.textViewWritingToolsDidEnd(mounted.native)
        }
        _ = card.accessibilityPerformPress()
        #expect(mounted.content.navigationTrail == trail)
        #expect(rail.panel == nil)
    }

    @Test("Rail and an already open card follow the forced document appearance independently of the window")
    func forcedAppearance() async throws {
        let mounted = Mounted()
        defer { mounted.close() }
        NSApp.activate(ignoringOtherApps: true)
        mounted.window.makeKeyAndOrderFront(nil)
        mounted.window.makeKey()
        for _ in 0..<100 where !mounted.window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }
        mounted.window.appearance = NSAppearance(named: .darkAqua)
        var editor = mounted.editor
        editor.forcedAppearanceName = .aqua
        mounted.container.reconcile(content: mounted.content, editor: editor)
        mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 60, onShowSidebar: {})
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.pointerMoved(to: NSPoint(x: 12, y: 400))
        let card = try #require(rail.panel)
        #expect(rail.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(card.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        editor.forcedAppearanceName = .darkAqua
        mounted.container.reconcile(content: mounted.content, editor: editor)
        #expect(card.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        editor.forcedAppearanceName = nil
        mounted.window.appearance = NSAppearance(named: .aqua)
        mounted.container.reconcile(content: mounted.content, editor: editor)
        #expect(rail.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    // Rasterize production drawing; PDF marks are measured against their opaque backing.
    private func inkColumns(_ rail: NavigationRailView, scale: Int = 2) throws -> [Set<Int>] {
        let width = Int(rail.bounds.width) * scale
        let height = Int(rail.bounds.height) * scale
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        rail.effectiveAppearance.performAsCurrentDrawingAppearance { rail.draw(rail.bounds) }
        context.flushGraphics()
        return rail.geometry.marks.map { mark in
            // The gap below a tick samples its actual backing, independent of appearance.
            let backing = rail.kind == .pdf
                ? bitmap.colorAt(x: 16 * scale, y: Int((mark.y + 2) * CGFloat(scale)))?.usingColorSpace(.sRGB) : nil
            var columns: Set<Int> = []
            for x in 0..<(44 * scale) {
                for y in Int((mark.y - 1) * CGFloat(scale))..<Int((mark.y + 1) * CGFloat(scale)) {
                    guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.01 else { continue }
                    if let backing {
                        guard let color = pixel.usingColorSpace(.sRGB),
                              max(abs(color.redComponent - backing.redComponent),
                                  abs(color.greenComponent - backing.greenComponent),
                                  abs(color.blueComponent - backing.blueComponent)) > 0.02 else { continue }
                    }
                    columns.insert(x)
                }
            }
            return columns
        }
    }

    private func widths(_ rail: NavigationRailView, scale: Int = 2) throws -> [CGFloat] {
        try inkColumns(rail, scale: scale).map { CGFloat($0.count) / CGFloat(scale) }
    }

    private func prepareRail(_ mounted: Mounted) async throws -> NavigationRailView {
        var stableGeneration: Int?
        var settled = false
        for _ in 0..<60 {
            NSApp.activate(ignoringOtherApps: true)
            mounted.window.makeKeyAndOrderFront(nil)
            mounted.window.makeKey()
            mounted.container.configureNavigationRail(content: mounted.content, eligible: true, topInset: 0, onShowSidebar: {})
            try await Task.sleep(for: .milliseconds(50))
            let rail = mounted.container.navigationRailAdapter?.rail
            if mounted.window.isKeyWindow, let rail, stableGeneration == rail.generation { settled = true; break }
            stableGeneration = mounted.window.isKeyWindow ? rail?.generation : nil
        }
        try #require(settled, "Raster interaction fixture requires settled native key-window ownership")
        let rail = try #require(mounted.container.navigationRailAdapter?.rail)
        // Isolate ink geometry here; the exclusion case below exercises subtraction separately.
        rail.paintExclusions = nil
        rail.reservedNativeHit = nil
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        return rail
    }

    @Test("Native resting ink encodes all six absolute levels in light and dark at 1x and 2x",
          arguments: [false, true], [1, 2])
    func headingLevelInk(dark: Bool, scale: Int) async throws {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Same\nbody\n" }.joined()
        let mounted = Mounted(source: source)
        defer { mounted.close() }
        let rail = try await prepareRail(mounted)
        rail.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        #expect(try widths(rail, scale: scale) == [21, 18, 15, 12, 9, 6])
        #expect(try inkColumns(rail, scale: scale).allSatisfy { $0.min() == 12 * scale && $0.max()! < 44 * scale })
        let geometry = rail.geometry
        // Active membership changes color without changing neutral lengths or rank geometry.
        let snapshot = try #require(mounted.content.editorController.sectionNavigationSnapshot)
        rail.configure(kind: .markdown, count: 6, visible: [0, 5], identity: snapshot.targets.first as AnyHashable,
                       eligible: true, topInset: 0)
        #expect(try widths(rail, scale: scale) == [21, 18, 15, 12, 9, 6])
        #expect(rail.geometry == geometry)
    }

    @Test("Skipped levels keep absolute widths and hover composes above baseline across the full lane")
    func skippedLevelsAndHoverInk() async throws {
        let mounted = Mounted(source: "### Third\nbody\n###### Sixth\ntail\n")
        defer { mounted.close() }
        let rail = try await prepareRail(mounted)
        #expect(try widths(rail) == [15, 6])
        let point = NSPoint(x: 43, y: rail.geometry.marks[1].y)
        #expect(rail.hitTest(mounted.container.convert(point, from: rail)) === rail)
        rail.pointerMoved(to: point)
        let last = try #require(mounted.content.editorController.sectionNavigationSnapshot?.targets.last)
        #expect(rail.presentedTarget == .section(last))
        #expect(try widths(rail) == [22, 28])
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        #expect(try widths(rail) == [15, 6])

        mounted.content.documentManager.text = (1...6).map { String(repeating: "#", count: $0) + " Level\nbody\n" }.joined()
        mounted.container.reconcile(content: mounted.content, editor: mounted.editor)
        let updated = try await prepareRail(mounted)
        let geometry = updated.geometry
        updated.pointerMoved(to: NSPoint(x: 43, y: geometry.marks[0].y))
        #expect(try widths(updated) == [28, 22, 16, 12, 9, 6])
        updated.pointerMoved(to: NSPoint(x: 43, y: geometry.marks[5].y))
        #expect(try widths(updated) == [21, 18, 15, 16, 22, 28])
        #expect(updated.geometry == geometry)
        updated.pointerMoved(to: NSPoint(x: 500, y: 300))
        #expect(try widths(updated) == [21, 18, 15, 12, 9, 6])
    }

    @Test("Grouped ink matches preview and click representatives; exclusions and PDF widths remain native")
    func groupedInkAndPDF() async throws {
        let levels = [4, 1, 6, 2, 3, 5, 1, 6, 4, 2, 5, 3, 6, 1, 2, 4, 3, 5, 1, 6]
        let source = levels.enumerated().map { String(repeating: "#", count: $0.element) + " Heading \($0.offset)\nbody\n" }.joined()
        let mounted = Mounted(source: source, height: 80)
        defer { mounted.close() }
        let rail = try await prepareRail(mounted)
        let targets = try #require(mounted.content.editorController.sectionNavigationSnapshot?.targets)
        try #require(rail.geometry.marks.count < targets.count)
        #expect(try widths(rail) == rail.geometry.marks.map { CGFloat([21, 18, 15, 12, 9, 6][levels[$0.representative] - 1]) })
        let mark = rail.geometry.marks[0]
        try #require(mark.ranks == 0..<2 && targets[0].level == 4 && targets[1].level == 1)
        let point = NSPoint(x: 43, y: mark.y)
        rail.pointerMoved(to: point)
        #expect(rail.presentedTarget == .section(targets[mark.representative]))
        var activated: NavigationRailTarget?
        rail.onActivate = { target, _ in activated = target }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: rail.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        rail.mouseDown(with: try event(.leftMouseDown))
        rail.mouseUp(with: try event(.leftMouseUp))
        #expect(activated == .section(targets[mark.representative]))
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        rail.paintExclusions = { [NSRect(x: 16, y: mark.y - 2, width: 6, height: 4),
                                   NSRect(x: 18, y: mark.y - 2, width: 2, height: 4)] }
        let columns = try #require(inkColumns(rail).first)
        #expect(columns.isDisjoint(with: Set(32..<44)))
        #expect(columns.contains(24) && columns.contains(47))
        rail.paintExclusions = nil
        rail.configure(kind: .pdf, count: 2, visible: [1], identity: "pdf-control", eligible: true, topInset: 0)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            rail.appearance = NSAppearance(named: appearance)
            for scale in [1, 2] {
                #expect(try widths(rail, scale: scale) == [12, 18])
            }
        }
    }

    @Test("A later heading-prefix edit and Undo publish new levels and resting ink without reviving old tokens")
    func headingPrefixEditInk() async throws {
        let source = "# First\nbody\n###### Later\ntail\n"
        let mounted = Mounted(source: source)
        defer { mounted.close() }
        let rail = try await prepareRail(mounted)
        let controller = mounted.content.editorController
        let old = try #require(controller.sectionNavigationSnapshot?.targets.last)
        let generation = rail.generation
        #expect(try widths(rail) == [21, 6])
        let point = NSPoint(x: 43, y: rail.geometry.marks[1].y)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: rail.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        rail.mouseDown(with: down)
        let trail = mounted.content.navigationTrail
        mounted.content.undoManager.beginUndoGrouping()
        mounted.native.insertText("#", replacementRange: (source as NSString).range(of: "######"))
        mounted.native.breakUndoCoalescing()
        mounted.content.undoManager.endUndoGrouping()
        for _ in 0..<100 where mounted.coordinator.sectionNavigationState.snapshot?.targets.last?.level != 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let edited = try #require(mounted.coordinator.sectionNavigationState.snapshot?.targets.last)
        #expect(edited.level == 1 && edited.rank == old.rank && edited.title == old.title && edited.source != old.source)
        #expect(mounted.coordinator.sectionNavigationState.snapshot?.targets.count == 2)
        #expect(rail.generation != generation)
        #expect(rail.targetAtRank?(1) == .section(edited))
        #expect(controller.sectionPreview(for: old) == nil)
        rail.pointerMoved(to: NSPoint(x: 500, y: 300))
        #expect(try widths(rail) == [21, 21])
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow, modifierFlags: [],
            timestamp: 0, windowNumber: mounted.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        rail.mouseUp(with: up)
        #expect(mounted.content.navigationTrail == trail)
        mounted.content.undoManager.undo()
        for _ in 0..<100 where mounted.coordinator.sectionNavigationState.snapshot?.targets.last?.level != 6 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try #require(mounted.coordinator.sectionNavigationState.snapshot?.targets.last)
        #expect(mounted.native.string == source)
        #expect(restored.level == 6 && restored.source != old.source && restored.source != edited.source)
        #expect(controller.sectionPreview(for: old) == nil)
        #expect(controller.sectionPreview(for: edited) == nil)
        #expect(rail.targetAtRank?(1) == .section(restored))
        #expect(try widths(rail) == [21, 6])
    }

    @Test("Native window delivery preserves editor ownership and protected input when clicking a rail",
          arguments: ["selection", "marked", "table", "tableMarked"])
    func nativeRailClickKeepsInputOwner(input: String) async throws {
        let source = "# First\n| H |\n| --- |\n| cell |\n\n"
            + String(repeating: "paragraph\n\n", count: 100) + "# Last\ntail\n"
        let mounted = Mounted(source: source)
        defer { mounted.close() }
        let rail = try await prepareRail(mounted)
        // Restore production native-control admission; raster helpers clear it.
        rail.reservedNativeHit = { [weak container = mounted.container] in container?.nativeControl(at: $0) }
        try #require(mounted.window.makeFirstResponder(mounted.native))
        let inputView: NSTextView
        if input.hasPrefix("table") {
            let coordinator = mounted.coordinator
            let token = try #require(coordinator.parsedDocument(for: mounted.native.string).tokens.first { $0.kind == .table })
            let table = try #require(MarkdownTableSource(source: mounted.native.string, range: token.range))
            let session = coordinator.tableEditingSession
            let rect = try #require(session.geometry(for: table)?.cellRects[1][0])
            try #require(session.begin(range: token.range,
                point: NSPoint(x: rect.midX, y: rect.midY), in: mounted.native))
            inputView = session.editor
        } else {
            inputView = mounted.native
        }
        try #require(mounted.window.firstResponder === inputView)
        let composing = input == "marked" || input == "tableMarked"
        if composing {
            inputView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                replacementRange: NSRange(location: input.hasPrefix("table") ? 0 : 2, length: 0))
            try #require(inputView.hasMarkedText())
        } else {
            inputView.setSelectedRange(NSRange(location: 1, length: 2))
        }
        let selections = inputView.selectedRanges
        let nativeSource = mounted.native.string
        let durableSource = mounted.content.documentManager.text
        let undo = mounted.content.undoManager.canUndo
        let trail = mounted.content.navigationTrail
        let last = try #require(rail.geometry.marks.last)
        let point = rail.convert(NSPoint(x: 12, y: last.y), to: nil)
        let content = try #require(mounted.window.contentView)
        let hitPoint = content.superview?.convert(point, from: nil) ?? point
        try #require(content.hitTest(hitPoint) === rail, "A real window hit must reach the rail, not an editor control")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 91, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            mounted.window.sendEvent(event)
            #expect(mounted.window.firstResponder === inputView,
                "Native \(type) changed \(input) ownership to \(String(describing: mounted.window.firstResponder))")
        }
        #expect(inputView.selectedRanges == selections)
        #expect(inputView.hasMarkedText() == composing)
        #expect(mounted.native.string == nativeSource)
        #expect(mounted.content.documentManager.text == durableSource)
        #expect(mounted.content.undoManager.canUndo == undo)
        if input.hasPrefix("table") { #expect(mounted.coordinator.tableEditingSession.isActive) }
        if composing {
            #expect(mounted.content.navigationTrail == trail, "Composition must defer navigation")
        } else {
            #expect(mounted.content.navigationTrail.canGoBack, "The native click must actually navigate")
        }
    }

}
