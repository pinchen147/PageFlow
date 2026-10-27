import AppKit
import PDFKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
@Suite("Thumbnail rail composition", .serialized)
struct ThumbnailRailCompositionTests {
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = descendant(type, in: child) { return match } }
        return nil
    }

    private func pixels(of view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func menuTitles(in host: NSView) throws -> [String] {
        let point = NSPoint(x: host.bounds.midX, y: host.isFlipped ? 100 : host.bounds.height - 100)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown,
            location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: host.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        var candidate = host.hitTest(host.convert(point, to: host.superview))
        while let view = candidate {
            if let menu = view.menu(for: event) { return menu.items.filter { !$0.isSeparatorItem }.map(\.title) }
            if view === host { break }
            candidate = view.superview
        }
        return []
    }

    @Test("Actual transient thumbnails omit bookmark pixels and actions while the manual grid preserves them")
    func transientAndManualComposition() async throws {
        let manager = PDFManager()
        manager.document = makeTestDocument(pageCount: 1)
        let bookmarks = BookmarkManager()
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        bookmarks.configure(pdfManager: manager) { undo }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close(); manager.closeDocument() }
        let bridge = NSHostingView(rootView: PDFNavigationRail(pdfManager: manager, bookmarkManager: bookmarks,
            eligible: true, topInset: 0, onShowSidebar: {}))
        window.contentView = bridge
        window.makeKeyAndOrderFront(nil)
        bridge.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let rail = try #require(descendant(NavigationRailView.self, in: bridge))
        let transient = try #require(rail.makePreview?(.page(0)))
        window.setContentSize(NSSize(width: 200, height: 500))
        window.contentView = transient
        try await Task.sleep(for: .milliseconds(500))
        let transientBefore = try pixels(of: transient)
        let transientMenu = try menuTitles(in: transient)
        #expect(transientMenu.isEmpty)
        bookmarks.addBookmark(at: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try pixels(of: transient) == transientBefore)

        let manual = NSHostingView(rootView: ThumbnailGridView(pdfManager: manager, bookmarkManager: bookmarks, isEditing: false))
        window.contentView = manual
        try await Task.sleep(for: .milliseconds(300))
        let manualBookmarked = try pixels(of: manual)
        let bookmarkedMenu = try menuTitles(in: manual)
        #expect(bookmarkedMenu.contains("Copy Page as Markdown"))
        #expect(bookmarkedMenu.contains("Remove Bookmark"))
        bookmarks.toggleBookmark(at: 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(try pixels(of: manual) != manualBookmarked)
        #expect(try menuTitles(in: manual).contains("Add Bookmark"))
        manual.rootView = ThumbnailGridView(pdfManager: manager, bookmarkManager: bookmarks, isEditing: true)
        try await Task.sleep(for: .milliseconds(150))
        let editingMenu = try menuTitles(in: manual)
        #expect(editingMenu.contains("Copy Page"))
        #expect(editingMenu.contains("Rotate Clockwise"))
        #expect(editingMenu.contains("Delete Page"))
    }
}
