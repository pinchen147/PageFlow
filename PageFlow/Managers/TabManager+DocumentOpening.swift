//
//  TabManager+DocumentOpening.swift
//  PageFlow
//
//  The open/create/replace half of the tab coordinator: new-tab creation, the
//  content-routed open path (PDF vs Markdown), drag-drop opens, load-result
//  handling, and the per-content session installers. Behavior lives with
//  TabManager's stored tab/session state; this is a pure decomposition.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import os.log
import MarkdownEngine

/// The tab content a URL opens as, decided by file extension — the single
/// authority the open paths branch on so a `.md` never reaches the PDF
/// firewall. Classified by `URL.pageFlowIsMarkdown` (`pageFlowMarkdownExtensions`).
private enum DocumentKind {
    case pdf
    case markdown
}

extension TabManager {

    func createNewTab(with url: URL? = nil, isSecurityScoped: Bool = false) {
        let previousActiveTabID = activeTabID

        // Edit mode is ephemeral: leaving the tab exits it (ADR-0005), same
        // as selectTab — otherwise the flag parks true and the reconcile
        // resurrects edit mode when this tab becomes active again.
        if isEditingPages {
            isEditingPages = false
        }

        // Preserve state of current tab before switching away
        saveCurrentTabState()

        let newTab = TabModel()
        tabs.append(newTab)

        // A markdown URL builds a markdown-backed session and loads through the
        // text document manager (never the PDF firewall). Branched before the
        // pdf session is created so the two paths never overlap.
        if let url, documentKind(for: url) == .markdown {
            createMarkdownSession(for: newTab.id)
            activeTabID = newTab.id
            loadMarkdownDocument(
                url: url,
                into: newTab.id,
                isSecurityScoped: isSecurityScoped,
                closeTabOnFailure: true,
                restoreTabIDOnFailure: previousActiveTabID
            )
            return
        }

        createSession(for: newTab)
        activeTabID = newTab.id

        if let url = url {
            let result = sessions[newTab.id]?.pdfManager?.loadDocument(from: url, isSecurityScoped: isSecurityScoped) ?? .failed
            handleLoadResult(
                result,
                for: newTab.id,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnCancel: true,
                restoreTabIDOnCancel: previousActiveTabID,
                closeTabOnFailure: true
            )
        }
        // A new empty tab (⌘T / the "+" button) opens no file picker: it may
        // become a new note. Its empty state offers Open Document and New
        // Markdown.
    }

    /// Creates a new, empty, untitled Markdown tab and makes it active — the ⌘N
    /// "New Markdown Document" command (ADR-0012 D6). No file picker: the buffer is
    /// empty and therefore not dirty until the first edit. The title is "Untitled",
    /// disambiguated to "Untitled 2", "Untitled 3", … against the other open tabs.
    func newMarkdownDocument() {
        // Edit mode is ephemeral: leaving the active tab exits it (ADR-0005).
        if isEditingPages {
            isEditingPages = false
        }

        // Reuse an empty active PLACEHOLDER (fresh window, New Tab): the new
        // document takes over IN PLACE instead of stranding a blank tab behind
        // — gated by the CANONICAL replace predicate (durable identity + not
        // dirty), same as the open path. Only the .pdf-kind placeholder
        // qualifies: an empty untitled MARKDOWN tab is already a document, so
        // asking for another appends a new one.
        if let activeID = activeTabID, let session = sessions[activeID],
           session.contentKind == .pdf,
           session.canReplaceWithoutPrompt, !isAwaitingPassword(for: activeID) {
            let title = untitledMarkdownTitle()
            let fresh = TabSession.markdown(id: activeID)
            swapSession(fresh, for: activeID, replacing: session)
            if let index = tabs.firstIndex(where: { $0.id == activeID }) {
                tabs[index].title = title
            }
            seedUntitledMarkdown(fresh, title: title)
            return
        }

        saveCurrentTabState()
        let newTab = TabModel(title: untitledMarkdownTitle())
        tabs.append(newTab)
        createMarkdownSession(for: newTab.id)
        activeTabID = newTab.id
        if let session = sessions[newTab.id] {
            seedUntitledMarkdown(session, title: newTab.title)
        }
    }

    /// Obsidian-style starter for a new document: a title heading matching the
    /// tab ("# Untitled"), seeded PRISTINE so an untouched tab stays clean.
    private func seedUntitledMarkdown(_ session: TabSession, title: String) {
        session.content.markdown?.documentManager.seedUntitled("# \(title)\n\n")
    }

    /// "Untitled", or the lowest "Untitled N" (N ≥ 2) not already used by an open
    /// tab — so two new untitled documents never share a title.
    private func untitledMarkdownTitle() -> String {
        let base = "Untitled"
        let used = Set(tabs.map(\.title))
        guard used.contains(base) else { return base }
        var n = 2
        while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Opens `url` in this window and brings it to the front, unless
    /// `bringsToFront` is false (a download that landed after the user moved
    /// on to another app).
    func openDocument(url: URL, isSecurityScoped: Bool, replaceCurrent: Bool = false, bringsToFront: Bool = true) {
        if let existingTabID = tabID(for: url) {
            selectTab(existingTabID)
            if bringsToFront { WindowRegistry.shared.bringToFront(for: self) }
            dismissPlaceholderWindowIfNeeded()
            return
        }

        // Activate existing tab if this document is already open (any window)
        if WindowRegistry.shared.activateExistingDocument(for: url) {
            dismissPlaceholderWindowIfNeeded()
            return
        }
        // A cloud-only file downloads off main and opens when it lands: reading
        // it here would hold the main thread for the whole download (TN3150).
        if isCloudOnly(url) {
            openAfterDownloading(url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent)
            return
        }
        if url.pageFlowIsMarkdown, !admitsLargeNote(url) {
            return
        }

        // Reuse the active tab only when replace was requested, or it is an empty,
        // non-dirty placeholder that can be silently replaced (a fresh PDF tab, or
        // an untitled Markdown buffer with no content). A dirty/typed-in untitled
        // Markdown tab is NOT clobbered — it opens a new tab instead (ADR-0012 D6).
        //
        // The clobber gate (`canReplaceWithoutPrompt`/`hasContent`) reads the
        // durable `text`, which the editor commits on a ~1s deferred binding write.
        // Reconcile the live editor FIRST so typing-then-⌘O (the NSOpenPanel runs
        // in a mode where that deferred write never drains) is judged on current
        // text, not a stale empty buffer — otherwise the keystrokes are clobbered.
        activeSession?.content.markdown?.reconcileLiveText()
        if let activeID = activeTabID,
           let session = sessions[activeID],
           (replaceCurrent || (session.canReplaceWithoutPrompt && !isAwaitingPassword(for: activeID))) {
            reuseActiveTab(activeID, url: url, isSecurityScoped: isSecurityScoped)
        } else {
            // Current tab holds content, create new tab
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }

        if bringsToFront { WindowRegistry.shared.bringToFront(for: self) }
    }

    /// Notes above this size ask before opening: the editor styles the whole note.
    static let largeNoteWarningBytes = 5 * 1024 * 1024

    /// A note large enough to be slow opens only once the user agrees.
    private func admitsLargeNote(_ url: URL) -> Bool {
        guard let size = url.pageFlowFileSize, size > Self.largeNoteWarningBytes else { return true }
        return largeNoteOpenPrompt(url.deletingPathExtension().lastPathComponent, size)
    }

    private func openAfterDownloading(_ url: URL, isSecurityScoped: Bool, replaceCurrent: Bool) {
        let name = url.deletingPathExtension().lastPathComponent
        guard downloadingURLs.insert(url).inserted else {
            postTransientToast("Still downloading “\(name)”…")
            return
        }
        postTransientToast("Downloading “\(name)”…")
        Task { [weak self] in
            let downloaded = await Task.detached(priority: .userInitiated) {
                url.pageFlowDownloadContents(isSecurityScoped: isSecurityScoped)
            }.value
            guard let self else { return }
            self.downloadingURLs.remove(url)
            guard downloaded, !self.isCloudOnly(url) else {
                self.postTransientToast("Couldn’t download “\(name)”")
                return
            }
            // A long download may land after the user moved on to another
            // app: open the file without taking the focus back.
            self.openDocument(url: url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent,
                              bringsToFront: NSApp.isActive)
        }
    }

    /// The one user-visible report for a note that failed to open.
    private func reportMarkdownLoadFailure(_ url: URL, _ error: Error) {
        let name = url.deletingPathExtension().lastPathComponent
        if case MarkdownDocumentManager.LoadError.notText = error {
            postTransientToast("Couldn’t open “\(name)”: it isn’t a text file")
        } else {
            postTransientToast("Couldn’t open “\(name)”")
        }
    }

    /// Loads `url` into the active tab — entered when that tab is an empty
    /// placeholder or the caller asked to replace-current. PDF→PDF reuses the live
    /// PDF managers in place (the unchanged PDF path); any other transition
    /// (placeholder→markdown, or a replace-current that changes content type, or
    /// markdown→markdown) replaces the tab's content WHOLESALE and atomically: the
    /// new file is loaded into a fresh content first, and only on success is the
    /// prior content torn down — through the same unsaved-changes gate `closeTab`
    /// uses. A load failure or a cancelled prompt leaves the existing tab untouched.
    private func reuseActiveTab(_ activeID: UUID, url: URL, isSecurityScoped: Bool) {
        guard let session = sessions[activeID] else {
            // No session for the active tab (should not happen) — fall back to a new tab.
            createNewTab(with: url, isSecurityScoped: isSecurityScoped)
            return
        }

        switch documentKind(for: url) {
        case .pdf:
            if let pdfManager = session.content.pdf?.pdfManager {
                // PDF → PDF (placeholder reuse or replace-current): load into the
                // live managers in place. Byte-identical to the original PDF path.
                let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
                handleLoadResult(result, for: activeID, url: url, isSecurityScoped: isSecurityScoped)
            } else {
                // markdown → PDF (replace-current): replace the content wholesale.
                replaceActiveContentWithPDF(activeID, replacing: session, url: url, isSecurityScoped: isSecurityScoped)
            }
        case .markdown:
            // → markdown (placeholder re-home or replace-current over any content).
            replaceActiveContentWithMarkdown(activeID, replacing: session, url: url, isSecurityScoped: isSecurityScoped)
        }
    }

    /// Replaces the active tab's content with a Markdown document loaded from `url`.
    /// Loads into a FRESH markdown session first; only on a successful load does it
    /// gate the prior content's teardown behind the unsaved-changes prompt and swap
    /// the fresh content in. A load failure (the file is missing/unreadable) returns
    /// with the existing tab/session entirely intact — no empty markdown tab left
    /// advertising the old document; a cancelled prompt likewise aborts.
    private func replaceActiveContentWithMarkdown(
        _ tabID: UUID,
        replacing oldSession: TabSession,
        url: URL,
        isSecurityScoped: Bool
    ) {
        let freshSession = TabSession.markdown(id: tabID)
        guard let freshContent = freshSession.content.markdown else { return }
        let documentManager = freshContent.documentManager

        do {
            try documentManager.load(from: url, isSecurityScoped: isSecurityScoped)
            freshContent.restoreReadingPositionIfAvailable()
            freshContent.loadComments()
            freshContent.presentInvalidUTF8NoteIfNeeded()
        } catch {
            // `load` already released any scope it acquired before throwing; the
            // unattached fresh session is discarded and the existing tab is untouched.
            logger.error("markdown.load.failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reportMarkdownLoadFailure(url, error)
            return
        }

        // The new file loaded. Gate the prior content's teardown exactly as
        // `closeTab` does; on cancel, release the freshly-loaded doc and abort.
        guard confirmDocumentClose(oldSession) else {
            freshSession.cleanup()
            return
        }

        swapSession(freshSession, for: tabID, replacing: oldSession)
        applyOpenedDocument(
            tabID: tabID,
            url: url,
            isSecurityScoped: isSecurityScoped,
            title: documentManager.documentTitle
        )
    }

    /// Replaces the active tab's content with a PDF loaded from `url` (the
    /// markdown→PDF replace-current edge). Loads into a FRESH PDF session first;
    /// only on a non-failure result does it gate the prior content's teardown and
    /// swap. On `.failed` the existing tab/session is untouched; on success or
    /// `.needsPassword` the shared `handleLoadResult` stamps identity / queues the
    /// password sheet against the now-installed fresh session.
    private func replaceActiveContentWithPDF(
        _ tabID: UUID,
        replacing oldSession: TabSession,
        url: URL,
        isSecurityScoped: Bool
    ) {
        let freshSession = TabSession(id: tabID)
        guard let pdfManager = freshSession.content.pdf?.pdfManager else { return }
        let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)

        if case .failed = result {
            // `loadDocument` already released any scope it acquired; leave the
            // existing tab/session intact and drop the unattached fresh session.
            return
        }

        guard confirmDocumentClose(oldSession) else {
            freshSession.cleanup()  // release the loaded (or pending-locked) document's scope
            return
        }

        swapSession(freshSession, for: tabID, replacing: oldSession)
        handleLoadResult(result, for: tabID, url: url, isSecurityScoped: isSecurityScoped)
    }

    /// Swaps `newSession` in for `tabID`, tearing down the replaced content's
    /// document, security scope, and undo history. Unlike `closeSession` the tab
    /// keeps its place in the warm/displayed sets (the id is unchanged); only any
    /// pending password request for the prior content is dropped.
    private func swapSession(_ newSession: TabSession, for tabID: UUID, replacing oldSession: TabSession) {
        logger.debug("session.replace tab=\(tabID.uuidString, privacy: .public)")
        sessions[tabID] = newSession
        oldSession.cleanup()
        unlockQueue.removeAll { $0 == tabID }
    }

    /// A local link clicked in a note (D8): `#heading` jumps within the note, a
    /// PDF or note opens in a tab, and any other file asks first, then opens in
    /// its own app. Apps and scripts never open from a link.
    func openLocalLink(_ link: URL, from content: MarkdownContent) {
        // A comment's Copy link: `‹note›#thread-‹id›` opens that comment (doc 25 §5.1).
        let thread = MarkdownEditorController.commentThreadID(inFragment: link.fragment)
        if !link.isFileURL, link.path(percentEncoded: false).isEmpty, let heading = link.fragment {
            if let thread { content.openCommentThread(thread) } else { content.scrollToHeading(heading) }
            return
        }
        guard let target = content.localLinkTarget(link) else {
            postTransientToast("Save the note to follow its relative links")
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            postTransientToast("Couldn’t find “\(target.lastPathComponent)”")
            return
        }
        if target.pageFlowIsOpenableDocument {
            openDocument(url: target, isSecurityScoped: false)
            if let thread, let opened = activeMarkdownContent,
               opened.documentManager.documentURL?.standardizedFileURL == target.standardizedFileURL {
                opened.openCommentThread(thread)
            }
            return
        }
        let type = (try? target.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let runnable: [UTType] = [.application, .applicationBundle, .executable, .script, .shellScript]
        if let type, runnable.contains(where: type.conforms(to:)) {
            postTransientToast("PageFlow doesn’t open apps or scripts from links")
            return
        }
        guard localFileLinkPrompt(target.lastPathComponent) else { return }
        NSWorkspace.shared.open(target)
    }

    /// The drop action shared by every drop surface: opens the files in this
    /// window and reports the ones that failed.
    func openDroppedFiles(_ urls: [URL]) {
        closeFilePicker()
        let failed = openDroppedDocuments(urls)
        if failed > 0 {
            postTransientToast(failed == 1 ? "Couldn’t open 1 file" : "Couldn’t open \(failed) files")
        }
    }

    /// Opens dropped PDF and Markdown files as tabs in THIS window, in order, and
    /// returns how many failed to load. A file already open in this window is
    /// focused (not duplicated); a file open in another window is skipped so the
    /// whole drop stays in this window. Drops are canonicalized like Finder opens,
    /// so saving a symlinked note writes its target instead of replacing the link.
    @discardableResult
    func openDroppedDocuments(_ urls: [URL]) -> Int {
        guard !urls.isEmpty else { return 0 }
        var failures = 0
        for url in urls.map(\.pageFlowCanonicalDocumentURL) where !openDroppedDocument(url) {
            failures += 1
        }
        WindowRegistry.shared.bringToFront(for: self)
        return failures
    }

    /// Loads one dropped `url`. Returns false only if the document failed to load.
    private func openDroppedDocument(_ url: URL) -> Bool {
        // Already open in this window → focus it, no duplicate.
        if let existingTabID = tabID(for: url) {
            selectTab(existingTabID)
            return true
        }
        // Already open in another window → leave it there; keep this drop here.
        if WindowRegistry.shared.isDocumentOpen(url) {
            return true
        }
        // A cloud-only drop downloads off main and opens when it lands; a
        // Markdown drop routes through the content-aware open path (it creates
        // the .markdown session). Either reports its own failure, and may wait
        // on a download or a large-note confirmation, so it never counts toward
        // the batch. The PDF reuse/rollback below is the PDF loader's protocol.
        if isCloudOnly(url) {
            openAfterDownloading(url, isSecurityScoped: false, replaceCurrent: false)
            return true
        }
        if url.pageFlowIsMarkdown {
            openDocument(url: url, isSecurityScoped: false)
            return true
        }
        // Reuse the empty active tab if free; otherwise a fresh tab, rolled back on failure.
        if let activeID = activeTabID, let activeTab,
           !activeTab.hasDocument, !isAwaitingPassword(for: activeID),
           let pdfManager = sessions[activeID]?.pdfManager {
            let result = pdfManager.loadDocument(from: url, isSecurityScoped: false)
            return finishDroppedLoad(result, for: activeID, url: url, createdTab: false, restoreOnFailure: nil)
        }

        let previousActiveTabID = activeTabID
        // Edit mode is ephemeral: leaving the tab exits it (ADR-0005).
        if isEditingPages {
            isEditingPages = false
        }
        saveCurrentTabState()
        let newTab = TabModel()
        tabs.append(newTab)
        createSession(for: newTab)
        activeTabID = newTab.id
        let result = sessions[newTab.id]?.pdfManager?.loadDocument(from: url, isSecurityScoped: false) ?? .failed
        return finishDroppedLoad(result, for: newTab.id, url: url, createdTab: true, restoreOnFailure: previousActiveTabID)
    }

    /// Applies a dropped file's load result. On `.failed`, removes a tab we created
    /// for it so a bad file never leaves an empty "New Tab" behind. Returns false
    /// only on `.failed`.
    private func finishDroppedLoad(
        _ result: DocumentLoadResult,
        for tabID: UUID,
        url: URL,
        createdTab: Bool,
        restoreOnFailure: UUID?
    ) -> Bool {
        if case .failed = result {
            if createdTab {
                removeFailedTab(tabID, restoringTo: restoreOnFailure)
            }
            return false
        }
        handleLoadResult(
            result,
            for: tabID,
            url: url,
            isSecurityScoped: false,
            closeTabOnCancel: createdTab,
            restoreTabIDOnCancel: createdTab ? restoreOnFailure : nil
        )
        return true
    }

    private func handleLoadResult(
        _ result: DocumentLoadResult,
        for tabID: UUID,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnCancel: Bool = false,
        restoreTabIDOnCancel: UUID? = nil,
        closeTabOnFailure: Bool = false
    ) {
        switch result {
        case .success:
            clearPendingPasswordRequest(for: tabID)
            clearSearchState(for: tabID)
            let title = sessions[tabID]?.pdfManager?.documentTitle ?? url.deletingPathExtension().lastPathComponent
            applyOpenedDocument(tabID: tabID, url: url, isSecurityScoped: isSecurityScoped, title: title)
        case .needsPassword:
            promptForPassword(
                tabID: tabID,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnCancel: closeTabOnCancel,
                restoreTabIDOnCancel: restoreTabIDOnCancel
            )
        case .failed:
            clearPendingPasswordRequest(for: tabID)
            if closeTabOnFailure {
                removeFailedTab(tabID, restoringTo: restoreTabIDOnCancel)
            }
        }
    }

    /// Stamps a tab with its now-open document's identity — URL, security scope,
    /// title — and notifies the recent-files handler. The single tab-identity
    /// bookkeeping path both the PDF (`handleLoadResult`) and Markdown
    /// (`loadMarkdownDocument`, replace-current) load successes funnel through, so
    /// identity can't drift between content types.
    func applyOpenedDocument(tabID: UUID, url: URL, isSecurityScoped: Bool, title: String) {
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].documentURL = url
            tabs[index].isSecurityScoped = isSecurityScoped
            tabs[index].title = title
        }
        documentOpenedHandler?(url, isSecurityScoped)
        // A tab just gained (or re-homed onto) a file identity — the single funnel
        // every open/Save-As success passes through, so one hook keeps the restore
        // store current (S8 P1).
        scheduleSessionSave()
    }

    /// Removes a tab whose document failed to load and restores the previously
    /// active tab, so a missing/corrupt file never leaves a stray "New Tab"
    /// behind (e.g. reopening a since-deleted Recently-Closed document).
    private func removeFailedTab(_ tabID: UUID, restoringTo restoreTabID: UUID?) {
        closeSession(for: tabID)
        tabs.removeAll { $0.id == tabID }
        let restore = restoreTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        activeTabID = restore ?? tabs.last?.id
    }

    func createSession(for tab: TabModel) {
        // The session wires the page-mutation fan-out and undo-availability
        // observers in its init; the markup managers are configured with the
        // live PDFView later in PDFViewWrapper.makeNSView().
        sessions[tab.id] = TabSession(id: tab.id)
        logger.debug("session.create tab=\(tab.id.uuidString, privacy: .public)")
    }

    /// Installs a fresh Markdown-backed session for `tab` (peer of
    /// `createSession`). Used when an open routes a `.md`/`.markdown` URL.
    private func createMarkdownSession(for tabID: UUID) {
        sessions[tabID] = TabSession.markdown(id: tabID)
        logger.debug("session.create.markdown tab=\(tabID.uuidString, privacy: .public)")
    }

    private func documentKind(for url: URL) -> DocumentKind {
        // Classified off the single shared Markdown predicate. The open gate
        // (`URL.pageFlowIsOpenableDocument`) guarantees every URL reaching here is
        // an openable document — PDF or Markdown — so a non-Markdown extension is
        // necessarily a PDF; this is a binary split, not an "assume PDF for unknown".
        url.pageFlowIsMarkdown ? .markdown : .pdf
    }

    /// Loads a markdown `url` into an already-installed markdown session for
    /// `tabID` — the text-document analogue of `pdfManager.loadDocument` +
    /// `handleLoadResult`. Goes through `MarkdownDocumentManager` exclusively, so
    /// the PDF firewall is never touched. On a load throw the tab is removed when
    /// `closeTabOnFailure` is set (mirroring `removeFailedTab`), so a bad file
    /// never leaves a half-open tab behind.
    private func loadMarkdownDocument(
        url: URL,
        into tabID: UUID,
        isSecurityScoped: Bool,
        closeTabOnFailure: Bool = false,
        restoreTabIDOnFailure: UUID? = nil
    ) {
        guard let content = sessions[tabID]?.content.markdown else { return }
        let documentManager = content.documentManager
        do {
            try documentManager.load(from: url, isSecurityScoped: isSecurityScoped)
            content.restoreReadingPositionIfAvailable()
            content.loadComments()
            content.presentInvalidUTF8NoteIfNeeded()
            applyOpenedDocument(
                tabID: tabID,
                url: url,
                isSecurityScoped: isSecurityScoped,
                title: documentManager.documentTitle
            )
        } catch {
            logger.error("markdown.load.failed tab=\(tabID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            reportMarkdownLoadFailure(url, error)
            if closeTabOnFailure {
                removeFailedTab(tabID, restoringTo: restoreTabIDOnFailure)
            }
        }
    }
}
