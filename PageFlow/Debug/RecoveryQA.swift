// DEBUG-only cross-process recovery qualification, restricted to a disposable identity.
#if DEBUG
import AppKit
import MarkdownEngine

nonisolated enum RecoveryQA {
    private struct Configuration {
        let runID: String
        let phase: String
        var root: URL { URL(fileURLWithPath: "/private/tmp/pageflow-recovery-qa-" + runID, isDirectory: true) }
    }

    private static var configuration: Configuration? {
        let env = ProcessInfo.processInfo.environment
        guard let runID = env["PAGEFLOW_QA_RUN_ID"], UUID(uuidString: runID) != nil,
              Bundle.main.bundleIdentifier == "com.raccoontechnologies.PageFlow.RecoveryQA." + runID,
              let phase = env["PAGEFLOW_QA_RECOVERY"], ["write", "early-quit", "restore", "empty"].contains(phase),
              env["PAGEFLOW_QA_BACKGROUND"] == "1", !TestEnvironment.isRunningTests else { return nil }
        return Configuration(runID: runID, phase: phase)
    }

    static var isRequested: Bool { configuration != nil }
    static var directory: URL? { configuration?.root.appendingPathComponent("Recovery", isDirectory: true) }

    @MainActor
    static func startIfRequested(delegate: AppDelegate, recoveryTask: Task<Void, Never>?) {
        guard ProcessInfo.processInfo.environment["PAGEFLOW_QA_RECOVERY"] != nil else { return }
        guard let config = configuration else { exit(2) }
        if config.phase == "early-quit" {
            // Called synchronously after AppDelegate schedules recovery, before
            // the main actor can materialize its recovered windows.
            var askedToDiscard = false
            let reply = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in askedToDiscard = true; return .cancel }, saveURL: { _ in nil }))
            let approved = reply == .terminateNow && delegate.terminationApproved && !askedToDiscard
            Task {
                do {
                    let expected = try JSONDecoder().decode([MarkdownRecoveryStore.Record].self,
                        from: Data(contentsOf: config.root.appendingPathComponent("expected.json")))
                    let records = await MarkdownRecoveryStore.shared.load()
                    await recoveryTask?.value
                    let copies = WindowRegistry.shared.allOpenTabs().flatMap { $0.tabManager.sessions.values }
                        .filter { $0.content.markdown?.documentManager.documentTitle.hasPrefix("Recovered — ") == true }
                    let checks = [
                        "earlyQuitApprovedWithoutDiscard": approved,
                        "scheduledRecoveryCancelled": recoveryTask?.isCancelled == true,
                        "cancelledRestoreCannotOpenCopies": copies.isEmpty,
                        "unseenJournalRetained": expected.count == 2 && expected.allSatisfy { record in
                            records.contains { $0.id == record.id && $0.source.hasSameSource(as: record.source) && parts($0).block.hasSameSource(as: parts(record).block) }
                        },
                        "background": !NSApp.isActive,
                    ]
                    try report(config, checks: checks)
                    exit(checks.values.allSatisfy({ $0 }) ? 0 : 1)
                } catch {
                    try? report(config, checks: [:], error: String(describing: error))
                    exit(2)
                }
            }
            return
        }
        Task {
            do {
                let deadline = ContinuousClock.now + .seconds(10)
                while delegate.windowContentBuilder == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard delegate.windowContentBuilder != nil else { throw Failure("No native window builder") }
                if config.phase == "write" { try await write(config, delegate: delegate) }
                else { try await restore(config) }
            } catch {
                try? report(config, checks: [:], error: String(describing: error))
                exit(2)
            }
        }
    }

    private struct Failure: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

    @MainActor
    private static func write(_ config: Configuration, delegate: AppDelegate) async throws {
        guard await MarkdownRecoveryStore.shared.load().isEmpty else { throw Failure("Journal was not empty") }
        let original = config.root.appendingPathComponent("original.md")
        try Data("# Original\n".utf8).write(to: original)
        let manager = TabManager()
        await manager.openDocument(url: original, isSecurityScoped: false, bringsToFront: false)?.value
        let fileID = manager.activeTabID!
        let content = manager.activeMarkdownContent!
        manager.newMarkdownDocument()
        let empty = manager.activeMarkdownContent!
        empty.documentManager.text = ""
        manager.selectTab(fileID)
        guard let window = delegate.createNewWindow(with: manager) else { throw Failure("No native window") }
        WindowRegistry.shared.register(manager, window: window)
        let mountDeadline = ContinuousClock.now + .seconds(8)
        var editor: NSTextView?
        while editor == nil, ContinuousClock.now < mountDeadline {
            if let host = window.contentView { editor = findEditor(in: host) }
            if editor == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        guard let editor, content.recoverySession != nil, empty.recoverySession != nil else {
            throw Failure("Native editor or ordinary recovery timer missing")
        }
        editor.insertText("\nRecovery e\u{301} 😀\n", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        content.editorController.commentThreads = [MarkdownCommentThread(
            anchor: MarkdownCommentAnchor(prefix: "", exact: "Recovery", suffix: ""), root: MarkdownComment(body: "Keep this comment 二")
        )]
        var capturedBeforeModelPublication = false
        for _ in 0..<100 {
            let records = await MarkdownRecoveryStore.shared.load()
            capturedBeforeModelPublication = records.contains {
                let body = parts($0).body
                return $0.originalURL == original && body.hasSameSource(as: editor.string) && !body.hasSameSource(as: content.documentManager.text)
            }
            if capturedBeforeModelPublication { break }
            editor.insertText("x", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
            try await Task.sleep(for: .milliseconds(50))
        }
        let expectedBody = editor.string
        var records: [MarkdownRecoveryStore.Record] = []
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            records = await MarkdownRecoveryStore.shared.load()
            if records.count == 2, records.contains(where: { parts($0).body.hasSameSource(as: expectedBody) }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let source = records.first { $0.originalURL == original }
        let checks = [
            "twoPeriodicCheckpoints": records.count == 2,
            "liveTypingCapturedBeforePublication": capturedBeforeModelPublication,
            "exactNativeText": source.map { parts($0).body.hasSameSource(as: expectedBody) } ?? false,
            "commentCaptured": source.map { MarkdownCommentBlock.threads(in: parts($0).block).first?.root.body == "Keep this comment 二" } ?? false,
            "emptyDraftCaptured": records.contains { $0.originalURL == nil && parts($0).body.isEmpty },
            "originalUnchanged": (try Data(contentsOf: original)) == Data("# Original\n".utf8),
            "background": !NSApp.isActive && !window.isKeyWindow,
        ]
        try JSONEncoder().encode(records).write(to: config.root.appendingPathComponent("expected.json"), options: .atomic)
        try report(config, checks: checks)
        guard checks.values.allSatisfy({ $0 }) else { exit(1) }
        // The runner sends SIGKILL only after independently checking the journal.
        while true { try await Task.sleep(for: .seconds(1)) }
    }

    @MainActor
    private static func restore(_ config: Configuration) async throws {
        let expected = try JSONDecoder().decode([MarkdownRecoveryStore.Record].self,
                                                from: Data(contentsOf: config.root.appendingPathComponent("expected.json")))
        let deadline = ContinuousClock.now + .seconds(8)
        var recovered: [(TabManager, TabSession)] = []
        repeat {
            recovered = WindowRegistry.shared.allOpenTabs().flatMap { group in
                group.tabManager.sessions.values.compactMap { session in
                    session.content.markdown?.documentManager.documentTitle.hasPrefix("Recovered — ") == true ? (group.tabManager, session) : nil
                }
            }
            if config.phase == "restore", recovered.count == expected.count { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline && (config.phase == "restore" || recovered.isEmpty)
        var checks = [
            "originalUnchanged": (try Data(contentsOf: config.root.appendingPathComponent("original.md"))) == Data("# Original\n".utf8),
            "background": !NSApp.isActive,
        ]
        if config.phase == "empty" {
            checks["noRecoveredCopiesAfterDiscard"] = recovered.isEmpty
            checks["journalEmpty"] = await MarkdownRecoveryStore.shared.load().isEmpty
        } else {
            checks["restoredExactlyTwoCopies"] = recovered.count == 2
            checks["exactSourceAndComments"] = expected.allSatisfy { record in
                recovered.contains { _, session in
                    guard let content = session.content.markdown else { return false }
                    let document = content.documentManager
                    let expectedParts = parts(record)
                    return document.text.hasSameSource(as: expectedParts.body) && document.commentBlock.hasSameSource(as: expectedParts.block) && document.documentURL == nil && document.isDirty &&
                        content.editorController.commentThreads == MarkdownCommentBlock.threads(in: document.commentBlock)
                }
            }
            let owners = Dictionary(recovered.map { (ObjectIdentifier($0.0), $0.0) }, uniquingKeysWith: { first, _ in first })
            guard let delegate = AppDelegate.shared, let owner = owners.values.first else { throw Failure("No recovered owner") }
            let reply = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in
                owner.restoreRecoveredMarkdown(.init(id: UUID(), title: "Arrived during quit", source: "Unreviewed recovery", updatedAt: Date()))
                return .discard
            }, saveURL: { _ in nil }))
            checks["lateRecoveryRevokesQuit"] = reply == .terminateCancel && !delegate.terminationApproved
            let retained = await MarkdownRecoveryStore.shared.load()
            checks["cancelledQuitRetainsJournal"] = expected.allSatisfy { record in
                retained.contains { $0.id == record.id && $0.source.hasSameSource(as: record.source) && $0.commentBlock == record.commentBlock }
            }
            let prompt = DocumentClosePrompt(decide: { _ in .discard }, saveURL: { _ in nil })
            for owner in owners.values {
                guard owner.confirmWindowClose(using: prompt) else { throw Failure("Discard approval failed") }
                owner.finishWindowClose()
            }
            MarkdownRecoveryStore.shared.flush()
            checks["discardRetiresJournal"] = await MarkdownRecoveryStore.shared.load().isEmpty
        }
        try report(config, checks: checks)
        exit(checks.values.allSatisfy({ $0 }) ? 0 : 1)
    }

    private static func parts(_ record: MarkdownRecoveryStore.Record) -> (body: String, block: String) {
        record.commentBlock.map { (record.source, $0) } ?? MarkdownCommentBlock.split(record.source)
    }

    @MainActor
    private static func findEditor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, String(describing: type(of: text)).contains("NativeTextView"), !view.isHiddenOrHasHiddenAncestor { return text }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private static func report(_ config: Configuration, checks: [String: Bool], error: String? = nil) throws {
        let report: [String: Any] = ["runID": config.runID, "phase": config.phase, "pid": ProcessInfo.processInfo.processIdentifier,
                                     "checks": checks, "error": error ?? "", "passed": !checks.isEmpty && checks.values.allSatisfy({ $0 }) && error == nil]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: config.root.appendingPathComponent(config.phase + ".json"), options: .atomic)
    }
}
#endif
