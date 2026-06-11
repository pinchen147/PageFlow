//
//  DocumentStateTests.swift
//  PageFlowTests
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct DocumentStateTests {
    @Test
    func pdfViewHostFreezesPDFLayoutDuringLiveResize() {
        let pdfView = StablePDFView()
        pdfView.document = makeTestDocument(pageCount: 1)

        let host = PDFViewHost(pdfView: pdfView)
        #expect(host.preservesContentDuringLiveResize)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        host.layout()
        #expect(pdfView.frame.size == host.bounds.size)

        host.viewWillStartLiveResize()
        #expect(!pdfView.isHidden)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 650)
        host.layout()
        #expect(pdfView.frame.size == NSSize(width: 400, height: 500))

        host.viewDidEndLiveResize()
        #expect(pdfView.frame.size == NSSize(width: 700, height: 650))
    }

    @Test
    func glassScrollerKnobTracksNativeScrollPosition() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let scroller = GlassScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = scroller
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 1_200))

        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.layoutSubtreeIfNeeded()

        let knob = try #require(scroller.subviews.first)
        let initialFrame = knob.frame

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        #expect(knob.frame == scroller.rect(for: .knob))
        #expect(knob.frame != initialFrame)
    }

    @Test
    func tabManagerMatchesCanonicalURLsAcrossSymlinks() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let originalURL = tempDirectory.appendingPathComponent("sample.pdf")
        let symlinkURL = tempDirectory.appendingPathComponent("sample-link.pdf")

        try Data().write(to: originalURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: originalURL)

        let tabManager = TabManager()
        tabManager.tabs[0].documentURL = originalURL

        #expect(tabManager.tabID(for: symlinkURL) == tabManager.tabs[0].id)
    }

    @Test
    func bookmarkManagerReconcilesInsertedDeletedAndMovedPages() {
        let pdfManager = PDFManager()
        let bookmarkManager = BookmarkManager()
        let undoManager = UndoManager()

        bookmarkManager.configure(pdfManager: pdfManager) { undoManager }

        bookmarkManager.addBookmark(at: 1)
        bookmarkManager.addBookmark(at: 3)

        let secondBookmark = try! #require(bookmarkManager.bookmarks.first(where: { $0.pageIndex == 3 }))
        bookmarkManager.renameBookmark(secondBookmark.id, to: "Chapter")

        bookmarkManager.handlePageInsertion(at: 1)

        let insertedBookmarks = bookmarkManager.sortedBookmarks
        #expect(insertedBookmarks.map(\.pageIndex) == [2, 4])
        #expect(insertedBookmarks[0].title == "Page 3")
        #expect(insertedBookmarks[1].title == "Chapter")

        bookmarkManager.handlePageDeletion(at: 2)

        let deletedBookmarks = bookmarkManager.sortedBookmarks
        #expect(deletedBookmarks.map(\.pageIndex) == [3])
        #expect(deletedBookmarks[0].title == "Chapter")

        bookmarkManager.handlePageMove(from: 3, to: 0)

        let movedBookmark = try! #require(bookmarkManager.sortedBookmarks.first)
        #expect(movedBookmark.pageIndex == 0)
        #expect(movedBookmark.title == "Chapter")
    }

    @Test
    func bookmarkManagerLoadsSameDataForCanonicalizedDocumentURLs() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let originalURL = tempDirectory.appendingPathComponent("bookmarked.pdf")
        let symlinkURL = tempDirectory.appendingPathComponent("bookmarked-link.pdf")

        try Data().write(to: originalURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: originalURL)

        let pdfManager = PDFManager()
        let bookmarkManager = BookmarkManager()
        let undoManager = UndoManager()

        pdfManager.document = makeTestDocument(pageCount: 5)
        pdfManager.documentURL = originalURL
        bookmarkManager.configure(pdfManager: pdfManager) { undoManager }
        bookmarkManager.addBookmark(at: 2)
        bookmarkManager.clearBookmarks()

        bookmarkManager.loadBookmarks(for: symlinkURL)

        let loadedBookmark = try! #require(bookmarkManager.bookmarks.first)
        #expect(loadedBookmark.pageIndex == 2)
        #expect(bookmarkManager.bookmarks.count == 1)
    }

    @Test
    func tabManagerCancellingLockedOpenClosesTemporaryTab() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let existingURL = tempDirectory.appendingPathComponent("existing.pdf")
        let lockedURL = tempDirectory.appendingPathComponent("locked.pdf")
        writeDocument(makeTestDocument(pageCount: 1), to: existingURL)
        writePasswordProtectedDocument(makeTestDocument(pageCount: 1), to: lockedURL, password: "secret")

        let tabManager = TabManager()
        let originalTabID = tabManager.tabs[0].id
        tabManager.tabs[0].documentURL = existingURL

        tabManager.openDocument(url: lockedURL, isSecurityScoped: false)

        let passwordRequest = try! #require(tabManager.pendingPasswordRequest)
        #expect(passwordRequest.tabID != originalTabID)
        #expect(tabManager.tabID(for: lockedURL) == passwordRequest.tabID)
        #expect(tabManager.tabs.count == 2)

        tabManager.cancelPasswordPrompt()

        #expect(tabManager.pendingPasswordRequest == nil)
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.activeTabID == originalTabID)
        #expect(tabManager.tabID(for: lockedURL) == nil)
    }

    @Test
    func pdfManagerCloseDocumentClearsPendingLockedState() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let lockedURL = tempDirectory.appendingPathComponent("locked.pdf")
        writePasswordProtectedDocument(makeTestDocument(pageCount: 1), to: lockedURL, password: "secret")

        let pdfManager = PDFManager()
        let result = pdfManager.loadDocument(from: lockedURL)

        guard case .needsPassword = result else {
            Issue.record("Expected locked PDF to require a password.")
            return
        }

        #expect(pdfManager.pendingLockedURL == lockedURL)
        #expect(pdfManager.pendingLockedDocument != nil)

        pdfManager.closeDocument()

        #expect(pdfManager.pendingLockedURL == nil)
        #expect(pdfManager.pendingLockedDocument == nil)
        #expect(pdfManager.pendingIsSecurityScoped == false)
    }

    @Test
    func recentFilesManagerRetainsBookmarkBackedEntriesWhenStoredPathIsMissing() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let originalURL = tempDirectory.appendingPathComponent("original.pdf")
        let movedURL = tempDirectory.appendingPathComponent("moved.pdf")
        writeDocument(makeTestDocument(pageCount: 1), to: originalURL)

        let bookmarkData = try originalURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let recentFile = RecentFile(url: originalURL, securityScopedBookmarkData: bookmarkData)
        defaults.set(try JSONEncoder().encode([recentFile]), forKey: "recentFiles")

        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        let manager = RecentFilesManager(defaults: defaults)

        #expect(manager.recentFiles.count == 1)
        #expect(manager.recentFiles.first?.securityScopedBookmarkData == bookmarkData)
    }

    @Test
    func settingsManagerPersistsToolbarPreferences() throws {
        let suiteName = "SettingsManagerTests-\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SettingsManager(defaults: defaults)
        #expect(manager.toolbarScale == SettingsManager.defaultToolbarScale)
        #expect(manager.isTopBarAlwaysVisible == false)
        #expect(manager.isFloatingToolbarAlwaysVisible == false)
        #expect(manager.isPageIndicatorAlwaysVisible == false)

        manager.toolbarScale = 1.35
        manager.isTopBarAlwaysVisible = true
        manager.isFloatingToolbarAlwaysVisible = true
        manager.isPageIndicatorAlwaysVisible = true

        let reloadedManager = SettingsManager(defaults: defaults)
        #expect(reloadedManager.toolbarScale == 1.35)
        #expect(reloadedManager.isTopBarAlwaysVisible)
        #expect(reloadedManager.isFloatingToolbarAlwaysVisible)
        #expect(reloadedManager.isPageIndicatorAlwaysVisible)
    }

    @Test
    func settingsManagerInitializesSeparatedVisibilityControlsHidden() throws {
        let suiteName = "SettingsManagerDefaultVisibilityTests-\(UUID().uuidString)"
        let defaults = try! #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The old combined preference must not make either new control visible.
        defaults.set(true, forKey: "settings.toolbarPinned")

        let manager = SettingsManager(defaults: defaults)
        #expect(manager.isTopBarAlwaysVisible == false)
        #expect(manager.isFloatingToolbarAlwaysVisible == false)
        #expect(manager.isPageIndicatorAlwaysVisible == false)
    }

    @Test
    func commentManagerReconcilesAfterPageStructureChanges() {
        let document = makeTestDocument(pageCount: 3)
        let pdfManager = PDFManager()
        let commentManager = CommentManager()
        let undoManager = UndoManager()

        pdfManager.document = document
        pdfManager.currentPage = document.page(at: 1)
        pdfManager.currentPageIndex = 1

        commentManager.configure(
            pdfManager: pdfManager,
            selectionProvider: { (nil, document.page(at: 1)) },
            undoManagerProvider: { undoManager }
        )

        let commentID = try! #require(commentManager.addComment(text: "note"))
        #expect(commentManager.comments.first?.pageIndex == 1)

        document.removePage(at: 0)
        commentManager.reconcilePageIndices()

        let shiftedComment = try! #require(commentManager.comments.first(where: { $0.id == commentID }))
        #expect(shiftedComment.pageIndex == 0)

        document.removePage(at: 0)
        commentManager.reconcilePageIndices()

        #expect(commentManager.comments.isEmpty)
        #expect(commentManager.selectedCommentID == nil)
    }

    @Test
    func pdfManagerKeepsCurrentPageStableWhenPagesChangeBeforeIt() {
        let document = makeTestDocument(pageCount: 4)
        let pdfManager = PDFManager()
        let undoManager = UndoManager()

        pdfManager.document = document
        pdfManager.currentPageIndex = 3
        pdfManager.currentPage = document.page(at: 3)
        pdfManager.undoManagerProvider = { undoManager }

        pdfManager.duplicatePage(at: 1)
        #expect(pdfManager.currentPageIndex == 4)

        pdfManager.deletePage(at: 1)
        #expect(pdfManager.currentPageIndex == 3)
    }

    private func writeDocument(_ document: PDFDocument, to url: URL) {
        let didWrite = document.write(to: url)
        #expect(didWrite)
    }

    private func writePasswordProtectedDocument(_ document: PDFDocument, to url: URL, password: String) {
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password
        ]
        let didWrite = document.write(to: url, withOptions: options)
        #expect(didWrite)
    }
}
