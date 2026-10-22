//
//  MarkdownLocalLinkTests.swift
//  PageFlowTests
//
//  Local links in a note (D8): headings jump, documents open in tabs, other
//  files ask first, and apps or scripts never open from a link.
//

import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownLocalLinkTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func headingSlugsMatchTitleAndAnchorForms() {
        #expect(MarkdownContent.headingSlug("Getting Started!") == "getting-started")
        #expect(MarkdownContent.headingSlug("getting-started") == "getting-started")
        #expect(MarkdownContent.headingSlug("Part 2: Setup") == "part-2-setup")
    }

    @Test
    func relativeLinksResolveFromTheNotesFolder() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: note)
        let content = MarkdownContent(documentId: UUID().uuidString)
        try content.documentManager.load(from: note)

        #expect(content.localLinkTarget(try #require(URL(string: "sub/other%20note.md")))?.path
                == directory.appendingPathComponent("sub/other note.md").standardizedFileURL.path)
        #expect(content.localLinkTarget(try #require(URL(string: "/abs/x.md")))?.path == "/abs/x.md")
        #expect(MarkdownContent(documentId: "untitled").localLinkTarget(try #require(URL(string: "x.md"))) == nil)
    }

    @Test
    func aLinkedNoteOpensInATab() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let other = directory.appendingPathComponent("other.md")
        try Data("[next](other.md)\n".utf8).write(to: note)
        try Data("# Other\n".utf8).write(to: other)
        let manager = TabManager()
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeSession?.content.markdown)

        await manager.openLocalLink(try #require(URL(string: "other.md")), from: content)?.value

        #expect(manager.tabID(for: other) != nil)
    }

    @Test(arguments: [false, true], [false, true])
    func aPDFPageLinkOpensTheRequestedPage(existingPDF: Bool, absoluteLink: Bool) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("Paper (二).PDF")
        try Data("Research notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf) == true)
        let manager = TabManager()
        defer { for session in manager.sessions.values { session.cleanup() } }
        var originalTabID: UUID?
        if existingPDF {
            await manager.openDocument(url: pdf, isSecurityScoped: false)?.value
            originalTabID = manager.activeTabID
        }
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeMarkdownContent)
        let link: URL
        if absoluteLink {
            var components = try #require(URLComponents(url: pdf, resolvingAgainstBaseURL: false))
            components.fragment = "page=3"
            link = try #require(components.url)
        } else {
            link = try #require(URL(string: "Paper%20(%E4%BA%8C).PDF#page=3&zoom=125"))
        }
        await manager.openLocalLink(link, from: content)?.value
        let opened = try #require(manager.activePDFManager)
        #expect(opened.documentURL?.pageFlowCanonicalDocumentURL == pdf.pageFlowCanonicalDocumentURL)
        #expect(opened.currentPageIndex == 2)
        #expect(opened.pendingNavigation?.page === opened.document?.page(at: 2))
        #expect(manager.tabs.filter { $0.documentURL?.pageFlowCanonicalDocumentURL == pdf.pageFlowCanonicalDocumentURL }.count == 1)
        if let originalTabID { #expect(manager.activeTabID == originalTabID) }
    }

    @Test
    func aPageLinkTargetsTheExistingPDFInAnotherWindow() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("paper.pdf")
        try Data("Notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf) == true)
        let source = TabManager()
        let destination = TabManager()
        await source.openDocument(url: note, isSecurityScoped: false)?.value
        await destination.openDocument(url: pdf, isSecurityScoped: false)?.value
        let content = try #require(source.activeMarkdownContent)
        let sourceWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled], backing: .buffered, defer: true)
        let destinationWindow = NSWindow(contentRect: sourceWindow.frame, styleMask: [.titled], backing: .buffered, defer: true)
        sourceWindow.isReleasedWhenClosed = false
        destinationWindow.isReleasedWhenClosed = false
        WindowRegistry.shared.register(source, window: sourceWindow)
        WindowRegistry.shared.register(destination, window: destinationWindow)
        defer {
            sourceWindow.orderOut(nil); destinationWindow.orderOut(nil)
            WindowRegistry.shared.unregister(source); WindowRegistry.shared.unregister(destination)
            for session in Array(source.sessions.values) + Array(destination.sessions.values) { session.cleanup() }
        }
        await source.openLocalLink(try #require(URL(string: "paper.pdf#page=3")), from: content)?.value
        #expect(source.tabID(for: pdf) == nil)
        #expect(destination.activePDFManager?.currentPageIndex == 2)
        #expect(destination.tabs.count == 1)
    }

    @Test
    func aSamePageLinkOverridesAnOldScrollRestoreAndDoesNotAddHistory() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("paper.pdf")
        try Data("Notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf) == true)
        let manager = TabManager()
        defer { for session in manager.sessions.values { session.cleanup() } }
        await manager.openDocument(url: pdf, isSecurityScoped: false)?.value
        let opened = try #require(manager.activePDFManager)
        opened.goToPage(2)
        let page = try #require(opened.currentPage)
        opened.pendingScrollRestore = PDFDestination(page: page, at: CGPoint(x: 10, y: 100))
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeMarkdownContent)
        await manager.openLocalLink(try #require(URL(string: "paper.pdf#page=3")), from: content)?.value
        #expect(opened.currentPageIndex == 2)
        #expect(opened.pendingScrollRestore == nil)
        #expect(opened.pendingNavigation?.page === page)
        #expect(opened.pendingNavigation?.point.y == page.bounds(for: .mediaBox).maxY)
        opened.goBack()
        #expect(opened.currentPageIndex == 2)
    }

    @Test(arguments: [0, 90, 180, 270])
    func aPageLinkMovesTheNativeViewAfterAnOlderRestoreWasQueued(rotation: Int) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("paper.pdf")
        try Data("Notes\n".utf8).write(to: note)
        let source = try #require(makeTextDocument(pages: ["First", "Second", "Third"]))
        source.page(at: 2)?.rotation = rotation
        try #require(source.write(to: pdf))
        let tabs = TabManager()
        defer { for session in tabs.sessions.values { session.cleanup() } }
        await tabs.openDocument(url: pdf, isSecurityScoped: false)?.value
        let manager = try #require(tabs.activePDFManager)
        let document = try #require(manager.document)
        manager.displayMode = .singlePage
        manager.scaleFactor = 0.6
        manager.pendingFit = nil
        let view = StablePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 0.6
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        let coordinator = PDFViewWrapper.Coordinator(
            pdfManager: manager, annotationManager: AnnotationManager(),
            commentManager: CommentManager(), isActive: true
        )
        defer {
            window.orderOut(nil)
            coordinator.removeScrollMonitor()
            view.removeRightClickMonitor()
        }
        let first = try #require(document.page(at: 0))
        view.go(to: first)
        try #require(view.currentPage === first)
        // Admit a real restore callback before the newer explicit navigation.
        manager.pendingScrollRestore = PDFDestination(page: first, at: CGPoint(x: 10, y: 100))
        coordinator.project(view, documentDidChange: false)
        await tabs.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(tabs.activeMarkdownContent)
        await tabs.openLocalLink(try #require(URL(string: "paper.pdf#page=3")), from: content)?.value
        coordinator.project(view, documentDidChange: false)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.pdfLayoutSettleDelay + 0.1) {
                continuation.resume()
            }
        }
        let target = try #require(document.page(at: 2))
        #expect(view.currentPage === target)
        #expect(view.visiblePages.contains { $0 === target })
        #expect(manager.pendingNavigation == nil)
    }

    @Test
    func aLockedPageLinkFollowsItsSessionThroughAWindowTransfer() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("locked.pdf")
        try Data("Notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf, withOptions: [.userPasswordOption: "reader", .ownerPasswordOption: "owner"]) == true)
        let source = TabManager()
        let destination = TabManager(createInitialTab: false)
        defer { for session in Array(source.sessions.values) + Array(destination.sessions.values) { session.cleanup() } }
        await source.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(source.activeMarkdownContent)
        await source.openLocalLink(try #require(URL(string: "locked.pdf#page=2")), from: content)?.value
        let lockedID = try #require(source.pendingPasswordRequest?.tabID)
        // A newer page reference updates the same pending password request.
        await source.openLocalLink(try #require(URL(string: "locked.pdf#page=3")), from: content)?.value
        try #require(source.moveTab(lockedID, to: destination, at: 0, closeIfEmpty: false))
        try #require(destination.submitPassword("reader"))
        #expect(destination.activePDFManager?.currentPageIndex == 2)
        #expect(destination.pendingPasswordRequest == nil)
        #expect(source.tabID(for: pdf) == nil)
    }

    @Test
    func replacingAnUnlockRequestDoesNotCarryThePreviousPageLink() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let first = directory.appendingPathComponent("first.pdf")
        let second = directory.appendingPathComponent("second.pdf")
        try Data("Notes\n".utf8).write(to: note)
        for pdf in [first, second] {
            try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf, withOptions: [.userPasswordOption: "reader", .ownerPasswordOption: "owner"]) == true)
        }
        let manager = TabManager()
        defer { for session in manager.sessions.values { session.cleanup() } }
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeMarkdownContent)
        await manager.openLocalLink(try #require(URL(string: "first.pdf#page=3")), from: content)?.value
        let pending = try #require(manager.activePDFManager)
        await manager.openDocument(url: second, isSecurityScoped: false, replaceCurrent: true)?.value
        try #require(manager.activePDFManager === pending)
        try #require(manager.submitPassword("reader"))
        #expect(pending.documentURL?.pageFlowCanonicalDocumentURL == second.pageFlowCanonicalDocumentURL)
        #expect(pending.currentPageIndex == 0)
        #expect(pending.pendingNavigation == nil)
    }

    @Test
    func theNewestPageReferenceSurvivesACloudDownload() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("cloud.pdf")
        try Data("Notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf) == true)
        let manager = TabManager()
        defer { for session in manager.sessions.values { session.cleanup() } }
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeMarkdownContent)
        var cloudOnly = true
        manager.isCloudOnly = { $0.pathExtension == "pdf" && cloudOnly }
        manager.openLocalLink(try #require(URL(string: "cloud.pdf#page=2")), from: content)
        manager.openLocalLink(try #require(URL(string: "cloud.pdf#page=3")), from: content)
        #expect(manager.tabID(for: pdf) == nil)
        cloudOnly = false
        let deadline = ContinuousClock.now + .seconds(3)
        while manager.tabID(for: pdf) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let opened = try #require(manager.activePDFManager)
        #expect(opened.currentPageIndex == 2)
        #expect(manager.tabs.filter { $0.documentURL?.pageFlowCanonicalDocumentURL == pdf.pageFlowCanonicalDocumentURL }.count == 1)
    }

    @Test(arguments: ["page=0", "page=-1", "page=2.5", "page=2&page=3", "page=9999999999999999999999999999", "page=99"])
    func invalidOrOutOfRangePageLinksKeepTheExistingPage(fragment: String) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        let pdf = directory.appendingPathComponent("paper.pdf")
        try Data("Notes\n".utf8).write(to: note)
        try #require(makeTextDocument(pages: ["First", "Second", "Third"])?.write(to: pdf) == true)
        let manager = TabManager()
        defer { for session in manager.sessions.values { session.cleanup() } }
        await manager.openDocument(url: pdf, isSecurityScoped: false)?.value
        let opened = try #require(manager.activePDFManager)
        opened.goToPage(1)
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeMarkdownContent)
        await manager.openLocalLink(try #require(URL(string: "paper.pdf#" + fragment)), from: content)?.value
        #expect(opened.currentPageIndex == 1)
        #expect(opened.pendingNavigation == nil)
    }

    @Test
    func scriptsNeverOpenAndOtherFilesAskFirst() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("note.md")
        try Data("links\n".utf8).write(to: note)
        try Data("#!/bin/sh\n".utf8).write(to: directory.appendingPathComponent("run.sh"))
        try Data("a,b\n".utf8).write(to: directory.appendingPathComponent("data.csv"))
        let manager = TabManager()
        await manager.openDocument(url: note, isSecurityScoped: false)?.value
        let content = try #require(manager.activeSession?.content.markdown)
        var asked: [String] = []
        manager.localFileLinkPrompt = { asked.append($0); return false }

        await manager.openLocalLink(try #require(URL(string: "run.sh")), from: content)?.value
        await manager.openLocalLink(try #require(URL(string: "data.csv")), from: content)?.value

        #expect(asked == ["data.csv"], "a script is refused before any prompt")
    }
}
