import AppKit

/// Cancelling a close cancels its wait, never an accepted filesystem operation.
/// The operation still publishes its ordinary completion to the live document.
@MainActor
private final class CloseOperationResult {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<Bool, Never>) {
        if finished { continuation.resume(returning: false) }
        else { self.continuation = continuation }
    }

    func finish(_ value: Bool) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

/// Cancellation can arrive from any executor, including inside a modal loop.
/// Revocation is synchronous; only continuation delivery hops to MainActor.
private final class CloseOperationAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func revoke() { lock.lock(); allowed = false; lock.unlock() }
    var isAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }
}

@MainActor
enum DocumentCloseOperation {
    static func wait(_ operation: @escaping @MainActor (@escaping () -> Bool) async -> Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let result = CloseOperationResult()
        let admission = CloseOperationAdmission()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.start(continuation)
                guard !Task.isCancelled else { admission.revoke(); result.finish(false); return }
                Task { @MainActor in
                    guard admission.isAllowed else { result.finish(false); return }
                    let value = await operation { admission.isAllowed }
                    admission.revoke()
                    result.finish(value)
                }
            }
        } onCancel: {
            admission.revoke()
            Task { @MainActor in result.finish(false) }
        }
    }
}

/// A delayed native sheet avoids flashing for ordinary local saves. Its Cancel
/// button abandons close/quit; already dispatched writes remain owned by their tab.
@MainActor
final class DocumentCloseWaitSheet {
    private weak var parent: NSWindow?
    private let alert = NSAlert()
    private var presentation: Task<Void, Never>?
    private var finished = false
    private var shown = false
    private var readinessObserver: NSObjectProtocol?

    init(window: NSWindow?, quitting: Bool = false, cancel: @escaping () -> Void) {
        parent = window
        guard !TestEnvironment.isRunningTests, window != nil else { return }
        #if DEBUG
        guard !QAPresentation.runsInBackground else { return }
        #endif
        alert.messageText = quitting ? "Waiting to Quit" : "Waiting to Close"
        alert.informativeText = "PageFlow is finishing a save. Cancel keeps your documents open; an already started save will continue."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Cancel")
        presentation = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            // A Save panel or decision may temporarily own the window. Resume
            // presentation on native event updates, never with a polling timer.
            self.readinessObserver = NotificationCenter.default.addMainActorObserver(forName: NSApplication.didUpdateNotification) { [weak self] in
                self?.showIfReady(cancel: cancel)
            }
            self.showIfReady(cancel: cancel)
        }
    }

    private func showIfReady(cancel: @escaping () -> Void) {
        guard !finished, !shown, let parent, NSApp.modalWindow == nil, parent.attachedSheet == nil else { return }
        if let readinessObserver { NotificationCenter.default.removeObserver(readinessObserver) }
        readinessObserver = nil
        shown = true
        alert.beginSheetModal(for: parent) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.finished = true
                cancel()
            }
        }
    }

    func finish() {
        finished = true
        presentation?.cancel()
        presentation = nil
        if let readinessObserver { NotificationCenter.default.removeObserver(readinessObserver) }
        readinessObserver = nil
        if shown { parent?.endSheet(alert.window) }
    }
}

extension TabManager {
    func beginClosingTab(_ session: TabSession, using prompt: DocumentClosePrompt? = nil) {
        guard pendingTabCloses[session.id] == nil else { return }
        pendingTabCloses[session.id] = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let sheet = DocumentCloseWaitSheet(window: WindowRegistry.shared.window(for: self)) { [weak self] in
                self?.pendingTabCloses[session.id]?.cancel()
            }
            defer {
                sheet.finish()
                self.pendingTabCloses.removeValue(forKey: session.id)
            }
            guard await self.confirmDocumentCloseInBackground(session, using: prompt), !Task.isCancelled,
                  self.sessions[session.id] === session, !session.content.document.hasPendingWrites else { return }
            self.finishClosingTab(session.id)
        }
    }

    var hasPendingDocumentWrites: Bool {
        sessions.values.contains { $0.content.document.hasPendingWrites }
    }

    var needsCloseApproval: Bool {
        sessions.values.contains { $0.content.document.isDirty || $0.content.document.hasPendingWrites }
    }

    /// The native window route and Cmd-W use this same source-bound approval.
    func confirmWindowCloseInBackground(using prompt: DocumentClosePrompt? = nil) async -> Bool {
        flushMarkdownEditors()
        let ids = tabs.map(\.id)
        var candidates = ids.compactMap { sessions[$0] }.map(DocumentCloseSnapshot.init)
        guard candidates.count == ids.count else { return false }
        let initiallyPending = Set(candidates.filter { $0.session.content.document.hasPendingWrites }.map { $0.session.id })
        func initialWritesMatch() -> Bool {
            tabs.map(\.id) == ids && candidates.allSatisfy {
                $0.matches(self, allowingSavedURL: initiallyPending.contains($0.session.id))
            }
        }
        for candidate in candidates where initiallyPending.contains(candidate.session.id) {
            guard !Task.isCancelled, initialWritesMatch(),
                  await DocumentCloseOperation.wait({ _ in await candidate.session.content.document.finishPendingWritesInBackground(); return true }) else { return false }
        }
        guard !Task.isCancelled, initialWritesMatch(), !hasPendingDocumentWrites else { return false }
        for candidate in candidates { publishSavedDocumentIdentity(candidate.session) }
        candidates = ids.compactMap { sessions[$0] }.map(DocumentCloseSnapshot.init)
        var approved: [DocumentCloseSnapshot] = []
        for candidate in candidates {
            guard !Task.isCancelled, candidate.matches(self),
                  await confirmDocumentCloseInBackground(candidate.session, using: prompt) else { return false }
            approved.append(DocumentCloseSnapshot(candidate.session))
        }
        return !Task.isCancelled && !hasPendingDocumentWrites && tabs.map(\.id) == ids && approved.allSatisfy { $0.matches(self) }
    }

    func confirmDocumentCloseInBackground(
        _ session: TabSession, using prompt: DocumentClosePrompt? = nil,
        whileApproved: @escaping () -> Bool = { true }, didAdoptImages: @escaping () -> Bool = { true }
    ) async -> Bool {
        let prompt = prompt ?? .live
        var snapshot = DocumentCloseSnapshot(session)
        let document = session.content.document
        guard snapshot.matches(self), whileApproved(), !Task.isCancelled else { return false }
        if document.hasPendingWrites {
            guard await DocumentCloseOperation.wait({ _ in await document.finishPendingWritesInBackground(); return true }) == true,
                  snapshot.matches(self, allowingSavedURL: true), !Task.isCancelled, whileApproved(),
                  !document.hasPendingWrites else { return false }
            publishSavedDocumentIdentity(session)
            snapshot = DocumentCloseSnapshot(session)
        }
        guard !document.isDirty else {
            let decision = prompt.decide(document.documentTitle)
            guard !Task.isCancelled, snapshot.matches(self), whileApproved(), !document.hasPendingWrites else { return false }
            switch decision {
            case .cancel: return false
            case .discard: return true
            case .save:
                let saved: Bool
                if document.needsSaveAs {
                    DirtyDoc(session: session, owner: self).reveal()
                    guard !Task.isCancelled, snapshot.matches(self), whileApproved(), !document.hasPendingWrites else { return false }
                    guard let url = prompt.saveURL(document.documentTitle), !Task.isCancelled,
                          snapshot.matches(self), whileApproved() else { return false }
                    saved = await DocumentCloseOperation.wait { [self] isWaiting in
                        let result = await saveDocumentAs(session, to: url, isSecurityScoped: true, expectedDocument: document,
                            whileApproved: { isWaiting() && snapshot.matches(self) && whileApproved() }, didAdoptImages: {
                                guard snapshot.matches(self, allowingImageAdoption: true), didAdoptImages() else { return false }
                                snapshot = DocumentCloseSnapshot(session)
                                return true
                            })
                        if case .success = result { return true }
                        if case .failure(let message) = result, isWaiting(), snapshot.matches(self), whileApproved() {
                            DirtyDoc(session: session, owner: self).reveal()
                            postTransientToast(message)
                        }
                        return false
                    }
                } else {
                    saved = await DocumentCloseOperation.wait { [self] isWaiting in
                        await DirtyDoc(session: session, owner: self).saveInBackground(
                            whileApproved: { isWaiting() && snapshot.matches(self) && whileApproved() })
                    } == true
                }
                return saved && !Task.isCancelled && !document.hasPendingWrites && snapshot.matches(self, allowingSavedURL: true) && !document.isDirty
            }
        }
        return !Task.isCancelled && whileApproved() && !document.hasPendingWrites && snapshot.matches(self)
    }
}
