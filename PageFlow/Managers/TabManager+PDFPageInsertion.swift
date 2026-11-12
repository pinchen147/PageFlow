//
//  TabManager+PDFPageInsertion.swift
//  PageFlow
//
//  Edit ▸ Insert Blank Page / Insert Pages from File… for the active PDF,
//  and the file panel and failure toasts the thumbnail menu shares.
//

import AppKit
import PDFKit
import UniformTypeIdentifiers

extension TabManager {

    /// The active tab is a PDF that may take new pages.
    var canInsertPDFPages: Bool { activePDFManager?.canInsertPages ?? false }

    /// Inserts a blank page after the current (in page editing, the selected) page.
    func insertBlankPDFPage() {
        guard let manager = activePDFManager else { return }
        manager.insertBlankPage(after: manager.currentPageIndex)
    }

    /// Asks for a PDF and inserts its pages after `index` (default: the
    /// current page) of `target` (default: the active PDF).
    func insertPDFPagesFromFile(into target: PDFManager? = nil, after index: Int? = nil) {
        // Test host: a panel would block the main actor (see openFilePicker).
        guard !TestEnvironment.isRunningTests,
              let manager = target ?? activePDFManager, manager.canInsertPages,
              let document = manager.document else { return }
        let anchor = index ?? manager.currentPageIndex
        let window = WindowRegistry.shared.window(for: self)
        guard window?.attachedSheet == nil else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Insert"
        panel.message = "Choose a PDF to insert its pages after page \(anchor + 1)"

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak manager, weak document] response in
            guard response == .OK, let url = panel.url,
                  let self, let manager, let document,
                  manager.document === document else { return }
            self.insertPDFPages(from: url, into: manager, after: anchor)
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Inserts the pages of the PDF at `url` after `anchor`. A password-protected
    /// source first asks for its password in the window's password sheet.
    func insertPDFPages(from url: URL, into manager: PDFManager, after anchor: Int) {
        guard manager.canInsertPages, let document = manager.document else { return }
        guard let source = PDFManager.insertionSource(at: url) else {
            return postTransientToast(Self.insertionFailureMessage(.unreadable, url: url) ?? "")
        }
        guard source.isLocked else {
            return finishPageInsertion(from: source, url: url, into: manager, after: anchor)
        }
        let tabID = sessions.first { $0.value.pdfManager === manager }?.key ?? UUID()
        pendingInsertionUnlock = InsertionUnlockRequest(
            tabID: tabID, url: url, source: source, target: manager, document: document,
            anchor: anchor, precedesQueue: unlockQueue.isEmpty
        )
    }

    /// Unlocks the waiting source in memory and inserts its pages. False (the
    /// sheet stays, saying the password is wrong) only for a wrong password.
    func submitInsertionPassword(_ password: String) -> Bool {
        guard let request = pendingInsertionUnlock else { return false }
        guard request.source.unlock(withPassword: password) else { return false }
        pendingInsertionUnlock = nil
        // The PDF may have closed or changed while the sheet was up.
        guard let manager = request.target, manager.document === request.document else { return true }
        finishPageInsertion(from: request.source, url: request.url, into: manager, after: request.anchor)
        return true
    }

    func cancelInsertionPassword() {
        pendingInsertionUnlock = nil
    }

    private func finishPageInsertion(from source: PDFDocument, url: URL, into manager: PDFManager, after anchor: Int) {
        let result = manager.insertPages(from: source, after: min(anchor, manager.pageCount - 1))
        if let message = Self.insertionFailureMessage(result, url: url) {
            postTransientToast(message)
        }
    }

    static func insertionFailureMessage(_ result: PageInsertionResult, url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        switch result {
        case .inserted: return nil
        case .locked: return "Couldn’t insert pages: “\(name)” is password-protected"
        case .restricted: return "Couldn’t insert pages: “\(name)” doesn’t allow copying"
        case .unreadable: return "Couldn’t read “\(name)” as a PDF"
        case .refused: return "Couldn’t insert pages into this PDF"
        }
    }
}
