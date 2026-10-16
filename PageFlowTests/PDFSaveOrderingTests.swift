import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct PDFSaveOrderingTests {
    /// Captures admitted work without executing it. Tests choose which queued
    /// job runs first; each job still performs the production filesystem write.
    /// The admission wait is bounded only to fail a broken fixture promptly.
    private final class ManualScheduler: @unchecked Sendable {
        struct Job: Sendable {
            let run: @Sendable () -> Void
        }
        private struct Waiter {
            let count: Int
            let continuation: CheckedContinuation<Bool, Never>
        }
        private let lock = NSLock()
        private var jobs: [Job] = []
        private var admitted = 0
        private var waiters: [UUID: Waiter] = [:]

        func enqueue(_ work: @escaping @Sendable () -> Void) {
            lock.lock()
            jobs.append(Job(run: work))
            admitted += 1
            let ready = waiters.filter { $0.value.count <= admitted }
            for id in ready.keys { waiters.removeValue(forKey: id) }
            lock.unlock()
            ready.values.forEach { $0.continuation.resume(returning: true) }
        }

        func waitForAdmission(_ count: Int) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if admitted >= count {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                let id = UUID()
                waiters[id] = Waiter(count: count, continuation: continuation)
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let waiter = self.waiters.removeValue(forKey: id)
                    self.lock.unlock()
                    waiter?.continuation.resume(returning: false)
                }
            }
        }

        func takeLast() -> Job? {
            lock.lock()
            defer { lock.unlock() }
            return jobs.popLast()
        }

        func drain() {
            while let job = takeLast() { job.run() }
        }
    }


    private func fixture() throws -> (directory: URL, source: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-save-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        try #require(document.write(to: source))
        return (directory, source)
    }

    private func load(_ url: URL, into manager: PDFManager) throws {
        let succeeded: Bool
        if case .success = manager.loadDocument(from: url) { succeeded = true } else { succeeded = false }
        try #require(succeeded, "Real PDF fixture failed to load")
    }

    private func addAnnotation(_ label: String, to manager: PDFManager) throws {
        let page = try #require(manager.document?.page(at: 0))
        let annotation = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 24, height: 24),
                                       forType: .text, withProperties: nil)
        annotation.contents = label
        page.addAnnotation(annotation)
        manager.noteVisibleEdit(on: page)
    }

    private func annotationNames(at url: URL) throws -> Set<String> {
        let document = try #require(PDFDocument(url: url), "Saved bytes must be a readable PDF")
        let page = try #require(document.page(at: 0))
        return Set(page.annotations.compactMap(\.contents))
    }

    @Test
    func editAfterSnapshotStaysDirtyEvenWhenItWasAlreadyDirty() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("first", to: manager)
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        #expect(manager.isDirty)
        try addAnnotation("second", to: manager)
        scheduler.drain()
        #expect(await save.value)
        #expect(try annotationNames(at: files.source) == ["first"])
        #expect(Set(manager.document?.page(at: 0)?.annotations.compactMap(\.contents) ?? []) == ["first", "second"])
        #expect(manager.isDirty, "An older snapshot must not clear a second true-to-true edit notification")
        #expect(manager.saveSync())
        #expect(try annotationNames(at: files.source) == ["first", "second"])
        #expect(!manager.isDirty)
    }

    @Test
    func newerAsyncSaveWinsWhenItsScheduledWorkRunsFirst() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("first", to: manager)
        let first = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        try addAnnotation("second", to: manager)
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        let newer = try #require(scheduler.takeLast())
        let older = try #require(scheduler.takeLast())
        newer.run()
        #expect(await second.value)
        older.run()
        #expect(await first.value)
        #expect(try annotationNames(at: files.source) == ["first", "second"])
        #expect(!manager.isDirty)
    }

    @Test
    func synchronousSaveFencesOlderPhysicalWrites() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("first", to: manager)
        let first = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let delayed = try #require(scheduler.takeLast())
        try addAnnotation("modal", to: manager)
        #expect(manager.saveSync())
        let modalBytes = try Data(contentsOf: files.source)
        #expect(try annotationNames(at: files.source) == ["first", "modal"])
        delayed.run()
        #expect(await first.value)
        #expect(try Data(contentsOf: files.source) == modalBytes,
                "Older admitted work must not replace the completed synchronous save's bytes")
        #expect(try annotationNames(at: files.source) == ["first", "modal"])
        #expect(!manager.isDirty)
    }

    @Test(arguments: [false, true])
    func saveFollowingSaveAsUsesTheSuccessfulDestination(firstSaveAsFails: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = firstSaveAsFails ? files.source.appendingPathComponent("blocked.pdf") :
            files.directory.appendingPathComponent("renamed.pdf")
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("first", to: manager)
        let first = Task { await manager.saveAs(to: destination) }
        try #require(await scheduler.waitForAdmission(1))
        try addAnnotation("second", to: manager)
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        scheduler.drain()
        #expect(await first.value == !firstSaveAsFails)
        #expect(await second.value)
        let finalURL = firstSaveAsFails ? files.source : destination
        #expect(manager.documentURL == finalURL)
        #expect(try annotationNames(at: finalURL) == ["first", "second"])
        if !firstSaveAsFails { #expect(try annotationNames(at: files.source).isEmpty) }
        #expect(!manager.isDirty)
    }

    @Test
    func latestSaveAsRetainsItsIdentityAfterAnOlderContinuation() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let firstURL = files.directory.appendingPathComponent("first.pdf")
        let secondURL = files.directory.appendingPathComponent("second.pdf")
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("first", to: manager)
        let first = Task { await manager.saveAs(to: firstURL) }
        try #require(await scheduler.waitForAdmission(1))
        try addAnnotation("second", to: manager)
        let second = Task { await manager.saveAs(to: secondURL) }
        try #require(await scheduler.waitForAdmission(2))
        let newer = try #require(scheduler.takeLast())
        let older = try #require(scheduler.takeLast())
        newer.run()
        #expect(await second.value)
        older.run()
        #expect(await first.value)
        #expect(try annotationNames(at: firstURL) == ["first"])
        #expect(try annotationNames(at: secondURL) == ["first", "second"])
        #expect(manager.documentURL == secondURL)
        #expect(!manager.isDirty)
    }

    @Test(arguments: [false, true])
    func loadOrCloseFencesWritesAndRejectsRetiredSaveAsCompletion(closeInsteadOfLoad: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("old-copy.pdf")
        let replacement = files.directory.appendingPathComponent("replacement.pdf")
        try Data(contentsOf: files.source).write(to: replacement)
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("accepted", to: manager)
        let save = Task { await manager.saveAs(to: destination) }
        try #require(await scheduler.waitForAdmission(1))
        let delayed = try #require(scheduler.takeLast())
        if closeInsteadOfLoad {
            manager.closeDocument()
        } else {
            try load(replacement, into: manager)
            try addAnnotation("new identity edit", to: manager)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path),
                "The lifecycle boundary must finish already accepted physical writes")
        delayed.run()
        _ = await save.value
        #expect(try annotationNames(at: destination) == ["accepted"])
        if closeInsteadOfLoad {
            #expect(manager.document == nil)
            #expect(manager.documentURL == nil, "A late Save As must not resurrect a closed identity")
        } else {
            #expect(manager.documentURL == replacement)
            #expect(Set(manager.document?.page(at: 0)?.annotations.compactMap(\.contents) ?? []) == ["new identity edit"])
            #expect(manager.isDirty, "A retired save must not clear edits to the loaded replacement")
        }
    }

    @Test
    func failedLoadPreservesTheLivePDFAndItsPendingSave() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        let original = try #require(manager.document)
        try addAnnotation("kept", to: manager)
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let result = manager.loadDocument(from: files.directory.appendingPathComponent("missing.pdf"))
        if case .failed = result {} else { Issue.record("Missing PDF load unexpectedly succeeded") }
        #expect(manager.document === original)
        #expect(manager.documentURL == files.source)
        scheduler.drain()
        #expect(await save.value)
        #expect(try annotationNames(at: files.source) == ["kept"])
        #expect(!manager.isDirty)
    }

    @Test
    func failedWritesPreserveLiveEditsAndOriginalBytes() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let originalBytes = try Data(contentsOf: files.source)
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(fileWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                                 scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("unsaved", to: manager)
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        scheduler.drain()
        #expect(!(await save.value))
        #expect(!manager.saveSync())
        #expect(manager.isDirty)
        #expect(manager.documentURL == files.source)
        #expect(try Data(contentsOf: files.source) == originalBytes)
        #expect(manager.document?.page(at: 0)?.annotations.first?.contents == "unsaved")
    }

    @Test
    func reloadReadsTheAcceptedSnapshotBeforeReplacingTheLiveDocument() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = PDFManager(scheduleWrite: { scheduler.enqueue($0) })
        try load(files.source, into: manager)
        try addAnnotation("accepted", to: manager)
        let save = Task { await manager.saveWithCompletion() }
        try #require(await scheduler.waitForAdmission(1))
        try load(files.source, into: manager)
        #expect(manager.document?.page(at: 0)?.annotations.first?.contents == "accepted")
        scheduler.drain()
        let completion = await save.value
        #expect(completion.didWrite)
        #expect(!manager.acceptsSaveCompletion(completion))
        #expect(!manager.isDirty)
    }

    @Test
    func saveAsReceiptFollowsTheTransferredSession() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("renamed.pdf")
        let source = TabManager()
        source.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(source.activeTabID)
        let session = try #require(source.activeSession)
        let manager = try #require(session.pdfManager)
        try addAnnotation("transferred", to: manager)
        let completion = await manager.saveAsWithCompletion(to: destination)
        try #require(completion.didWrite)
        let target = TabManager()
        target.newMarkdownDocument()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(target, window: window)
        defer {
            WindowRegistry.shared.unregister(target)
            window.close()
        }
        try #require(source.moveTab(tabID, to: target, at: target.tabs.count, select: false, closeIfEmpty: false))
        let result = source.completePDFSave(session: session, completion: completion, saveAs: true)
        if case .success = result {} else { Issue.record("Transferred session lost its successful save receipt") }
        #expect(target.tabs.first { $0.id == tabID }?.documentURL == destination)
        #expect(target.tabs.first { $0.id == tabID }?.title == "renamed")
        #expect(target.tabID(for: destination) == tabID)
        #expect(source.tabs.allSatisfy { $0.id != tabID })
        #expect(try annotationNames(at: destination) == ["transferred"])
    }

    @Test
    func delayedSaveAsReceiptUsesLatestIdentityAndMigratesBookmarksOnce() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let firstURL = files.directory.appendingPathComponent("first.pdf")
        let latestURL = files.directory.appendingPathComponent("latest.pdf")
        let owner = TabManager()
        owner.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(owner.activeTabID)
        let session = try #require(owner.activeSession)
        let manager = try #require(session.pdfManager)
        let bookmarks = try #require(session.bookmarkManager)
        // A real persisted bookmark must follow the accepted final identity,
        // even when both callbacks arrive after the second Save As.
        let undo = try #require(session.undoManager)
        bookmarks.configure(pdfManager: manager, undoManagerProvider: { [weak undo] in undo })
        undo.beginUndoGrouping()
        bookmarks.addBookmark(at: 0)
        undo.endUndoGrouping()
        defer {
            for url in [files.source, firstURL, latestURL] {
                UserDefaults.standard.removeObject(forKey: "bookmarks:" + url.pageFlowCanonicalDocumentURL.path)
            }
        }
        let sourceKey = "bookmarks:" + files.source.pageFlowCanonicalDocumentURL.path
        let persisted = try #require(UserDefaults.standard.data(forKey: sourceKey),
                                     "Source bookmark must exist before migration is exercised")
        let originalBookmarks = try JSONDecoder().decode([BookmarkModel].self, from: persisted)
        try #require(originalBookmarks.map(\.pageIndex) == [0])
        bookmarks.loadBookmarks(for: files.source)
        try #require(bookmarks.isBookmarked(0))
        let first = await manager.saveAsWithCompletion(to: firstURL)
        let latest = await manager.saveAsWithCompletion(to: latestURL)
        try #require(first.didWrite && latest.didWrite)
        _ = owner.completePDFSave(session: session, completion: latest, saveAs: true)
        let stale = owner.completePDFSave(session: session, completion: first, saveAs: true)
        if case .cancelled = stale {} else { Issue.record("Older receipt surfaced as current") }
        #expect(owner.tabs.first { $0.id == tabID }?.documentURL == latestURL)
        #expect(owner.tabID(for: latestURL) == tabID)
        #expect(owner.tabID(for: firstURL) == nil)
        bookmarks.loadBookmarks(for: latestURL)
        #expect(bookmarks.isBookmarked(0))
    }

    @Test(arguments: [false, true])
    func oldSaveAsReceiptCannotRenameReplacedOrClosedPDF(closeInsteadOfReplace: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("old-save.pdf")
        let replacement = files.directory.appendingPathComponent("replacement.pdf")
        try Data(contentsOf: files.source).write(to: replacement)
        let owner = TabManager()
        owner.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(owner.activeTabID)
        let session = try #require(owner.activeSession)
        let manager = try #require(session.pdfManager)
        let completion = await manager.saveAsWithCompletion(to: destination)
        try #require(completion.didWrite)
        if closeInsteadOfReplace {
            owner.closeTab(tabID)
        } else {
            owner.openDocument(url: replacement, isSecurityScoped: false, replaceCurrent: true)
            try #require(owner.activeTabID == tabID)
            try #require(owner.activeSession?.pdfManager === manager,
                         "Replacement must exercise the reused PDFManager path")
            try addAnnotation("replacement edit", to: manager)
        }
        let result = owner.completePDFSave(session: session, completion: completion, saveAs: true)
        if case .cancelled = result {} else { Issue.record("Retired PDF accepted an old save receipt") }
        #expect(owner.tabs.allSatisfy { $0.documentURL != destination })
        if !closeInsteadOfReplace {
            #expect(owner.tabs.first { $0.id == tabID }?.documentURL == replacement)
            #expect(owner.tabs.first { $0.id == tabID }?.title == "replacement")
            #expect(manager.isDirty)
            #expect(manager.document?.page(at: 0)?.annotations.first?.contents == "replacement edit")
        }
    }

}
