//
//  TabDocument.swift
//  PageFlow
//
//  The behavioral contract every tab-content backend implements (`PDFContent`,
//  `MarkdownContent`) so the session and the quit/close lifecycle route through
//  ONE interface instead of an exhaustive `switch` per concern (ADR-0006 kept
//  the typed `TabContent` discriminator; this collapses the ~dozen lifecycle /
//  predicate / save switches that hung off it into `content.document.foo()`).
//
//  This is STRONGER than the old per-site `switch`, not weaker: adding a third
//  content type is one compile error at `TabContent.document` plus a conformance
//  the compiler forces to implement every member — co-located in the new type,
//  where the "how does THIS content decide it" logic belongs, rather than a
//  break/no-op risk scattered across TabSession and TabManager.
//

import Foundation
import AppKit

/// The per-tab content backend contract. Conformed by `PDFContent` and
/// `MarkdownContent`; reached through `TabContent.document`. Each member's doc
/// states the PDF vs Markdown contract so the two semantics stay legible side by
/// side even though the implementations live in each content's own file.
@MainActor
protocol TabDocument: AnyObject {

    // MARK: State the Edit menu / chrome mirrors

    /// This tab's undo stack — PDF page ops vs Markdown text edits. The Edit menu
    /// drives it and (Markdown) the engine's text view registers into the same
    /// object, so ⌘Z and the editor can never operate different stacks.
    var undoManager: UndoManager { get }

    /// Cached can-undo/can-redo for cheap, observable menu enable/disable.
    var undoAvailability: UndoAvailability { get }

    // MARK: Open / restore predicates

    /// This tab's security-scoped bookmark for cross-launch restore, if its
    /// content holds its file under a security scope; `nil` for a non-scoped or
    /// untitled tab. Both mint it once per held file access.
    var restoreBookmark: Data? { get }

    /// Whether this tab holds real content — a loaded PDF, or a Markdown buffer
    /// with a file URL or any typed text. An empty untitled placeholder is false.
    var hasContent: Bool { get }

    /// Whether an open may silently reuse this tab: true only for a non-dirty
    /// placeholder with no durable identity (a fresh PDF tab, or an untouched
    /// untitled Markdown buffer). Once file-backed or edited, an open must not
    /// clobber it (ADR-0012 D6). One rule for both: no URL + not dirty.
    var canReplaceWithoutPrompt: Bool { get }

    // MARK: Save gating (⌘S / ⌘⇧S / dirty)

    /// Whether Save (⌘S) applies. PDF: a document is open. Markdown: always, so
    /// Save can reconcile the live editor before judging dirty state (a clean
    /// buffer saves nothing; an untitled one routes to Save-As).
    var canSave: Bool { get }

    /// Whether Save As… (⌘⇧S) applies. PDF: a document is open. Markdown: always —
    /// even an untitled buffer can be written to a new file.
    var canSaveAs: Bool { get }

    /// Whether this tab has unsaved changes.
    var isDirty: Bool { get }

    // MARK: Modal quit/close save path (the retired `DirtyDoc` enum's arms)

    /// Display title for the save/quit prompt.
    var documentTitle: String { get }

    /// True for a dirty document that has never been written to disk — `saveSync()`
    /// returns false for it and the caller must route to Save-As. Only a dirty
    /// untitled Markdown buffer; PDF always has a URL, so false.
    var needsSaveAs: Bool { get }

    /// Blocking save to the document's existing location (no `await` at terminate
    /// time). Markdown first reconciles the live editor (fork P1) so the trailing
    /// keystroke is captured, then surfaces the one-time UTF-8 downgrade note.
    /// Returns false for an untitled Markdown document (no URL yet) — route to
    /// Save-As.
    @discardableResult
    func saveSync() -> Bool

    /// Reconcile + blocking Save-As to `url` for the untitled-Markdown quit path.
    /// PDF never routes here (it always has a URL); returns false for it.
    func saveAsSync(to url: URL, isSecurityScoped: Bool) -> Bool

    /// Lands every write already admitted for this document. Quit calls it before
    /// judging dirty state, so termination never cuts an in-flight save short.
    func finishPendingWrites()

    /// Native close/quit wait without synchronously draining storage on main.
    func finishPendingWritesInBackground() async
    var hasPendingWrites: Bool { get }

    // MARK: Lifecycle

    /// Ordered teardown on tab close (not on a window move — that transfers the
    /// content intact).
    func cleanup()

    /// Captures the live view position into the activation snapshot when switching
    /// away. Markdown has no cross-activation snapshot yet (deferred) — a no-op —
    /// kept a requirement so a new content type must decide its capture behavior.
    func captureViewSnapshot()

    /// Re-applies the activation snapshot on re-activation. Markdown: no-op.
    func restoreViewSnapshot()

    /// Clears just the search part of the activation snapshot. Markdown: no-op.
    func clearSearchSnapshot()
}

// MARK: - TabContent routing

extension TabContent {
    /// The content backend as its behavioral contract — the ONE switch that
    /// replaces the dozen lifecycle/predicate/save switches TabSession and
    /// TabManager used to make. A new `TabContent` case is a compile error here
    /// AND must conform `TabDocument`, so the "must decide" guarantee is kept.
    var document: any TabDocument {
        switch self {
        case .pdf(let content): return content
        case .markdown(let content): return content
        }
    }
}

// MARK: - Dirty document handle (quit/close aggregation)

/// A quit/close save handle bound to the exact session and content observed by
/// `TabManager.dirtyDocuments()`. Ownership is resolved again after modal work,
/// so transfers follow the live tab and replacements cannot inherit its save.
@MainActor
struct DirtyDoc {
    /// The owning tab's id — the key the aggregation is grouped by.
    var tabID: UUID { session.id }

    private let session: TabSession
    private weak var originalOwner: TabManager?

    /// The dirty content itself, reached through its contract.
    let document: any TabDocument

    init(session: TabSession, owner: TabManager) {
        self.session = session
        self.originalOwner = owner
        self.document = session.content.document
    }

    private var owner: TabManager? {
        WindowRegistry.shared.owner(of: session, document: document, fallback: originalOwner)
    }

    /// Display title for the save/quit prompt.
    var title: String { document.documentTitle }

    /// True for a dirty untitled document that must route to Save-As.
    var needsSaveAs: Bool { document.needsSaveAs }

    /// Blocking save to the existing location (Markdown reconciles first).
    @discardableResult
    func saveSync(whileApproved: () -> Bool = { true }) -> Bool {
        guard whileApproved(), let currentOwner = owner else { return false }
        if let content = session.content.markdown {
            // The coordinator observes once and reveals only a modified file.
            let allowed = currentOwner.confirmSaveOverExternalChange(content, session: session)
            guard whileApproved() else { return false }
            guard allowed else {
                // Reload left the tab matching disk; Cancel keeps it dirty.
                return !document.isDirty
            }
            if content.documentManager.hasInvalidUTF8 {
                reveal()
                guard currentOwner.confirmReplacingInvalidUTF8(content), whileApproved() else { return false }
            }
        }
        guard whileApproved() else { return false }
        let saved = document.saveSync()
        guard let owner else { return false }
        owner.publishSavedDocumentIdentity(session)
        return saved && !document.isDirty
    }

    /// Brings the document's window and tab forward, so a quit-time panel shows
    /// whose changes it is about to save.
    func reveal() {
        guard let owner else { return }
        owner.selectTab(tabID)
        WindowRegistry.shared.bringToFront(for: owner)
    }

    /// Reconcile + blocking Save-As (untitled-Markdown quit path only).
    func saveAsSync(to url: URL, isSecurityScoped: Bool, whileApproved: () -> Bool = { true },
                    didAdoptImages: () -> Bool = { true }) -> Bool {
        guard whileApproved(), let owner else { return false }
        return owner.saveDocumentAsSync(session, to: url, isSecurityScoped: isSecurityScoped,
                                        expectedDocument: document, whileApproved: whileApproved, didAdoptImages: didAdoptImages)
    }
}

// Keep the asynchronous barrier beside the document lifecycle contract.
extension PDFContent {
    var hasPendingWrites: Bool { pdfManager.hasPendingWrites }
    func finishPendingWritesInBackground() async { await pdfManager.finishPendingWritesInBackground() }
}

extension MarkdownContent {
    var hasPendingWrites: Bool { documentManager.hasPendingWrites }
    func finishPendingWritesInBackground() async { await documentManager.finishPendingWritesInBackground() }
}

extension DirtyDoc {
    func saveForCloseInBackground(using prompt: DocumentClosePrompt,
                                  whileApproved: @escaping () -> Bool,
                                  didAdoptImages: @escaping () -> Bool) async -> Bool {
        guard let owner else { return false }
        return await owner.confirmDocumentCloseInBackground(session, using: prompt,
            whileApproved: whileApproved, didAdoptImages: didAdoptImages)
    }

    /// Approval belongs to the invoking close/quit request. A dispatched save
    /// continues normally even when that request stops waiting.
    func saveInBackground(whileApproved: @escaping () -> Bool) async -> Bool {
        guard !Task.isCancelled, whileApproved(), let currentOwner = owner else { return false }
        if let content = session.content.markdown {
            let allowed = await currentOwner.confirmSaveOverExternalChangeInBackground(content, session: session, selectingForClose: true, whileApproved: whileApproved)
            guard whileApproved() else { return false }
            guard allowed else { return !document.isDirty }
            guard currentOwner.confirmReplacingInvalidUTF8(content), whileApproved() else { return false }
            let completion = await content.documentManager.saveWithCompletion()
            guard let currentOwner = owner else { return false }
            currentOwner.publishSavedDocumentIdentity(session)
            if completion.didWrite, completion.isCurrent {
                if whileApproved() { content.presentEncodingDowngradeNoteIfNeeded() }
                content.noteWasSaved()
            } else if completion.isCurrent, whileApproved() {
                reveal()
                currentOwner.postTransientToast(completion.failureReason.map { "Save failed. \($0)" } ?? "Save failed. Your edits are still open.")
            }
            return completion.didWrite && !document.isDirty
        }
        guard let manager = session.pdfManager, whileApproved() else { return false }
        let completion = await manager.saveWithCompletion()
        guard let currentOwner = owner, manager.acceptsSaveCompletion(completion) else { return false }
        currentOwner.publishSavedDocumentIdentity(session)
        if !completion.didWrite, manager.isCurrentSaveCompletion(completion), whileApproved() {
            reveal()
            currentOwner.postTransientToast("Save failed. Your edits are still open.")
        }
        return completion.didWrite && !document.isDirty
    }
}
