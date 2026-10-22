import Foundation
import os.log

/// One prompt admits one exact local source against one observed disk version.
/// Focus, command Save and close/quit share the decision; only their I/O differs.
@MainActor
struct MarkdownExternalChangeDecision {
    private enum Resolution { case keepLocal, reload }
    private let resolution: Resolution
    private let content: MarkdownContent
    private let snapshot: DocumentCloseSnapshot
    private let checked: MarkdownDocumentManager.DiskCheck
    private let ownerAtAdmission: TabManager
    private let whileApproved: () -> Bool

    init?(content: MarkdownContent, session: TabSession, owner: TabManager,
          checked: MarkdownDocumentManager.DiskCheck, whileApproved: @escaping () -> Bool = { true }) {
        guard whileApproved(), owner.activeSession === session, session.content.markdown === content else { return nil }
        let snapshot = DocumentCloseSnapshot(session)
        let choice = owner.externalChangePrompt(content.documentManager.documentTitle, content.documentManager.isDirty)
        guard !Task.isCancelled, whileApproved(), owner.activeSession === session, session.content.markdown === content,
              snapshot.matches(owner) else { return nil }
        switch choice {
        case .cancel: return nil
        case .keepMine: resolution = .keepLocal
        case .reload: resolution = .reload
        }
        self.content = content
        self.snapshot = snapshot
        self.checked = checked
        ownerAtAdmission = owner
        self.whileApproved = whileApproved
    }

    /// A transferred tab retains admission; replacement or an edit revokes it.
    private var currentOwner: TabManager? {
        guard !Task.isCancelled, whileApproved(),
              let owner = WindowRegistry.shared.owner(of: snapshot.session, document: content, fallback: ownerAtAdmission),
              snapshot.matches(owner) else { return nil }
        return owner
    }

    /// Keep consumes the captured observation, never a new read after the prompt.
    private func keepLocal(allowingPendingWrites: Bool) -> Bool {
        guard currentOwner != nil else { return false }
        let manager = content.documentManager
        return allowingPendingWrites
            ? manager.keepObservedVersionForSynchronousSave(checked)
            : manager.keepLocalVersionIgnoringDisk(checked.observation, for: checked.probe)
    }

    /// Focus acknowledges Keep before yielding, while Reload runs off main.
    func applyAfterFocusPrompt() {
        if case .keepLocal = resolution { _ = keepLocal(allowingPendingWrites: false) }
        else { Task { await applyInBackground() } }
    }

    /// Close/quit finish their reload before returning to the save/dirty gate.
    func applySynchronously() -> Bool {
        if case .keepLocal = resolution { return keepLocal(allowingPendingWrites: true) }
        guard currentOwner != nil else { return false }
        do {
            try content.reloadFromDisk()
            content.presentInvalidUTF8NoteIfNeeded()
        } catch {
            let logger = Logger(subsystem: "com.pageflow", category: "MarkdownExternalChange")
            logger.error("markdown.reload.failed tab=\(content.documentId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            // Preserve close/quit's failed-reload behavior: leave the draft dirty
            // and acknowledge the baseline rather than repeatedly prompting.
            content.documentManager.keepLocalVersionIgnoringDisk()
        }
        return false
    }

    /// Both focus and ordinary Save use this one guarded reload continuation.
    @discardableResult
    func applyInBackground() async -> Bool {
        if case .keepLocal = resolution { return keepLocal(allowingPendingWrites: false) }
        guard currentOwner != nil else { return false }
        do {
            if try await content.reloadFromDiskInBackground(whileCurrent: { self.currentOwner != nil }) {
                content.presentInvalidUTF8NoteIfNeeded()
            }
        } catch {
            currentOwner?.postTransientToast("Couldn’t reload “\(content.documentManager.documentTitle)”. Your edits are still open.")
        }
        return false
    }
}
