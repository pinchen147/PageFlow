//
//  TabManager+SaveIO.swift
//  PageFlow
//
//  The active tab's document I/O: print, Save / Save-As routed by content type,
//  and the unsaved-changes confirmation prompts. Pure decomposition — the save
//  recipes and dirty state live on the per-content managers; this routes to them.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

extension TabManager {

    /// ⌘P on the active tab. PDF prints via the unchanged PDFKit path; Markdown
    /// prints the STYLED Live-Preview document rendered THROUGH the engine (fork seam
    /// `makePrintView`) so math, tables, and code-block backgrounds print as on screen.
    /// No reconcile is needed: the seam reads the live `NSTextStorage` directly, which
    /// already carries the trailing keystroke. Exhaustive over `TabContent` so a new
    /// content type must define its print path.
    func printActiveDocument() {
        guard let content = activeSession?.content else { return }
        switch content {
        case .pdf(let c):
            guard c.pdfManager.permissions.print, let document = c.pdfManager.document else { return }
            runPrintPanel(for: document)
        case .markdown(let c):
            runMarkdownPrintPanel(jobTitle: c.documentManager.documentTitle) { pageWidth in
                c.makePrintView(pageWidth: pageWidth)
            }
        }
    }

    /// ⌘S on the active tab. Routes by content type: PDF saves in place;
    /// Markdown reconciles the live editor (fork P1) then saves to its URL, or routes
    /// an untitled buffer to Save-As. Exhaustive over `TabContent`.
    func saveActiveDocument() async -> SaveResult {
        guard let content = activeSession?.content else {
            return .failure(message: "No active document to save.")
        }
        switch content {
        case .pdf(let c):
            return await savePDFDocument(c.pdfManager)
        case .markdown(let c):
            return await saveMarkdownDocument(c)
        }
    }

    /// Save the current snapshot, then deliver its receipt to the live tab owner.
    private func savePDFDocument(_ pdfManager: PDFManager) async -> SaveResult {
        guard pdfManager.hasDocument else {
            return .failure(message: "Open a document before saving.")
        }
        guard pdfManager.isDirty || pdfManager.hasPendingWrites else {
            return .success(message: "")
        }
        guard let session = sessions.values.first(where: { $0.pdfManager === pdfManager }) else {
            return .cancelled
        }
        let completion = await pdfManager.saveWithCompletion()
        return completePDFSave(session: session, completion: completion, saveAs: false)
    }

    /// The Markdown Save path: reconcile the live editor text (fork P1) so the
    /// trailing keystroke is captured, then save to the existing URL — or route an
    /// untitled buffer to Save-As (it has no on-disk location yet, ADR-0012 D6).
    private func saveMarkdownDocument(_ content: MarkdownContent) async -> SaveResult {
        let documentManager = content.documentManager
        content.reconcileLiveText()
        guard documentManager.hasSaveDestination else {
            return await saveActiveDocumentAs()
        }
        guard documentManager.isDirty || documentManager.hasPendingWrites else {
            return .success(message: "")
        }
        guard let session = sessions.values.first(where: { $0.content.markdown === content }) else {
            return .cancelled
        }
        guard await confirmSaveOverExternalChangeInBackground(content, session: session),
              let owner = WindowRegistry.shared.owner(of: session, document: content, fallback: self) else { return .cancelled }
        let approval = DocumentCloseSnapshot(session)
        guard owner.confirmReplacingInvalidUTF8(content), !Task.isCancelled,
              let currentOwner = WindowRegistry.shared.owner(of: session, document: content, fallback: owner),
              approval.matches(currentOwner) else { return .cancelled }
        let completion = await documentManager.saveWithCompletion()
        if !completion.didWrite, documentManager.isBackingFileMissing {
            // The vanished file's path can't be recreated (its folder moved, or
            // the sandbox no longer grants it): choose a new location instead.
            guard let owner = WindowRegistry.shared.owner(of: session, document: content, fallback: currentOwner) else { return .cancelled }
            return await owner.saveMarkdownDocumentAs(id: session.id, content: content)
        }
        return completeMarkdownSave(session: session, content: content, completion: completion, saveAs: false)
    }

    /// ⌘⇧S writes the current document to a chosen file and re-homes the tab.
    /// Markdown reconciles its live editor before capturing the save snapshot.
    func saveActiveDocumentAs() async -> SaveResult {
        guard let id = activeTabID, let session = sessions[id] else {
            return .failure(message: "No active document to save.")
        }
        switch session.content {
        case .pdf(let c):
            return await savePDFDocumentAs(id: id, session: session, pdfManager: c.pdfManager)
        case .markdown(let c):
            return await saveMarkdownDocumentAs(id: id, content: c)
        }
    }

    private func savePDFDocumentAs(id: UUID, session: TabSession, pdfManager: PDFManager) async -> SaveResult {
        guard let originalURL = pdfManager.documentURL, let originalDocument = pdfManager.document else {
            return .failure(message: "Open a document before saving.")
        }

        let expectedDocument = session.content.document
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = originalURL.lastPathComponent

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return .cancelled
        }

        guard session.pdfManager === pdfManager, pdfManager.document === originalDocument else { return .cancelled }
        return await saveDocumentAs(session, to: url, isSecurityScoped: true, expectedDocument: expectedDocument)
    }

    /// The session can move windows while disk I/O runs; a replacement can also
    /// reuse its PDFManager. Both the owner and the receipt's document must match.
    func completePDFSave(
        session: TabSession, completion: PDFManager.SaveCompletion, saveAs: Bool
    ) -> SaveResult {
        guard let manager = session.pdfManager, manager.acceptsSaveCompletion(completion),
              let owner = WindowRegistry.shared.owner(of: session, document: session.content.document, fallback: self) else {
            return .cancelled
        }
        owner.publishSavedDocumentIdentity(session)
        guard manager.isCurrentSaveCompletion(completion) else { return .cancelled }
        let result = Self.saveResult(didWrite: completion.didWrite, saveAs: saveAs)
        owner.postSaveNotification(result)
        return result
    }

    private func saveMarkdownDocumentAs(id: UUID, content: MarkdownContent) async -> SaveResult {
        guard let session = sessions[id], session.content.markdown === content else { return .cancelled }
        let documentManager = content.documentManager
        let originalURL = documentManager.documentURL
        let expectedDocument = session.content.document
        // Reconcile the live editor text (fork P1) before showing the panel.
        content.reconcileLiveText()
        guard confirmReplacingInvalidUTF8(content) else { return .cancelled }

        // One shared panel builder — same allowed types + name rule the quit-time
        // Save-As path uses, so a `.markdown` tab is offered consistently.
        guard let url = MarkdownSavePanel.runModal(defaultName: defaultMarkdownSaveName(for: id, documentManager: documentManager)) else {
            return .cancelled
        }

        guard session.content.markdown === content, documentManager.documentURL == originalURL else { return .cancelled }
        return await saveDocumentAs(session, to: url, isSecurityScoped: true, expectedDocument: expectedDocument)
    }

    /// The selected destination is claimed before disk work and stays claimed
    /// until completion publishes the identity, even if the source changes windows.
    func saveDocumentAs(
        _ session: TabSession, to url: URL, isSecurityScoped: Bool,
        expectedDocument document: any TabDocument,
        whileApproved: () -> Bool = { true }, didAdoptImages: () -> Bool = { true }
    ) async -> SaveResult {
        let registry = WindowRegistry.shared
        guard whileApproved(), let owner = registry.owner(of: session, document: document, fallback: self) else { return .cancelled }
        guard let claim = registry.claimSaveAs(to: url, session: session, document: document, owner: owner) else {
            // The destination is open in another tab, which is now in front.
            return .failure(message: "“\(url.lastPathComponent)” is open in another tab. Close it first to save over it.")
        }
        defer { registry.releaseSaveAs(claim) }
        switch session.content {
        case .pdf(let content):
            let completion = await content.pdfManager.saveAsWithCompletion(to: url, isSecurityScoped: isSecurityScoped)
            return completePDFSave(session: session, completion: completion, saveAs: true)
        case .markdown(let content):
            if content.adoptPastedImages(savedAt: url, whileApproved: whileApproved), !didAdoptImages() { return .cancelled }
            guard whileApproved() else { return .cancelled }
            content.reconcileLiveText()
            let completion = await content.documentManager.saveAsWithCompletion(to: url, isSecurityScoped: isSecurityScoped)
            return completeMarkdownSave(session: session, content: content, completion: completion, saveAs: true)
        }
    }

    /// Quit and close share the same destination admission and publication.
    /// Keep the claim until metadata follows any window move during a modal note.
    func saveDocumentAsSync(
        _ session: TabSession, to url: URL, isSecurityScoped: Bool,
        expectedDocument document: any TabDocument,
        whileApproved: () -> Bool = { true }, didAdoptImages: () -> Bool = { true }
    ) -> Bool {
        let registry = WindowRegistry.shared
        guard let owner = registry.owner(of: session, document: document, fallback: self),
              let claim = registry.claimSaveAs(to: url, session: session, document: document, owner: owner) else { return false }
        defer { registry.releaseSaveAs(claim) }
        guard whileApproved() else { return false }
        if let content = session.content.markdown,
           content.adoptPastedImages(savedAt: url, whileApproved: whileApproved), !didAdoptImages() { return false }
        guard whileApproved() else { return false }
        let saved = document.saveAsSync(to: url, isSecurityScoped: isSecurityScoped)
        guard let owner = registry.owner(of: session, document: document, fallback: owner) else { return false }
        // An earlier accepted write can commit an identity even if this write fails.
        owner.publishSavedDocumentIdentity(session)
        return saved && !document.isDirty
    }

    /// Publish the latest committed identity, even before an older receipt is
    /// rejected. Shared by command, close and quit saves; unchanged metadata is a no-op.
    func publishSavedDocumentIdentity(_ session: TabSession) {
        guard sessions[session.id] === session,
              let tab = tabs.first(where: { $0.id == session.id }) else { return }
        let identity: (url: URL?, title: String, isSecurityScoped: Bool)
        switch session.content {
        case .markdown(let content):
            let manager = content.documentManager
            identity = (manager.documentURL, manager.documentTitle, manager.usesSecurityScopedAccess)
        case .pdf(let content):
            let manager = content.pdfManager
            identity = (manager.documentURL, manager.documentTitle, manager.usesSecurityScopedAccess)
        }
        guard let url = identity.url,
              tab.documentURL != url || tab.title != identity.title ||
                tab.isSecurityScoped != identity.isSecurityScoped else { return }
        if let oldURL = tab.documentURL, oldURL != url {
            session.bookmarkManager?.migrateBookmarks(from: oldURL, to: url)
        }
        applyOpenedDocument(tabID: session.id, url: url,
                            isSecurityScoped: identity.isSecurityScoped, title: identity.title)
    }

    /// Save completion follows the live content after a window transfer. A tab
    /// replaced under the same UUID must never inherit its old content's result.
    func completeMarkdownSave(
        session: TabSession, content: MarkdownContent,
        completion: MarkdownDocumentManager.SaveCompletion, saveAs: Bool
    ) -> SaveResult {
        guard session.content.markdown === content,
              let owner = WindowRegistry.shared.owner(of: session, document: content, fallback: self) else {
            return .cancelled
        }
        owner.publishSavedDocumentIdentity(session)
        guard completion.isCurrent else { return .cancelled }
        if completion.didWrite {
            content.presentEncodingDowngradeNoteIfNeeded()
            content.noteWasSaved()
        }
        let result = Self.saveResult(didWrite: completion.didWrite, saveAs: saveAs,
                                     failureReason: completion.failureReason)
        owner.postSaveNotification(result)
        return result
    }

    /// The user-facing outcome of a save; a failure names its reason when known.
    private static func saveResult(didWrite: Bool, saveAs: Bool, failureReason: String? = nil) -> SaveResult {
        guard !didWrite else { return .success(message: saveAs ? "Saved As" : "Saved") }
        let failure = saveAs ? "Save As failed." : "Save failed."
        return .failure(message: failureReason.map { "\(failure) \($0)" } ?? failure)
    }

    /// Default file name for a Markdown Save-As panel: the tab's title (the
    /// extension is normalized by `MarkdownSavePanel`). Falls back to the document
    /// manager's own title when the tab carries no usable title.
    private func defaultMarkdownSaveName(for tabID: UUID, documentManager: MarkdownDocumentManager) -> String {
        let raw = tabs.first { $0.id == tabID }?.title ?? documentManager.documentTitle
        return raw.isEmpty ? documentManager.documentTitle : raw
    }

    private func postSaveNotification(_ result: SaveResult) {
        switch result {
        case .success(let message):
            guard !message.isEmpty else { return }
            postTransientToast(message)
        case .cancelled, .failure:
            break
        }
    }
}
