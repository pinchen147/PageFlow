import AppKit
import Testing
@testable import PageFlow

@MainActor
@Suite("Asynchronous document close", .serialized)
struct AsyncDocumentCloseTests {
    nonisolated private final class WriterGate: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0)
        private let proceed = DispatchSemaphore(value: 0)
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        func write(_ data: Data, to url: URL, scratch: URL?) throws -> (modDate: Date, scratchDir: URL) {
            entered.signal()
            guard proceed.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
            if fails { throw CocoaError(.fileWriteNoPermission) }
            return try MarkdownDocumentManager.writeData(data, to: url, reusingScratchDir: scratch)
        }
        func waitForWrite() async -> Bool {
            await Task.detached { self.entered.wait(timeout: .now() + 5) == .success }.value
        }
        func release() { proceed.signal() }
    }

    @MainActor private final class Fixture {
        let gate: WriterGate
        let owner = TabManager(createInitialTab: false)
        let window: NSWindow
        let content: MarkdownContent
        let session: TabSession
        let directory: URL
        var target: URL { directory.appendingPathComponent("saved.md") }
        init(fails: Bool = false) throws {
            gate = WriterGate(fails: fails)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("async-close-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            owner.newMarkdownDocument()
            session = try #require(owner.activeSession)
            let gate = gate
            let manager = MarkdownDocumentManager(fileWriter: { try gate.write($0, to: $1, scratch: $2) })
            content = MarkdownContent(documentId: UUID().uuidString, documentManager: manager)
            session.content = .markdown(content)
            manager.text = "Approved draft e\u{301} 😀\n"
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            WindowRegistry.shared.register(owner, window: window)
        }
        var prompt: DocumentClosePrompt { DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in self.target }) }
        func finish() {
            gate.release()
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "the close request did not settle while storage was suspended")
    }

    @Test("window Save waits off the UI actor and preserves an edit made during the write")
    func changedSourceRevokesWindowClose() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        var allowed: Bool?
        let close = Task { allowed = await fixture.owner.confirmWindowCloseInBackground(using: fixture.prompt) }
        try #require(await fixture.gate.waitForWrite())
        #expect(allowed == nil)
        fixture.content.documentManager.text = "New edit after the approved snapshot\n"
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        fixture.gate.release()
        await close.value
        #expect(allowed == false)
        #expect(fixture.content.documentManager.isDirty)
        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == "Approved draft e\u{301} 😀\n")
        #expect(fixture.content.documentManager.text == "New edit after the approved snapshot\n")
    }

    @Test("Cancel stops waiting for close without cancelling a dispatched write")
    func cancellationLeavesTheDocumentOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        var allowed: Bool?
        let close = Task { allowed = await fixture.owner.confirmWindowCloseInBackground(using: fixture.prompt) }
        try #require(await fixture.gate.waitForWrite())
        close.cancel()
        try await waitUntil { allowed != nil }
        #expect(allowed == false)
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        #expect(!fixture.content.documentManager.isClosed)
        #expect(fixture.content.documentManager.hasPendingWrites)
        fixture.content.documentManager.text = "Edit after cancelling close\n"
        #expect(fixture.content.documentManager.isDirty)
        fixture.gate.release()
        await close.value
    }

    @Test("a failed asynchronous close Save retains the draft and its owner")
    func failedSaveKeepsTheWindowOpen() async throws {
        let fixture = try Fixture(fails: true)
        defer { fixture.finish() }
        let close = Task { await fixture.owner.confirmWindowCloseInBackground(using: fixture.prompt) }
        try #require(await fixture.gate.waitForWrite())
        fixture.gate.release()
        #expect(!(await close.value))
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        #expect(fixture.content.documentManager.isDirty)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test("a recovered draft arriving while quit waits invalidates its admitted membership")
    func newDocumentRevokesPendingQuit() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        let delegate = try #require(AppDelegate.shared)
        let quit = Task { await delegate.confirmTerminationInBackground(using: fixture.prompt) }
        try #require(await fixture.gate.waitForWrite())
        fixture.owner.restoreRecoveredMarkdown(.init(id: UUID(), title: "New arrival", source: "Unreviewed draft", updatedAt: Date()))
        fixture.gate.release()
        #expect(await quit.value == .terminateCancel)
        #expect(!delegate.terminationApproved)
        #expect(fixture.owner.tabs.count == 2)
        #expect(fixture.owner.activeMarkdownContent?.documentManager.text == "Unreviewed draft")
        #expect(fixture.owner.activeMarkdownContent?.documentManager.isDirty == true)
    }
    @Test("Cmd-W uses asynchronous approval and keeps an edited tab open")
    func tabCloseDoesNotBlockTheUIActor() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.owner.closeTab(fixture.session.id, using: fixture.prompt)
        try #require(await fixture.gate.waitForWrite())
        fixture.content.documentManager.text = "Edit while Cmd-W is waiting\n"
        fixture.gate.release()
        try await waitUntil { fixture.owner.pendingTabCloses[fixture.session.id] == nil }
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        #expect(fixture.content.documentManager.isDirty)
        #expect(!fixture.content.documentManager.isClosed)
    }

    @Test("the native close delegate defers approval and commits one approved close")
    func nativeWindowCloseUsesTheAsyncRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        // Install this component directly; the registry still owns the actual
        // window/session teardown exercised by its windowWillClose callback.
        fixture.window.delegate = nil
        let gate = WindowCloseCoordinator(window: fixture.window, manager: fixture.owner,
            prompt: DocumentClosePrompt(decide: { _ in .discard }, saveURL: { _ in nil }))
        #expect(!gate.windowShouldClose(fixture.window))
        try await waitUntil { fixture.owner.tabs.isEmpty }
        #expect(WindowRegistry.shared.window(for: fixture.owner) == nil)
        #expect(fixture.content.documentManager.isClosed)
    }

    @Test("Cancel abandons quit while its accepted physical save continues")
    func cancellationLeavesQuitUnapproved() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        let delegate = try #require(AppDelegate.shared)
        var reply: NSApplication.TerminateReply?
        let quit = Task { reply = await delegate.confirmTerminationInBackground(using: fixture.prompt) }
        try #require(await fixture.gate.waitForWrite())
        quit.cancel()
        try await waitUntil { reply != nil }
        #expect(reply == .terminateCancel)
        #expect(!delegate.terminationApproved)
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        #expect(fixture.content.documentManager.hasPendingWrites)
        fixture.gate.release()
        await quit.value
    }

    @Test("Cancel revokes admission even when an asynchronous preflight later succeeds")
    func cancellationCannotDispatchALaterWrite() async throws {
        var preflight: CheckedContinuation<Void, Never>?
        var dispatched = false
        var operationFinished = false
        var reply: Bool?
        let close = Task {
            reply = await DocumentCloseOperation.wait { isWaiting in
                defer { operationFinished = true }
                await withCheckedContinuation { preflight = $0 }
                guard isWaiting() else { return false }
                dispatched = true
                return true
            }
        }
        try await waitUntil { preflight != nil }
        close.cancel()
        try await waitUntil { reply != nil }
        #expect(reply == false)
        preflight?.resume()
        preflight = nil
        try await waitUntil { operationFinished }
        #expect(!dispatched)
        await close.value
    }

    @Test("Quit reveals the untitled draft whose Save As panel is being shown")
    func saveAsPanelBelongsToTheVisibleDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.owner.newMarkdownDocument()
        fixture.owner.activeMarkdownContent?.documentManager.text = "A different untitled draft"
        #expect(fixture.owner.activeSession !== fixture.session)
        let delegate = try #require(AppDelegate.shared)
        var panelSession: TabSession?
        let reply = await delegate.confirmTerminationInBackground(using: DocumentClosePrompt(
            decide: { _ in .save }, saveURL: { _ in
                panelSession = fixture.owner.activeSession
                return nil
            }))
        #expect(panelSession === fixture.session)
        #expect(reply == .terminateCancel)
        #expect(!fixture.content.documentManager.hasPendingWrites)
    }

    @Test("native clean quit persists the current reading zoom before approval")
    func cleanQuitPersistsReadingState() throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try Data("Clean reading document\n".utf8).write(to: fixture.target)
        try fixture.content.documentManager.load(from: fixture.target)
        fixture.content.handleMagnificationChanged(1.75)
        #expect(!fixture.content.documentManager.isDirty)
        let delegate = try #require(AppDelegate.shared)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
        #expect(DocumentStateStore.shared.state(for: fixture.target)?.markdownScaleFactor == 1.75)
    }

    private func secondDraft(in fixture: Fixture, gate: WriterGate) throws -> MarkdownContent {
        fixture.owner.newMarkdownDocument()
        let session = try #require(fixture.owner.activeSession)
        let manager = MarkdownDocumentManager(fileWriter: { try gate.write($0, to: $1, scratch: $2) })
        let content = MarkdownContent(documentId: UUID().uuidString, documentManager: manager)
        manager.text = "Second approved draft\n"
        session.content = .markdown(content)
        return content
    }

    @Test("a late same-source Save As revokes final approval instead of leaving a write behind", arguments: ["window", "quit"])
    func lateSaveAsRevokesFinalApproval(_ route: String) async throws {
        let fixture = try Fixture()
        let secondGate = WriterGate()
        defer { secondGate.release(); fixture.finish() }
        _ = try secondDraft(in: fixture, gate: secondGate)
        let delegate = try #require(AppDelegate.shared)
        let secondURL = fixture.directory.appendingPathComponent("second.md")
        let lateURL = fixture.directory.appendingPathComponent("late.md")
        var panels = 0
        let prompt = DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in
            panels += 1
            return panels == 1 ? fixture.target : secondURL
        })
        fixture.gate.release()
        let close = Task {
            if route == "window" { return await fixture.owner.confirmWindowCloseInBackground(using: prompt) }
            return await delegate.confirmTerminationInBackground(using: prompt) == .terminateNow
        }
        try #require(await secondGate.waitForWrite())
        // Consume the completed first write's entry before observing the late one.
        try #require(await fixture.gate.waitForWrite())
        let late = Task { await fixture.content.documentManager.saveAsWithCompletion(to: lateURL) }
        try #require(await fixture.gate.waitForWrite())
        try #require(fixture.content.documentManager.hasPendingWrites)
        secondGate.release()
        #expect(!(await close.value))
        #expect(fixture.content.documentManager.hasPendingWrites)
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        if route == "quit" { #expect(!delegate.terminationApproved) }
        fixture.gate.release()
        #expect(await late.value.didWrite)
    }

    @Test("initial Save As receipts may change both URLs while one barrier waits", arguments: ["window", "quit"])
    func concurrentInitialSaveAsReceiptsKeepTheirApproval(_ route: String) async throws {
        let fixture = try Fixture()
        let secondGate = WriterGate()
        defer { secondGate.release(); fixture.finish() }
        let second = try secondDraft(in: fixture, gate: secondGate)
        let secondURL = fixture.directory.appendingPathComponent("second.md")
        let firstSave = Task { await fixture.content.documentManager.saveAsWithCompletion(to: fixture.target) }
        let secondSave = Task { await second.documentManager.saveAsWithCompletion(to: secondURL) }
        try #require(await fixture.gate.waitForWrite())
        try #require(await secondGate.waitForWrite())
        let delegate = try #require(AppDelegate.shared)
        var began = false
        var decisions = 0
        let prompt = DocumentClosePrompt(decide: { _ in decisions += 1; return .cancel }, saveURL: { _ in nil })
        let close = Task {
            began = true
            if route == "window" { return await fixture.owner.confirmWindowCloseInBackground(using: prompt) }
            return await delegate.confirmTerminationInBackground(using: prompt) == .terminateNow
        }
        try await waitUntil { began }
        secondGate.release()
        #expect(await secondSave.value.didWrite)
        fixture.gate.release()
        #expect(await firstSave.value.didWrite)
        #expect(await close.value)
        #expect(decisions == 0)
        #expect(fixture.content.documentManager.documentURL == fixture.target)
        #expect(second.documentManager.documentURL == secondURL)
        #expect(!fixture.content.documentManager.hasPendingWrites && !second.documentManager.hasPendingWrites)
    }

    @Test("quit Save reports an unreadable backing path and preserves the draft")
    func unreadableBackingFileReportsQuitFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try Data("Original disk source\n".utf8).write(to: fixture.target)
        try fixture.content.documentManager.load(from: fixture.target)
        let draft = "Local draft must survive a failed disk read\n"
        fixture.content.documentManager.text = draft
        try FileManager.default.removeItem(at: fixture.target)
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
        let delegate = try #require(AppDelegate.shared)

        #expect(await delegate.confirmTerminationInBackground(using: fixture.prompt) == .terminateCancel)
        #expect(!delegate.terminationApproved)
        #expect(fixture.owner.sessions[fixture.session.id] === fixture.session)
        #expect(fixture.content.documentManager.text == draft)
        #expect(fixture.content.documentManager.isDirty)
        #expect(!fixture.content.documentManager.hasPendingWrites)
        let message = try #require(fixture.owner.transientToast?.message)
        #expect(message.localizedCaseInsensitiveContains("read"))
    }

    @Test("cancelling close from an external-change decision cannot apply Reload afterward")
    func cancellationRevokesTheExternalReload() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        try Data("Original disk source\n".utf8).write(to: fixture.target)
        try fixture.content.documentManager.load(from: fixture.target)
        fixture.content.documentManager.text = "Local draft must survive Cancel\n"
        try Data("New external source\n".utf8).write(to: fixture.target)
        var close: Task<Bool, Never>?
        var operationFinished = false
        fixture.owner.externalChangePrompt = { _, _ in
            close?.cancel()
            return .reload
        }
        close = Task {
            await DocumentCloseOperation.wait { isWaiting in
                defer { operationFinished = true }
                return await DirtyDoc(session: fixture.session, owner: fixture.owner).saveInBackground(whileApproved: isWaiting)
            }
        }
        #expect(await close?.value == false)
        try await waitUntil { operationFinished }
        #expect(fixture.content.documentManager.text == "Local draft must survive Cancel\n")
        #expect(fixture.content.documentManager.isDirty)
        #expect(!fixture.content.documentManager.hasPendingWrites)
        #expect(try String(contentsOf: fixture.target, encoding: .utf8) == "New external source\n")
    }

}
