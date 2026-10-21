import AppKit
import Foundation
import Testing
@testable import PageFlow

/// Exercises Save As through the command, close and quit owner boundaries.
/// The injected choice replaces only modal UI; the production save, identity
/// bookkeeping and registry lookups still execute against real scratch files.
@MainActor
struct SaveAsIdentityCollisionTests {
    enum Route: Sendable { case command, close, quit }

    struct Scenario: Sendable {
        let differentWindow: Bool
        let throughDirectoryAlias: Bool
        let route: Route
    }
    static let scenarios = [false, true].flatMap { differentWindow in
        [false, true].flatMap { throughDirectoryAlias in
            [Route.command, .close, .quit].map { route in
                Scenario(differentWindow: differentWindow, throughDirectoryAlias: throughDirectoryAlias, route: route)
            }
        }
    }

    @Test(arguments: scenarios)
    func saveAsPreservesAnAlreadyOpenCanonicalDestination(_ scenario: Scenario) async throws {
        let differentWindow = scenario.differentWindow
        let throughDirectoryAlias = scenario.throughDirectoryAlias
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-as-collision-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("target.md")
        let diskSource = Data("# Target\r\n\r\ndisk e\u{301} 😀\r\n".utf8)
        try diskSource.write(to: targetURL)
        let chosenURL: URL
        if throughDirectoryAlias {
            let alias = directory.appendingPathComponent("directory-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            chosenURL = alias.appendingPathComponent("target.md")
            try #require(chosenURL != targetURL)
        } else {
            chosenURL = targetURL
        }
        try #require(chosenURL.pageFlowCanonicalDocumentURL == targetURL.pageFlowCanonicalDocumentURL)
        try #require(Data(contentsOf: chosenURL) == diskSource)

        let sourceOwner = TabManager(createInitialTab: false)
        let targetOwner = differentWindow ? TabManager(createInitialTab: false) : sourceOwner
        await targetOwner.openDocument(url: targetURL, isSecurityScoped: false)?.value
        let targetSession = try #require(targetOwner.activeSession)
        let targetContent = try #require(targetSession.content.markdown)
        let targetDraft = "# Target\n\nunsaved target e\u{301} 😀\n"
        targetContent.documentManager.text = targetDraft
        let targetSaved = targetContent.documentManager.savedText
        if differentWindow {
            // Make focusing the existing target observable in either route.
            targetOwner.newMarkdownDocument()
        }
        sourceOwner.newMarkdownDocument()
        let sourceSession = try #require(sourceOwner.activeSession)
        let sourceContent = try #require(sourceSession.content.markdown)
        let sourceDraft = "# Source\n\nunsaved source é 😀\n"
        sourceContent.documentManager.text = sourceDraft
        let sourceSaved = sourceContent.documentManager.savedText
        try #require(sourceSession !== targetSession)
        try #require(sourceContent.documentManager.documentURL == nil)
        try #require(sourceContent.documentManager.isDirty && targetContent.documentManager.isDirty)
        try #require(targetOwner.activeTabID != targetSession.id)

        let owners = differentWindow ? [sourceOwner, targetOwner] : [sourceOwner]
        let windows = owners.map { _ in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        for (owner, window) in zip(owners, windows) {
            WindowRegistry.shared.register(owner, window: window)
        }
        defer {
            for (owner, window) in zip(owners, windows) {
                WindowRegistry.shared.unregister(owner)
                window.close()
            }
        }
        let originalIDs = owners.map { $0.tabs.map(\.id) }
        var saveChoices = 0
        var destinationChoices = 0
        let allowed: Bool
        switch scenario.route {
        case .command:
            let result = await sourceOwner.saveDocumentAs(sourceSession, to: chosenURL, isSecurityScoped: false, expectedDocument: sourceContent)
            if case .success = result { allowed = true } else { allowed = false }
            if case .failure(let message) = result { #expect(message.contains("open in another tab")) }
        case .close:
            allowed = sourceOwner.confirmDocumentClose(sourceSession, using: DocumentClosePrompt(
                decide: { _ in saveChoices += 1; return .save },
                saveURL: { _ in destinationChoices += 1; return chosenURL }
            ))
        case .quit:
            let quitDocument = try #require(sourceOwner.dirtyDocuments().first { $0.tabID == sourceSession.id })
            allowed = quitDocument.saveAsSync(to: chosenURL, isSecurityScoped: false)
        }

        #expect(saveChoices == (scenario.route == .close ? 1 : 0) && destinationChoices == (scenario.route == .close ? 1 : 0))
        #expect(!allowed, "Focusing an already-open destination must not approve closing an unsaved source")
        #expect(owners.map { $0.tabs.map(\.id) } == originalIDs)
        #expect(sourceOwner.sessions[sourceSession.id] === sourceSession)
        #expect(targetOwner.sessions[targetSession.id] === targetSession)
        #expect(sourceContent.documentManager.documentURL == nil)
        #expect(sourceContent.documentManager.text.utf8.elementsEqual(sourceDraft.utf8))
        #expect(sourceContent.documentManager.savedText.utf8.elementsEqual(sourceSaved.utf8))
        #expect(sourceContent.documentManager.isDirty)
        #expect(targetContent.documentManager.text.utf8.elementsEqual(targetDraft.utf8))
        #expect(targetContent.documentManager.savedText.utf8.elementsEqual(targetSaved.utf8))
        #expect(targetContent.documentManager.isDirty)
        #expect(try Data(contentsOf: targetURL) == diskSource)
        let canonicalOwners = owners.flatMap(\.tabs).filter {
            $0.documentURL?.pageFlowCanonicalDocumentURL == targetURL.pageFlowCanonicalDocumentURL
        }
        #expect(canonicalOwners.map(\.id) == [targetSession.id])
        #expect(targetOwner.activeTabID == targetSession.id)
    }

    /// A saved quit handle must publish the file identity even when termination
    /// is later cancelled. The other draft remains live throughout this boundary.
    @Test(arguments: [false, true])
    func quitSaveAsPublishesIdentityAndFollowsTheMovedSession(transfer: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quit-save-identity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.md")
        let source = TabManager(createInitialTab: false)
        let target = TabManager(createInitialTab: false)
        let opener = TabManager(createInitialTab: false)
        source.newMarkdownDocument()
        let session = try #require(source.activeSession)
        let content = try #require(session.content.markdown)
        let exactSource = "# Saved draft\n\nexact e\u{301} 😀\n"
        content.documentManager.text = exactSource
        target.newMarkdownDocument()
        let other = try #require(target.activeMarkdownContent)
        let otherSource = "other unsaved draft\n"
        other.documentManager.text = otherSource
        opener.newMarkdownDocument()
        opener.activeMarkdownContent?.documentManager.text = "separate opener draft\n"
        let owners = [source, target, opener]
        let windows = register(owners)
        defer { cleanup(owners, windows: windows) }
        let quitDocument = try #require(source.dirtyDocuments().first { $0.tabID == session.id })
        if transfer {
            try #require(source.moveTab(session.id, to: target, at: target.tabs.count, closeIfEmpty: false))
        }
        let liveOwner = transfer ? target : source
        let openerIDs = opener.tabs.map(\.id)

        #expect(quitDocument.saveAsSync(to: destination, isSecurityScoped: false))
        #expect(try Data(contentsOf: destination) == Data(exactSource.utf8))
        #expect(liveOwner.sessions[session.id] === session)
        #expect(content.documentManager.documentURL == destination)
        #expect(!content.documentManager.isDirty)
        #expect(liveOwner.tabID(for: destination) == session.id)
        #expect(liveOwner.tabs.first { $0.id == session.id }?.title == "saved")
        #expect(liveOwner.captureWindowSession()?.tabs.contains { $0.path == destination.pageFlowCanonicalDocumentURL.path } == true)
        #expect(other.documentManager.documentURL == nil && other.documentManager.isDirty)
        #expect(other.documentManager.text == otherSource)
        await opener.openDocument(url: destination, isSecurityScoped: false)?.value
        #expect(opener.tabs.map(\.id) == openerIDs, "Reopening the saved file must focus its existing session")
        #expect(liveOwner.activeTabID == session.id)
        #expect(owners.flatMap(\.tabs).filter { $0.documentURL?.pageFlowCanonicalDocumentURL == destination.pageFlowCanonicalDocumentURL }.map(\.id) == [session.id])
    }

    /// Only the first physical write pauses. Its accepted production request,
    /// filesystem replacement and completion still run normally.
    private final class SuspendedWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let entered = DispatchSemaphore(value: 0)
        private let proceed = DispatchSemaphore(value: 0)
        func write(_ data: Data, to url: URL, scratch: URL?) throws -> (modDate: Date, scratchDir: URL) {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            if first {
                entered.signal()
                guard proceed.wait(timeout: .now() + 10) == .success else { throw CocoaError(.fileWriteUnknown) }
            }
            return try MarkdownDocumentManager.writeData(data, to: url, reusingScratchDir: scratch)
        }

        func waitForPhysicalWrite() async -> Bool {
            await Task.detached { self.entered.wait(timeout: .now() + 10) == .success }.value
        }

        func release() { proceed.signal() }
    }

    private func register(_ owners: [TabManager]) -> [NSWindow] {
        owners.map { owner in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            WindowRegistry.shared.register(owner, window: window)
            return window
        }
    }

    private func cleanup(_ owners: [TabManager], windows: [NSWindow]) {
        for (owner, window) in zip(owners, windows) {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.close()
        }
    }

    private func suspendedSource(_ owner: TabManager, writer: SuspendedWriter) throws -> (TabSession, MarkdownContent) {
        owner.newMarkdownDocument()
        let session = try #require(owner.activeSession)
        let manager = MarkdownDocumentManager(fileWriter: { try writer.write($0, to: $1, scratch: $2) })
        let content = MarkdownContent(documentId: UUID().uuidString, documentManager: manager)
        session.content = .markdown(content)
        manager.text = "# Pending source\n\nexact e\u{301} 😀\n"
        try #require(manager.isDirty && manager.documentURL == nil)
        return (session, content)
    }

    /// Quit can synchronously drain a previously accepted command Save As;
    /// identity must be current before that command's async callback executes.
    @Test
    func quitSavePublishesIdentityAdoptedFromAPendingSaveAs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quit-pending-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.md")
        let destination = directory.appendingPathComponent("renamed.md")
        let originalBytes = Data("original on disk\n".utf8)
        try originalBytes.write(to: original)
        let writer = SuspendedWriter()
        let owner = TabManager(createInitialTab: false)
        let windows = register([owner])
        defer {
            writer.release()
            cleanup([owner], windows: windows)
            try? FileManager.default.removeItem(at: directory)
        }
        let (session, content) = try suspendedSource(owner, writer: writer)
        try content.documentManager.load(from: original)
        owner.applyOpenedDocument(tabID: session.id, url: original, isSecurityScoped: false, title: "original.md")
        content.documentManager.text = "accepted older snapshot\n"
        let quitDocument = try #require(owner.dirtyDocuments().first { $0.tabID == session.id })
        try #require(!quitDocument.needsSaveAs)
        let save = Task {
            await owner.saveDocumentAs(session, to: destination, isSecurityScoped: false, expectedDocument: content)
        }
        try #require(await writer.waitForPhysicalWrite())
        let latest = "latest quit snapshot e\u{301} 😀\n"
        content.documentManager.text = latest
        writer.release()

        #expect(quitDocument.saveSync())
        #expect(try Data(contentsOf: destination) == Data(latest.utf8))
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(owner.tabID(for: destination) == session.id)
        #expect(owner.tabID(for: original) == nil)
        #expect(owner.tabs.first { $0.id == session.id }?.title == "renamed")
        #expect(owner.captureWindowSession()?.tabs.contains { $0.path == destination.pageFlowCanonicalDocumentURL.path } == true)
        #expect(!content.documentManager.isDirty)
        _ = await save.value
    }

    @Test(arguments: [false, true])
    func openingAnAdmittedDestinationFollowsItsSourceUntilIdentityPublication(transfer: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-as-pending-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("destination.md")
        let staleBytes = Data("stale unopened destination\n".utf8)
        try staleBytes.write(to: destination)
        let writer = SuspendedWriter()
        let source = TabManager(createInitialTab: false)
        let target = TabManager(createInitialTab: false)
        let opener = TabManager(createInitialTab: false)
        target.newMarkdownDocument()
        opener.newMarkdownDocument()
        opener.activeMarkdownContent?.documentManager.text = "separate opener draft\n"
        let owners = [source, target, opener]
        let windows = register(owners)
        defer {
            writer.release()
            cleanup(owners, windows: windows)
            try? FileManager.default.removeItem(at: directory)
        }
        let (session, content) = try suspendedSource(source, writer: writer)
        let exactDraft = Data(content.documentManager.text.utf8)
        let openerIDs = opener.tabs.map(\.id)
        let save = Task {
            await source.saveDocumentAs(session, to: destination, isSecurityScoped: false, expectedDocument: content)
        }
        try #require(await writer.waitForPhysicalWrite())
        try #require(content.documentManager.hasPendingWrites)
        try #require(content.documentManager.documentURL == nil)
        try #require(Data(contentsOf: destination) == staleBytes)
        if transfer {
            try #require(source.moveTab(session.id, to: target, at: target.tabs.count, closeIfEmpty: false))
            try #require(target.sessions[session.id] === session && source.sessions[session.id] == nil)
        }
        let liveOwner = transfer ? target : source
        #expect(WindowRegistry.shared.isDocumentOpen(destination), "The accepted destination must be reserved before disk replacement")
        await opener.openDocument(url: destination, isSecurityScoped: false)?.value
        #expect(opener.tabs.map(\.id) == openerIDs, "Opening during Save As must not read a stale second editing session")
        #expect(liveOwner.activeTabID == session.id)
        #expect(liveOwner.sessions[session.id] === session)
        #expect(content.documentManager.text.utf8.elementsEqual(exactDraft))
        #expect(try Data(contentsOf: destination) == staleBytes)
        writer.release()
        let result = await save.value
        if case .success = result {} else { Issue.record("The admitted Save As did not complete successfully") }
        #expect(try Data(contentsOf: destination) == exactDraft)
        #expect(liveOwner.tabID(for: destination) == session.id)
        #expect(liveOwner.tabs.first { $0.id == session.id }?.documentURL == destination)
        #expect(!content.documentManager.isDirty)
        await opener.openDocument(url: destination, isSecurityScoped: false)?.value
        #expect(opener.tabs.map(\.id) == openerIDs)
        #expect(liveOwner.activeTabID == session.id)
        #expect(owners.flatMap(\.tabs).filter { $0.documentURL?.pageFlowCanonicalDocumentURL == destination.pageFlowCanonicalDocumentURL }.map(\.id) == [session.id])
    }

    @Test
    func failedSaveAsReleasesItsDestinationForARealOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-as-failure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let targetDirectory = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let destination = targetDirectory.appendingPathComponent("destination.md")
        let diskBytes = Data("unchanged real destination e\u{301} 😀\n".utf8)
        try diskBytes.write(to: destination)
        let writer = SuspendedWriter()
        let source = TabManager(createInitialTab: false)
        let opener = TabManager(createInitialTab: false)
        opener.newMarkdownDocument()
        opener.activeMarkdownContent?.documentManager.text = "separate opener draft\n"
        let owners = [source, opener]
        let windows = register(owners)
        defer {
            writer.release()
            cleanup(owners, windows: windows)
            try? FileManager.default.removeItem(at: directory)
        }
        let (session, content) = try suspendedSource(source, writer: writer)
        let draft = Array(content.documentManager.text.utf16)
        let save = Task {
            await source.saveDocumentAs(session, to: destination, isSecurityScoped: false, expectedDocument: content)
        }
        try #require(await writer.waitForPhysicalWrite())
        try #require(Data(contentsOf: destination) == diskBytes)
        #expect(WindowRegistry.shared.isDocumentOpen(destination))
        let preservedDirectory = directory.appendingPathComponent("preserved", isDirectory: true)
        try FileManager.default.moveItem(at: targetDirectory, to: preservedDirectory)
        try Data("blocked parent".utf8).write(to: targetDirectory)
        try #require((try targetDirectory.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true)
        try #require(Data(contentsOf: preservedDirectory.appendingPathComponent("destination.md")) == diskBytes)
        writer.release()
        let result = await save.value
        if case .failure = result {} else { Issue.record("The real writer failure was not delivered") }
        #expect(!WindowRegistry.shared.isDocumentOpen(destination), "A failed write must not leave a ghost destination claim")
        #expect(try Data(contentsOf: preservedDirectory.appendingPathComponent("destination.md")) == diskBytes)
        #expect(source.sessions[session.id] === session)
        #expect(content.documentManager.documentURL == nil && content.documentManager.isDirty)
        #expect(Array(content.documentManager.text.utf16) == draft)
        try FileManager.default.removeItem(at: targetDirectory)
        try FileManager.default.moveItem(at: preservedDirectory, to: targetDirectory)
        try #require(Data(contentsOf: destination) == diskBytes)
        await opener.openDocument(url: destination, isSecurityScoped: false)?.value
        let opened = try #require(opener.activeMarkdownContent)
        #expect(opened !== content)
        #expect(opener.tabID(for: destination) == opener.activeTabID)
        #expect(Data(opened.documentManager.text.utf8) == diskBytes)
        #expect(try Data(contentsOf: destination) == diskBytes)
    }

    @Test(arguments: [false, true])
    func saveAsToTheSourcesOwnCanonicalURLRemainsAllowed(throughDirectoryAlias: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-as-own-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("source.md")
        try Data("original\n".utf8).write(to: destination)
        let chosen: URL
        if throughDirectoryAlias {
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            chosen = alias.appendingPathComponent("source.md")
        } else { chosen = destination }
        let owner = TabManager(createInitialTab: false)
        await owner.openDocument(url: destination, isSecurityScoped: false)?.value
        let windows = register([owner])
        defer { cleanup([owner], windows: windows) }
        let session = try #require(owner.activeSession)
        let content = try #require(session.content.markdown)
        content.documentManager.text = "own updated e\u{301} 😀\n"
        let result = await owner.saveDocumentAs(session, to: chosen, isSecurityScoped: false, expectedDocument: content)
        if case .success = result {} else { Issue.record("Saving to the same canonical source was refused") }
        #expect(owner.tabs.map(\.id) == [session.id])
        #expect(owner.tabID(for: destination) == session.id)
        #expect(try Data(contentsOf: destination) == Data(content.documentManager.text.utf8))
        #expect(!content.documentManager.isDirty)
    }

}
