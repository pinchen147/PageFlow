import Foundation
import AppKit
import Testing
@testable import PageFlow

@MainActor
struct MarkdownSaveOrderingTests {
    /// Pauses the first real replacement while the caller performs another
    /// document action. Deadlock bounds fail the operation; they do not establish
    /// whether writes are ordered or whether the final bytes are correct.
    private final class WriterGate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let entered = DispatchSemaphore(value: 0)
        private let proceed = DispatchSemaphore(value: 0)

        func write(_ data: Data, to url: URL, scratch: URL?) throws -> (modDate: Date, scratchDir: URL) {
            lock.lock()
            calls += 1
            let isFirst = calls == 1
            lock.unlock()
            if isFirst {
                entered.signal()
                guard proceed.wait(timeout: .now() + 10) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return try MarkdownDocumentManager.writeData(data, to: url, reusingScratchDir: scratch)
        }

        func waitForFirstWrite() async -> Bool {
            await Task.detached { self.entered.wait(timeout: .now() + 10) == .success }.value
        }

        func release() { proceed.signal() }
    }

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

    private func scheduledManager(_ scheduler: ManualScheduler) -> MarkdownDocumentManager {
        MarkdownDocumentManager(scheduleWrite: { scheduler.enqueue($0) })
    }

    private func fixture() throws -> (directory: URL, source: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdown-save-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.md")
        try Data("original\r\n".utf8).write(to: source)
        return (directory, source)
    }

    /// Undo back to the old saved text while a save still writes: disk will
    /// hold the newer text, so close and quit must keep prompting.
    @Test
    func undoingToTheSavedTextDuringAWriteStaysDirty() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "edited\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        #expect(!manager.isDirty, "the buffer matches the write in flight")
        manager.text = "original\n"
        #expect(manager.isDirty)
        scheduler.drain()
        #expect(await save.value)
        #expect(manager.isDirty, "disk now holds the edit, the buffer the undone text")
    }

    @Test
    func aFailedWriteLeavesTheBufferDirtyAgainstDisk() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        struct Refused: Error {}
        let manager = MarkdownDocumentManager(fileWriter: { _, _, _ in throw Refused() })
        try manager.load(from: files.source)
        manager.text = "edited\n"
        #expect(!(await manager.save()))
        #expect(manager.isDirty)
    }

    @Test
    func editsDuringAWriteStayDirtyAgainstTheWrittenSnapshot() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let gate = WriterGate()
        defer { gate.release() }
        let manager = MarkdownDocumentManager(fileWriter: { try gate.write($0, to: $1, scratch: $2) })
        try manager.load(from: files.source)
        manager.text = "first snapshot\n"
        let save = Task { await manager.save() }
        #expect(await gate.waitForFirstWrite())
        manager.text = "later unsaved edit\n"
        gate.release()
        #expect(await save.value)
        #expect(try Data(contentsOf: files.source) == Data("first snapshot\r\n".utf8))
        #expect(manager.savedText == "first snapshot\n")
        #expect(manager.text == "later unsaved edit\n")
        #expect(manager.isDirty)
    }

    @Test
    func newerKeepDecisionForTheSameFileSurvivesAnOlderSave() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let gate = WriterGate()
        defer { gate.release() }
        let manager = MarkdownDocumentManager(fileWriter: { try gate.write($0, to: $1, scratch: $2) })
        try manager.load(from: files.source)
        let save = Task { await manager.save() }
        #expect(await gate.waitForFirstWrite())
        try Data("external\n".utf8).write(to: files.source)
        manager.keepLocalVersionIgnoringDisk()
        gate.release()
        #expect(await save.value)
        #expect(try Data(contentsOf: files.source) == Data("original\r\n".utf8))
        #expect(manager.isDirty, "A write requested before Keep must not acknowledge the newer decision")
    }

    @Test(arguments: [false, true])
    func keepAfterPhysicalSaveSurvivesItsDelayedCompletion(newerExternal: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "accepted local A\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let physicalWrite = try #require(scheduler.takeLast())

        // Running on the main actor finishes the actual disk write, but its
        // awaiting completion cannot apply manager state until this turn yields.
        physicalWrite.run()
        try #require(Data(contentsOf: files.source) == Data("accepted local A\r\n".utf8))
        try #require(manager.hasPendingWrites)
        try #require(manager.savedText == "original\n", "The old completion must still be pending")
        let externalBytes = Data("external B e\u{301} 😀\r\n".utf8)
        try externalBytes.write(to: files.source, options: .atomic)
        try #require(Data(contentsOf: files.source) == externalBytes)
        try #require(manager.diskWasModifiedExternally())
        manager.keepLocalVersionIgnoringDisk()
        try #require(!manager.diskWasModifiedExternally(), "Keep must acknowledge the actual external source")
        try #require(manager.isDirty && manager.hasPendingWrites)
        let finalDiskBytes = newerExternal ? Data("unacknowledged external C\r\n".utf8) : externalBytes
        if newerExternal { try finalDiskBytes.write(to: files.source, options: .atomic) }

        #expect(await save.value)
        #expect(try Data(contentsOf: files.source) == finalDiskBytes)
        #expect(manager.text == "accepted local A\n")
        #expect(manager.savedText == "accepted local A\n")
        #expect(manager.isDirty, "The older completion must preserve the newer overwrite decision")
        #expect(manager.diskWasModifiedExternally() == newerExternal,
                "The older completion must preserve Keep's acknowledgment without accepting a later external source")
        #expect(manager.diskWasModifiedExternally() == newerExternal)
    }

    @Test
    func physicalSaveAfterKeepIsNotReportedAsANewExternalChange() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "accepted local A\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let physicalWrite = try #require(scheduler.takeLast())

        // This ordering reverses the first case: Keep observes B before the
        // already-accepted production writer physically installs its own A.
        let externalBytes = Data("external B e\u{301} 😀\r\n".utf8)
        try externalBytes.write(to: files.source, options: .atomic)
        try #require(Data(contentsOf: files.source) == externalBytes)
        try #require(manager.diskWasModifiedExternally())
        manager.keepLocalVersionIgnoringDisk()
        try #require(!manager.diskWasModifiedExternally())
        try #require(manager.isDirty && manager.hasPendingWrites)
        physicalWrite.run()
        try #require(Data(contentsOf: files.source) == Data("accepted local A\r\n".utf8))
        try #require(manager.savedText == "original\n", "The physical write must precede its manager completion")

        #expect(await save.value)
        #expect(try Data(contentsOf: files.source) == Data("accepted local A\r\n".utf8))
        #expect(manager.text == "accepted local A\n")
        #expect(manager.savedText == "accepted local A\n")
        #expect(manager.isDirty, "An older accepted save must not clear the newer Keep decision")
        #expect(!manager.diskWasModifiedExternally(), "A production save installed after Keep is our own write")
        #expect(!manager.diskWasModifiedExternally())
    }

    @Test
    func saveAsResolvesTheOldIdentitysKeepDecision() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("copy.md")
        let gate = WriterGate()
        defer { gate.release() }
        let manager = MarkdownDocumentManager(fileWriter: { try gate.write($0, to: $1, scratch: $2) })
        try manager.load(from: files.source)
        let save = Task { await manager.saveAs(to: destination) }
        #expect(await gate.waitForFirstWrite())
        try Data("external source\n".utf8).write(to: files.source)
        manager.keepLocalVersionIgnoringDisk()
        gate.release()
        #expect(await save.value)
        #expect(try Data(contentsOf: files.source) == Data("external source\n".utf8))
        #expect(try Data(contentsOf: destination) == Data("original\r\n".utf8))
        #expect(manager.documentURL == destination)
        #expect(manager.savedText == manager.text)
        #expect(!manager.isDirty, "The successfully written new identity has no pending overwrite of the old file")
    }

    @Test
    func newerAsyncSaveWinsEvenWhenItsScheduledWorkRunsFirst() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "first snapshot\n"
        let first = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        manager.text = "second snapshot\n"
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        let newerJob = try #require(scheduler.takeLast())
        let olderJob = try #require(scheduler.takeLast())
        newerJob.run()
        #expect(await second.value)
        olderJob.run()
        #expect(await first.value)
        #expect(try Data(contentsOf: files.source) == Data("second snapshot\r\n".utf8))
        #expect(manager.savedText == "second snapshot\n")
        #expect(!manager.isDirty)
    }

    @Test
    func synchronousSaveFencesPreviouslyAdmittedAsyncWork() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "older async snapshot\n"
        let first = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let delayedJob = try #require(scheduler.takeLast())
        manager.text = "modal snapshot\n"
        #expect(manager.saveSync())
        #expect(try Data(contentsOf: files.source) == Data("modal snapshot\r\n".utf8))
        delayedJob.run()
        #expect(await first.value)
        #expect(try Data(contentsOf: files.source) == Data("modal snapshot\r\n".utf8),
                "Older scheduled work must not overwrite a completed modal save")
        #expect(manager.savedText == "modal snapshot\n")
        #expect(!manager.isDirty)
    }

    @Test(arguments: [false, true])
    func saveFollowingSaveAsUsesItsSuccessfulIdentity(firstSaveAsFails: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        // A file cannot be the parent directory of the failing destination.
        let destination = firstSaveAsFails ? files.source.appendingPathComponent("blocked.md") :
            files.directory.appendingPathComponent("renamed.md")
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "save as snapshot\n"
        let first = Task { await manager.saveAs(to: destination) }
        try #require(await scheduler.waitForAdmission(1))
        manager.text = "subsequent save\n"
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        scheduler.drain()
        #expect(await first.value == !firstSaveAsFails)
        #expect(await second.value)
        let finalURL = firstSaveAsFails ? files.source : destination
        #expect(manager.documentURL == finalURL)
        #expect(try Data(contentsOf: finalURL) == Data("subsequent save\r\n".utf8))
        if !firstSaveAsFails {
            #expect(try Data(contentsOf: files.source) == Data("original\r\n".utf8),
                    "Save submitted after Save As must not keep writing the old identity")
        }
        #expect(manager.savedText == "subsequent save\n")
        #expect(!manager.isDirty)
    }

    @Test
    func laterSaveAsOwnsIdentityRegardlessOfContinuationOrder() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let firstURL = files.directory.appendingPathComponent("first.md")
        let secondURL = files.directory.appendingPathComponent("second.md")
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "first copy\n"
        let first = Task { await manager.saveAs(to: firstURL) }
        try #require(await scheduler.waitForAdmission(1))
        manager.text = "second copy\n"
        let second = Task { await manager.saveAs(to: secondURL) }
        try #require(await scheduler.waitForAdmission(2))
        let newerJob = try #require(scheduler.takeLast())
        let olderJob = try #require(scheduler.takeLast())
        newerJob.run()
        #expect(await second.value)
        olderJob.run()
        #expect(await first.value)
        #expect(try Data(contentsOf: firstURL) == Data("first copy\r\n".utf8))
        #expect(try Data(contentsOf: secondURL) == Data("second copy\r\n".utf8))
        #expect(manager.documentURL == secondURL)
        #expect(manager.savedText == "second copy\n")
        #expect(!manager.isDirty)
    }

    @Test
    func loadFencesOldWritesAndRejectsTheirLaterModelCompletion() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let replacement = files.directory.appendingPathComponent("replacement.md")
        try Data("new identity\n".utf8).write(to: replacement)
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "accepted save\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let delayedJob = try #require(scheduler.takeLast())
        try manager.load(from: replacement)
        #expect(try Data(contentsOf: files.source) == Data("accepted save\r\n".utf8),
                "Load must finish previously accepted physical writes before changing identity")
        delayedJob.run()
        _ = await save.value
        #expect(manager.documentURL == replacement)
        #expect(manager.text == "new identity\n")
        #expect(manager.savedText == "new identity\n")
        #expect(manager.fidelity.lineEnding == .lf)
        #expect(!manager.isDirty)
    }

    @Test
    func reloadReadsAfterPreviouslyAcceptedSaveAndRetiresItsCompletion() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "accepted save\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let delayedJob = try #require(scheduler.takeLast())
        manager.text = "discard this draft\n"
        try manager.reload()
        delayedJob.run()
        _ = await save.value
        #expect(try Data(contentsOf: files.source) == Data("accepted save\r\n".utf8))
        #expect(manager.text == "accepted save\n")
        #expect(manager.savedText == "accepted save\n")
        #expect(!manager.isDirty)
    }

    @Test
    func closeFinishesAcceptedWritesBeforeReturningAndRetiresCallbacks() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        manager.text = "accepted save\n"
        let save = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        let delayedJob = try #require(scheduler.takeLast())
        manager.close()
        let baselineAtClose = manager.savedText
        #expect(try Data(contentsOf: files.source) == Data("accepted save\r\n".utf8))
        delayedJob.run()
        _ = await save.value
        #expect(try Data(contentsOf: files.source) == Data("accepted save\r\n".utf8))
        #expect(manager.savedText == baselineAtClose, "A closed document must not accept a later save callback")
    }

    @Test
    func queuedSaveKeepsAnEarlierUTF8Downgrade() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try Data([0x68, 0xE9, 0x0A]).write(to: files.source)
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        try manager.load(from: files.source)
        #expect(manager.fidelity.encoding == .windowsCP1252)
        manager.text = "h😀é\n"
        let first = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(1))
        manager.text = "hé\n"
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        scheduler.drain()
        #expect(await first.value)
        #expect(await second.value)
        #expect(try Data(contentsOf: files.source) == Data("hé\n".utf8))
        #expect(manager.fidelity.savedAsDowngradedUTF8)
        #expect(manager.savedText == "hé\n")
        #expect(!manager.isDirty)
    }


    @Test
    func saveAsCompletionFollowsTheTransferredContentOwner() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("renamed.md")
        let source = TabManager()
        source.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(source.activeTabID)
        let session = try #require(source.activeSession)
        let content = try #require(source.activeMarkdownContent)
        let completion = await content.documentManager.saveAsWithCompletion(to: destination)
        try #require(completion.didWrite)
        let target = TabManager()
        target.newMarkdownDocument()
        let targetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: [.titled], backing: .buffered, defer: true)
        targetWindow.isReleasedWhenClosed = false
        WindowRegistry.shared.register(target, window: targetWindow)
        defer {
            WindowRegistry.shared.unregister(target)
            targetWindow.close()
        }
        try #require(source.moveTab(tabID, to: target, at: target.tabs.count, select: false, closeIfEmpty: false))
        _ = source.completeMarkdownSave(session: session, content: content, completion: completion, saveAs: true)
        let moved = try #require(target.tabs.first { $0.id == tabID })
        #expect(moved.documentURL == destination)
        #expect(moved.title == "renamed")
        #expect(target.tabID(for: destination) == tabID)
        #expect(source.tabs.allSatisfy { $0.id != tabID })
        #expect(try Data(contentsOf: destination) == Data("original\r\n".utf8))
    }

    @Test
    func olderSaveAsCompletionUsesTheLatestCommittedIdentity() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let firstURL = files.directory.appendingPathComponent("first.md")
        let latestURL = files.directory.appendingPathComponent("latest.md")
        let owner = TabManager()
        owner.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(owner.activeTabID)
        let session = try #require(owner.activeSession)
        let content = try #require(owner.activeMarkdownContent)
        let first = await content.documentManager.saveAsWithCompletion(to: firstURL)
        let latest = await content.documentManager.saveAsWithCompletion(to: latestURL)
        try #require(first.didWrite && latest.didWrite)
        _ = owner.completeMarkdownSave(session: session, content: content, completion: latest, saveAs: true)
        _ = owner.completeMarkdownSave(session: session, content: content, completion: first, saveAs: true)
        #expect(owner.tabs.first { $0.id == tabID }?.documentURL == latestURL)
        #expect(owner.tabs.first { $0.id == tabID }?.title == "latest")
        #expect(owner.tabID(for: latestURL) == tabID)
        #expect(owner.tabID(for: firstURL) == nil)
    }

    @Test(arguments: [false, true])
    func staleSaveAsCompletionCannotRenameReplacedOrClosedContent(closeInsteadOfReplace: Bool) async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("old-save.md")
        let replacement = files.directory.appendingPathComponent("replacement.md")
        try Data("replacement source\n".utf8).write(to: replacement)
        let owner = TabManager()
        owner.openDocument(url: files.source, isSecurityScoped: false)
        let tabID = try #require(owner.activeTabID)
        let session = try #require(owner.activeSession)
        let oldContent = try #require(owner.activeMarkdownContent)
        let completion = await oldContent.documentManager.saveAsWithCompletion(to: destination)
        try #require(completion.didWrite)
        if closeInsteadOfReplace {
            owner.closeTab(tabID)
        } else {
            owner.openDocument(url: replacement, isSecurityScoped: false, replaceCurrent: true)
            try #require(owner.activeTabID == tabID)
            try #require(owner.activeMarkdownContent !== oldContent)
        }
        let result = owner.completeMarkdownSave(session: session, content: oldContent,
                                                completion: completion, saveAs: true)
        if case .cancelled = result {} else { Issue.record("Retired content accepted a save completion") }
        #expect(owner.tabs.allSatisfy { $0.documentURL != destination })
        if !closeInsteadOfReplace {
            #expect(owner.tabs.first { $0.id == tabID }?.documentURL == replacement)
            #expect(owner.tabs.first { $0.id == tabID }?.title == "replacement")
            #expect(owner.activeMarkdownContent?.documentManager.text == "replacement source\n")
        }
    }


    @Test
    func untitledSaveCanFollowAnAdmittedFirstSaveAs() async throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let destination = files.directory.appendingPathComponent("untitled.md")
        let scheduler = ManualScheduler()
        defer { scheduler.drain() }
        let manager = scheduledManager(scheduler)
        manager.text = "first draft\n"
        let first = Task { await manager.saveAs(to: destination) }
        try #require(await scheduler.waitForAdmission(1))
        manager.text = ""
        #expect(manager.isDirty, "The buffer no longer matches the source the pending write will leave on disk")
        #expect(manager.hasSaveDestination && manager.hasPendingWrites)
        let second = Task { await manager.save() }
        try #require(await scheduler.waitForAdmission(2))
        scheduler.drain()
        #expect(await first.value)
        #expect(await second.value)
        #expect(manager.documentURL == destination)
        #expect(try Data(contentsOf: destination).isEmpty)
        #expect(manager.savedText.isEmpty && !manager.isDirty)
        #expect(!manager.hasPendingWrites)
    }

}
