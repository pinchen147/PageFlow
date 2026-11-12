//
//  TabManager+PasswordSheet.swift
//  PageFlow
//
//  Window-level presentation over per-session password data: the single sheet's
//  FIFO queue derivation, prompt/submit/cancel, and the placeholder-window
//  dismissal that clears the way for it. The unlock payload lives on each
//  TabSession; this is a pure decomposition of the window-level plumbing.
//

import Foundation
import AppKit
import PDFKit

extension TabManager {

    /// The current request's identity survives transfer and changes even when
    /// another unlock request replaces it within the same tab.
    /// A source for Insert Pages from File waits ahead of the open requests
    /// that arrived after it, and behind those already waiting.
    var pendingPasswordRequest: PasswordPrompt? {
        if let insertion = pendingInsertionUnlock, insertion.target != nil,
           insertion.precedesQueue || unlockQueue.isEmpty {
            return PasswordPrompt(id: insertion.id, tabID: insertion.tabID, url: insertion.url, purpose: .insertPages)
        }
        guard let tabID = unlockQueue.first,
              let request = sessions[tabID]?.pendingUnlock else { return nil }
        return PasswordPrompt(id: request.id, tabID: tabID, url: request.url, purpose: .open)
    }

    struct PasswordPrompt: Identifiable {
        enum Purpose: Equatable {
            /// Opening a locked PDF in its tab.
            case open
            /// Reading a locked PDF's pages to insert them into another.
            case insertPages
        }

        let id: UUID
        let tabID: UUID
        let url: URL
        var purpose: Purpose = .open
    }

    /// A locked PDF chosen in Insert Pages from File, held in memory (never
    /// opened as a tab) until its password is given.
    struct InsertionUnlockRequest {
        let id = UUID()
        let tabID: UUID
        let url: URL
        let source: PDFDocument
        weak var target: PDFManager?
        /// The target's document when asked, so a replaced one isn't changed.
        weak var document: PDFDocument?
        let anchor: Int
        /// No open request was waiting when this one arrived.
        let precedesQueue: Bool
    }

    func submitPassword(_ password: String, for prompt: PasswordPrompt) -> Bool {
        guard pendingPasswordRequest?.id == prompt.id else { return false }
        if prompt.purpose == .insertPages { return submitInsertionPassword(password) }
        return submitPassword(password)
    }

    func cancelPasswordPrompt(for prompt: PasswordPrompt) {
        guard pendingPasswordRequest?.id == prompt.id else { return }
        if prompt.purpose == .insertPages { return cancelInsertionPassword() }
        cancelPasswordPrompt()
    }

    func isAwaitingPassword(for tabID: UUID) -> Bool {
        sessions[tabID]?.pendingUnlock != nil
    }

    @discardableResult
    func dismissPlaceholderWindowIfNeeded() -> Bool {
        closeFilePicker()

        guard hasOnlyPlaceholderTab else { return false }

        WindowRegistry.shared.closePlaceholderWindow(for: self)
        return true
    }

    func promptForPassword(
        tabID: UUID,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnCancel: Bool,
        restoreTabIDOnCancel: UUID?
    ) {
        guard let session = sessions[tabID] else { return }

        session.pendingUnlock = TabSession.UnlockRequest(
            url: url,
            isSecurityScoped: isSecurityScoped,
            closeTabOnCancel: closeTabOnCancel,
            restoreTabIDOnCancel: restoreTabIDOnCancel
        )
        if !unlockQueue.contains(tabID) {
            unlockQueue.append(tabID)
        }
    }

    func clearPendingPasswordRequest(for tabID: UUID) {
        sessions[tabID]?.pendingUnlock = nil
        unlockQueue.removeAll { $0 == tabID }
    }

    /// The tab whose session is awaiting a password for the given canonical URL.
    func tabAwaitingPassword(for canonicalURL: URL) -> UUID? {
        sessions.first { _, session in
            session.pendingUnlock?.url.pageFlowCanonicalDocumentURL == canonicalURL
        }?.key
    }

    func submitPassword(_ password: String) -> Bool {
        guard let tabID = unlockQueue.first,
              let session = sessions[tabID],
              let request = session.pendingUnlock else {
            return false
        }

        if session.pdfManager?.unlockDocument(password: password) == true {
            clearSearchState(for: tabID)
            closedTabStore.documentSettled(request.url)
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].documentURL = request.url
                tabs[index].isSecurityScoped = request.isSecurityScoped
            }
            documentOpenedHandler?(request.url, request.isSecurityScoped)
            scheduleSessionSave()
            session.pendingUnlock = nil
            unlockQueue.removeAll { $0 == tabID }
            return true
        }
        return false
    }

    func cancelPasswordPrompt() {
        guard let tabID = unlockQueue.first,
              let session = sessions[tabID],
              let request = session.pendingUnlock else { return }

        session.pdfManager?.cancelPendingUnlock()
        session.pendingUnlock = nil
        unlockQueue.removeAll { $0 == tabID }

        guard request.closeTabOnCancel,
              tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        closeTab(tabID)

        if let restoreTabID = request.restoreTabIDOnCancel,
           tabs.contains(where: { $0.id == restoreTabID }) {
            selectTab(restoreTabID)
        }
    }
}
