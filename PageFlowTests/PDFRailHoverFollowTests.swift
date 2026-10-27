import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
@Suite("PDF rail hover follow", .serialized)
struct PDFRailHoverFollowTests {
    private final class PreviewWindow: NSWindow {
        var pointer = NSPoint(x: 700, y: 300)
        override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func mount(_ manager: PDFManager) async throws -> (PreviewWindow, NavigationRailView, PDFView) {
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let pdf = PDFView(frame: content.bounds)
        pdf.document = manager.document
        pdf.autoScales = false
        pdf.scaleFactor = 1
        if let page = manager.currentPage { pdf.go(to: page) }
        content.addSubview(pdf)
        let host = NSHostingView(rootView: PDFNavigationRail(pdfManager: manager,
            bookmarkManager: BookmarkManager(), eligible: true, topInset: 0, onShowSidebar: {}))
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let rail = try #require(descendant(NavigationRailView.self, in: host))
        var lastGeneration: Int?
        var settled = false
        for _ in 0..<60 {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            try await Task.sleep(for: .milliseconds(50))
            if window.isKeyWindow, lastGeneration == rail.generation { settled = true; break }
            lastGeneration = window.isKeyWindow ? rail.generation : nil
        }
        try #require(settled, "Fixture requires settled key-window ownership")
        window.makeFirstResponder(pdf)
        move(to: NSPoint(x: 700, y: 300), rail: rail, window: window)
        return (window, rail, pdf)
    }

    private func move(to point: NSPoint, rail: NavigationRailView, window: PreviewWindow) {
        window.pointer = rail.convert(point, to: nil)
        rail.pointerMoved(to: point)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        window.sendEvent(event)
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        try send(.leftMouseDown, at: point, in: window)
        try send(.leftMouseUp, at: point, in: window)
    }

    /// Uniform fixed-size cells make the native document extent an independent
    /// measurement of each page's position, including LazyVStack's offscreen rows.
    private func isCentered(_ index: Int, count: Int, scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView, document.bounds.height > scroll.contentSize.height else { return false }
        let stride = document.bounds.height / CGFloat(count)
        let center = (CGFloat(index) + 0.5) * stride
        return abs(scroll.contentView.bounds.midY - center) < stride / 4
    }

    private func expectCentered(_ index: Int, count: Int, scroll: NSScrollView) async throws {
        for _ in 0..<100 {
            scroll.window?.contentView?.layoutSubtreeIfNeeded()
            if isCentered(index, count: count, scroll: scroll) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(isCentered(index, count: count, scroll: scroll),
            "Page \(index + 1) must be centered in native clip \(scroll.contentView.bounds), document \(String(describing: scroll.documentView?.bounds))")
    }

    @Test("Distant grouped PDF hover targets scroll one mounted grid without navigating the PDF")
    func hoverMovesExistingGrid() async throws {
        let manager = PDFManager()
        manager.document = try #require(makeTextDocument(pages: Array(repeating: "Hover preview preserves selected text.", count: 300)))
        manager.goToPage(2)
        let undo = UndoManager()
        manager.undoManagerProvider = { undo }
        let (window, rail, pdf) = try await mount(manager)
        defer { window.close(); manager.closeDocument() }
        let selection = try #require(manager.currentPage?.selection(for: NSRange(location: 0, length: 5)))
        pdf.setCurrentSelection(selection, animate: false)
        let initialSelection = try #require(pdf.currentSelection?.string)
        #expect(initialSelection == "Hover")
        let initialPage = pdf.currentPage
        let initialPoint = pdf.currentDestination?.point
        let first = rail.geometry.marks[30]
        let second = rail.geometry.marks[100]
        try #require(first.ranks.count > 1 && second.ranks.count > 1)
        move(to: NSPoint(x: 20, y: first.y), rail: rail, window: window)
        let panel = try #require(rail.panel)
        panel.layoutSubtreeIfNeeded()
        let scroll = try #require(descendant(NSScrollView.self, in: panel))
        try await expectCentered(first.ranks.lowerBound, count: 300, scroll: scroll)
        let firstOffset = scroll.contentView.bounds.origin.y

        // A burst must settle on its latest target in the same mounted grid.
        for mark in [rail.geometry.marks[80], rail.geometry.marks[40], second] {
            move(to: NSPoint(x: 20, y: mark.y), rail: rail, window: window)
        }
        try await expectCentered(second.ranks.lowerBound, count: 300, scroll: scroll)
        #expect(rail.panel === panel)
        #expect(descendant(NSScrollView.self, in: panel) === scroll)
        #expect(scroll.contentView.bounds.origin.y > firstOffset + 10_000)
        #expect(rail.presentedTarget == .page(second.ranks.lowerBound))

        let heldOffset = scroll.contentView.bounds.origin
        move(to: NSPoint(x: 48, y: panel.frame.midY), rail: rail, window: window)
        move(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY), rail: rail, window: window)
        try await Task.sleep(for: .milliseconds(350))
        #expect(rail.panel === panel)
        #expect(scroll.contentView.bounds.origin == heldOffset)
        #expect(manager.currentPageIndex == 2)
        #expect(manager.currentPage === manager.document?.page(at: 2))
        #expect(pdf.currentPage === initialPage)
        #expect(pdf.currentSelection?.string == initialSelection)
        #expect(pdf.currentDestination?.point == initialPoint)
        #expect(!manager.canGoBack && !manager.canGoForward && !undo.canUndo && !manager.isDirty)
        #expect(manager.pendingNavigation == nil)

        // Native rail activation uses the same grouped page as the preview.
        try click(rail.convert(NSPoint(x: 20, y: second.y), to: nil), in: window)
        #expect(manager.currentPageIndex == second.ranks.lowerBound)
        #expect(manager.currentPage === manager.document?.page(at: second.ranks.lowerBound))
        #expect(manager.canGoBack)
        // Repeating the current mark must not add another departure.
        try click(rail.convert(NSPoint(x: 20, y: second.y), to: nil), in: window)
        manager.goBack()
        #expect(manager.currentPageIndex == 2)
        #expect(!manager.canGoBack && manager.canGoForward)
        #expect(!undo.canUndo && !manager.isDirty)

        // Native thumbnail input still navigates and records the departure.
        let clip = scroll.contentView
        try click(clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil), in: window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.currentPageIndex == second.ranks.lowerBound)
        #expect(manager.canGoBack)
        manager.goBack()
        #expect(manager.currentPageIndex == 2)
    }

    @Test("PDF activation rejects replacement or fitted reading before SwiftUI reconciles",
          arguments: ["replaceBeforePress", "replaceAfterPress", "fitAfterPress"])
    func staleActivationIsRejected(change: String) async throws {
        let manager = PDFManager()
        let original = makeTestDocument(pageCount: 80)
        manager.document = original
        manager.goToPage(2)
        let (window, rail, _) = try await mount(manager)
        defer { window.close(); manager.closeDocument() }
        let point = rail.convert(NSPoint(x: 20, y: rail.geometry.marks[40].y), to: nil)
        let generation = rail.generation
        if change == "replaceBeforePress" {
            manager.document = makeTestDocument(pageCount: 80)
            manager.goToPage(2)
        }
        try send(.leftMouseDown, at: point, in: window)
        if change == "replaceAfterPress" {
            manager.document = makeTestDocument(pageCount: 80)
            manager.goToPage(2)
        } else if change == "fitAfterPress" {
            manager.requestFitOnce()
        }
        // No suspension: the adapter still represents the old admission state.
        try #require(rail.generation == generation && rail.eligible)
        try send(.leftMouseUp, at: point, in: window)
        #expect(manager.currentPageIndex == 2)
        #expect(manager.currentPage === manager.document?.page(at: 2))
        #expect(!manager.canGoBack && !manager.canGoForward && !manager.isDirty)
        #expect(manager.pendingNavigation == nil)
        withExtendedLifetime(original) {}
    }

    @Test("Document replacement retires the old preview and requires fresh pointer entry")
    func replacementRetiresPreview() async throws {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: 80)
        let (window, rail, _) = try await mount(manager)
        defer { window.close(); manager.closeDocument() }
        let first = rail.geometry.marks[40]
        move(to: NSPoint(x: 20, y: first.y), rail: rail, window: window)
        let oldPanel = try #require(rail.panel)
        oldPanel.layoutSubtreeIfNeeded()
        let oldScroll = try #require(descendant(NSScrollView.self, in: oldPanel))
        try await expectCentered(40, count: 80, scroll: oldScroll)
        manager.document = makeTestDocument(pageCount: 80)
        for _ in 0..<100 where rail.panel != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rail.panel == nil)
        let oldOffset = oldScroll.contentView.bounds.origin
        move(to: NSPoint(x: 20, y: first.y), rail: rail, window: window)
        #expect(rail.panel == nil)
        move(to: NSPoint(x: 700, y: 300), rail: rail, window: window)
        move(to: NSPoint(x: 20, y: rail.geometry.marks[60].y), rail: rail, window: window)
        let nextPanel = try #require(rail.panel)
        nextPanel.layoutSubtreeIfNeeded()
        #expect(nextPanel !== oldPanel)
        let nextScroll = try #require(descendant(NSScrollView.self, in: nextPanel))
        try await expectCentered(60, count: 80, scroll: nextScroll)
        #expect(oldScroll.contentView.bounds.origin == oldOffset)
        rail.retire()
        #expect(rail.panel == nil)
        move(to: NSPoint(x: 20, y: first.y), rail: rail, window: window)
        #expect(rail.panel == nil)
    }

    @Test("Manual thumbnails keep their current-page follow policy")
    func manualSidebarFollowsCurrentPage() async throws {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: 80)
        manager.goToPage(20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); manager.closeDocument() }
        let host = NSHostingView(rootView: ThumbnailGridView(pdfManager: manager,
            bookmarkManager: BookmarkManager(), isEditing: false))
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendant(NSScrollView.self, in: host))
        try await expectCentered(20, count: 80, scroll: scroll)
        manager.goToPage(60)
        for _ in 0..<100 {
            let documentHeight = scroll.documentView?.bounds.height ?? 0
            if documentHeight > 0, scroll.contentView.bounds.contains(NSPoint(x: 0, y: documentHeight * 60.5 / 80)) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let targetCenter = try #require(scroll.documentView).bounds.height * 60.5 / 80
        #expect(scroll.contentView.bounds.minY < targetCenter && scroll.contentView.bounds.maxY > targetCenter)
        #expect(descendant(NSScrollView.self, in: host) === scroll)
    }
}
