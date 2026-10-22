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

    @discardableResult
    func createNewTab(with url: URL? = nil, isSecurityScoped: Bool = false) -> Task<Void, Never>? {
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

        // A pending note owns a placeholder until its background read succeeds.
        // The old content remains intact on failure or cancelled replacement.
        if let url, documentKind(for: url) == .markdown {
            createSession(for: newTab)
            activeTabID = newTab.id
            guard let session = sessions[newTab.id] else { return nil }
            return replaceActiveContentWithMarkdown(
                newTab.id,
                replacing: session,
                url: url,
                isSecurityScoped: isSecurityScoped,
                closeTabOnFailure: true,
                restoreTabIDOnFailure: previousActiveTabID
            )
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
        return nil
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

    /// A recovered draft is a separate untitled document. Its original file
    /// remains untouched and normal Save As/close confirmation still applies.
    func restoreRecoveredMarkdown(_ record: MarkdownRecoveryStore.Record) {
        newMarkdownDocument()
        guard let id = activeTabID, let content = sessions[id]?.content.markdown else { return }
        content.documentManager.recoverUnsavedSource(record.source, title: record.title, commentBlock: record.commentBlock)
        content.loadComments()
        content.recoverySession?.adopt(record)
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            tabs[index].title = content.documentManager.documentTitle
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
    @discardableResult
    func openDocument(url: URL, isSecurityScoped: Bool, replaceCurrent: Bool = false, bringsToFront: Bool = true, pdfPageIndex: Int? = nil) -> Task<Void, Never>? {
        if let existingTabID = tabID(for: url) {
            selectTab(existingTabID)
            followPDFPageLink(pdfPageIndex, to: url)
            if bringsToFront { WindowRegistry.shared.bringToFront(for: self) }
            dismissPlaceholderWindowIfNeeded()
            return sessions[existingTabID]?.pendingMarkdownOpen?.task
        }

        // Activate existing tab if this document is already open (any window)
        if WindowRegistry.shared.activateExistingDocument(for: url, bringsToFront: bringsToFront, pdfPageIndex: pdfPageIndex) {
            dismissPlaceholderWindowIfNeeded()
            return WindowRegistry.shared.pendingMarkdownOpenTask(for: url)
        }
        // A cloud-only file downloads off main and opens when it lands: reading
        // it here would hold the main thread for the whole download (TN3150).
        if isCloudOnly(url) {
            return openAfterDownloading(url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent, pdfPageIndex: pdfPageIndex)
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
        let pending: Task<Void, Never>?
        if let activeID = activeTabID,
           let session = sessions[activeID],
           (replaceCurrent || (session.canReplaceWithoutPrompt && !isAwaitingPassword(for: activeID))) {
            pending = reuseActiveTab(activeID, url: url, isSecurityScoped: isSecurityScoped)
        } else {
            // Current tab holds content, create new tab
            pending = createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }

        followPDFPageLink(pdfPageIndex, to: url)
        if bringsToFront { WindowRegistry.shared.bringToFront(for: self) }
        return pending
    }

    /// Deliver to the matching session rather than whichever tab is active after open.
    func followPDFPageLink(_ pageIndex: Int?, to url: URL) {
        guard let pageIndex, let id = tabID(for: url) else { return }
        sessions[id]?.pdfManager?.followPageLink(pageIndex, for: url)
    }

    /// Notes above this size ask before opening: the editor styles the whole note.
    static let largeNoteWarningBytes = 5 * 1024 * 1024

    @discardableResult
    private func openAfterDownloading(_ url: URL, isSecurityScoped: Bool, replaceCurrent: Bool, pdfPageIndex: Int? = nil,
                                      dropBatch: DroppedDocumentBatch? = nil) -> Task<Void, Never>? {
        if let pdfPageIndex { downloadingPDFPageIndices[url] = pdfPageIndex }
        let name = url.deletingPathExtension().lastPathComponent
        guard downloadingURLs.insert(url).inserted else {
            postTransientToast("Still downloading “\(name)”…")
            return downloadingTasks[url]
        }
        postTransientToast("Downloading “\(name)”…")
        let task = Task { [weak self] in
            let downloaded = await Task.detached(priority: .userInitiated) {
                url.pageFlowDownloadContents(isSecurityScoped: isSecurityScoped)
            }.value
            guard let self else { return }
            self.downloadingURLs.remove(url)
            self.downloadingTasks.removeValue(forKey: url)
            defer { if self.downloadingTasks.isEmpty { self.currentDropBatch = nil } }
            let linkedPageIndex = self.downloadingPDFPageIndices.removeValue(forKey: url)
            guard downloaded, !self.isCloudOnly(url) else {
                self.postTransientToast("Couldn’t download “\(name)”")
                return
            }
            // A long download may land after the user moved on to another
            // app: open the file without taking the focus back.
            let previousSelection = self.activeTabID
            let selectionOwner = dropBatch == nil ? nil : (self.currentDropBatch ?? dropBatch)
            let selectionChanged = selectionOwner?.selectionChanged(in: self) ?? false
            // A re-drop can share an older batch's download. The newest batch
            // that requested this URL owns its insertion and selection.
            let claimedByNewest = selectionOwner?.urls.contains(url.pageFlowCanonicalDocumentURL) == true
            let alreadyOpen = self.tabID(for: url) != nil
            let pending = self.openDocument(url: url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent,
                                            bringsToFront: NSApp.isActive && !selectionChanged, pdfPageIndex: linkedPageIndex)
            if let dropBatch {
                if !alreadyOpen, let tabID = self.tabID(for: url) {
                    self.positionDroppedTab(tabID, url: url, in: claimedByNewest ? selectionOwner! : dropBatch)
                }
                if selectionChanged || !claimedByNewest {
                    if let previousSelection { self.selectTab(previousSelection) }
                } else {
                    if let last = selectionOwner?.urls.reversed().compactMap({ self.tabID(for: $0) }).first {
                        self.selectTab(last)
                    }
                }
                // Other batches' automatic completions are not user navigation.
                if !selectionChanged { selectionOwner?.rememberSelection(in: self) }
            }
            await pending?.value
        }
        downloadingTasks[url] = task
        return task
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
    private func reuseActiveTab(_ activeID: UUID, url: URL, isSecurityScoped: Bool) -> Task<Void, Never>? {
        guard let session = sessions[activeID] else {
            // No session for the active tab (should not happen) — fall back to a new tab.
            return createNewTab(with: url, isSecurityScoped: isSecurityScoped)
        }

        switch documentKind(for: url) {
        case .pdf:
            if let pdfManager = session.content.pdf?.pdfManager {
                // PDF → PDF (placeholder reuse or replace-current): load into the
                // live managers in place. Byte-identical to the original PDF path.
                let result = pdfManager.loadDocument(from: url, isSecurityScoped: isSecurityScoped)
                if case .failed = result {} else {
                    session.pendingMarkdownOpen?.cancel()
                    session.pendingMarkdownOpen = nil
                }
                handleLoadResult(result, for: activeID, url: url, isSecurityScoped: isSecurityScoped)
            } else {
                // markdown → PDF (replace-current): replace the content wholesale.
                replaceActiveContentWithPDF(activeID, replacing: session, url: url, isSecurityScoped: isSecurityScoped)
            }
        case .markdown:
            // → markdown (placeholder re-home or replace-current over any content).
            return replaceActiveContentWithMarkdown(activeID, replacing: session, url: url, isSecurityScoped: isSecurityScoped)
        }
        return nil
    }

    /// Replaces the active tab's content with a Markdown document loaded from `url`.
    /// Loads into a FRESH markdown session first; only on a successful load does it
    /// gate the prior content's teardown behind the unsaved-changes prompt and swap
    /// the fresh content in. A load failure (the file is missing/unreadable) returns
    /// with the existing tab/session entirely intact — no empty markdown tab left
    /// advertising the old document; a cancelled prompt likewise aborts.
    @discardableResult
    private func replaceActiveContentWithMarkdown(
        _ tabID: UUID,
        replacing oldSession: TabSession,
        url: URL,
        isSecurityScoped: Bool,
        closeTabOnFailure: Bool = false,
        restoreTabIDOnFailure: UUID? = nil,
        removeUnusedPlaceholderOnFailure: Bool = false
    ) -> Task<Void, Never> {
        oldSession.pendingMarkdownOpen?.cancel()
        let request = TabSession.MarkdownOpen(url: url, isSecurityScoped: isSecurityScoped, owner: self)
        oldSession.pendingMarkdownOpen = request
        let document = oldSession.content.document
        let task = Task { [weak self, weak oldSession] in
            defer {
                request.task = nil
                if oldSession?.pendingMarkdownOpen === request { oldSession?.pendingMarkdownOpen = nil }
            }
            do {
                let read = request.read
                let prepared = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: { read.cancel() }
                try Task.checkCancellation()
                guard let oldSession, oldSession.pendingMarkdownOpen === request,
                      let owner = WindowRegistry.shared.owner(of: oldSession, document: document, fallback: request.owner ?? self) else { return }
                // This warning protects the editor's styling work. Its byte
                // count comes from the background read, without a main-thread stat.
                let acceptsSize = prepared.byteCount <= Self.largeNoteWarningBytes ||
                    owner.largeNoteOpenPrompt(url.deletingPathExtension().lastPathComponent, prepared.byteCount)
                guard !Task.isCancelled, oldSession.pendingMarkdownOpen === request,
                      let currentOwner = WindowRegistry.shared.owner(of: oldSession, document: document, fallback: request.owner ?? owner) else { return }
                guard acceptsSize else {
                    if closeTabOnFailure || (removeUnusedPlaceholderOnFailure && currentOwner.tabs.count > 1 &&
                        oldSession.content.document.canReplaceWithoutPrompt) {
                        currentOwner.removeFailedTab(tabID, restoringTo: restoreTabIDOnFailure)
                    }
                    return
                }
                guard currentOwner.confirmDocumentClose(oldSession),
                      !Task.isCancelled, oldSession.pendingMarkdownOpen === request,
                      let finalOwner = WindowRegistry.shared.owner(of: oldSession, document: document, fallback: request.owner ?? currentOwner) else { return }
                let fresh = TabSession.markdown(id: tabID)
                guard let content = fresh.content.markdown else { return }
                content.documentManager.applyPreparedOpen(prepared)
                content.restoreReadingPositionIfAvailable()
                content.loadComments()
                content.presentInvalidUTF8NoteIfNeeded()
                oldSession.pendingMarkdownOpen = nil
                finalOwner.swapSession(fresh, for: tabID, replacing: oldSession)
                finalOwner.applyOpenedDocument(tabID: tabID, url: url, isSecurityScoped: isSecurityScoped,
                                               title: content.documentManager.documentTitle)
            } catch {
                guard !Task.isCancelled, let oldSession, oldSession.pendingMarkdownOpen === request,
                      let owner = WindowRegistry.shared.owner(of: oldSession, document: document, fallback: request.owner ?? self) else { return }
                oldSession.pendingMarkdownOpen = nil
                owner.reportMarkdownLoadFailure(url, error)
                if closeTabOnFailure || (removeUnusedPlaceholderOnFailure && owner.tabs.count > 1 &&
                    oldSession.content.document.canReplaceWithoutPrompt) {
                    owner.removeFailedTab(tabID, restoringTo: restoreTabIDOnFailure)
                }
            }
        }
        request.task = task
        return task
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
    @discardableResult
    func openLocalLink(_ link: URL, from content: MarkdownContent) -> Task<Void, Never>? {
        // A comment's Copy link: `‹note›#thread-‹id›` opens that comment (doc 25 §5.1).
        let thread = MarkdownEditorController.commentThreadID(inFragment: link.fragment)
        if !link.isFileURL, link.path(percentEncoded: false).isEmpty, let heading = link.fragment {
            if let thread { content.openCommentThread(thread) } else { content.scrollToHeading(heading) }
            return nil
        }
        guard let target = content.localLinkTarget(link) else {
            postTransientToast("Save the note to follow its relative links")
            return nil
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            postTransientToast("Couldn’t find “\(target.lastPathComponent)”")
            return nil
        }
        if target.pageFlowIsOpenableDocument {
            let pageIndex = target.pathExtension.lowercased() == "pdf" ? PDFPageLink.pageIndex(in: link.fragment) : nil
            let pending = openDocument(url: target, isSecurityScoped: false, pdfPageIndex: pageIndex)
            guard let thread else { return pending }
            return Task { [weak self] in
                await pending?.value
                let managers = [self].compactMap { $0 } + WindowRegistry.shared.allOpenTabs().map(\.tabManager)
                for manager in managers {
                    guard let id = manager.tabID(for: target),
                          let opened = manager.sessions[id]?.content.markdown,
                          opened.documentManager.documentURL?.pageFlowCanonicalDocumentURL == target.pageFlowCanonicalDocumentURL else { continue }
                    opened.openCommentThread(thread)
                    break
                }
            }
        }
        let type = (try? target.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        let runnable: [UTType] = [.application, .applicationBundle, .executable, .script, .shellScript]
        if let type, runnable.contains(where: type.conforms(to:)) {
            postTransientToast("PageFlow doesn’t open apps or scripts from links")
            return nil
        }
        guard localFileLinkPrompt(target.lastPathComponent) else { return nil }
        NSWorkspace.shared.open(target)
        return nil
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
        let batch = DroppedDocumentBatch(urls: urls.map(\.pageFlowCanonicalDocumentURL))
        currentDropBatch = batch
        var failures = 0
        for url in batch.urls where !openDroppedDocument(url, batch: batch) {
            failures += 1
        }
        batch.rememberSelection(in: self)
        if downloadingTasks.isEmpty { currentDropBatch = nil }
        WindowRegistry.shared.bringToFront(for: self)
        return failures
    }

    /// Download completion may arrive in any order. Insert only its newly
    /// admitted tab beside the nearest already-admitted member of this drop;
    /// never reorder the other tabs or serialize unrelated downloads.
    final class DroppedDocumentBatch {
        let urls: [URL]
        let order: [URL]
        private var selectedTabID: UUID?
        private weak var selectedSession: TabSession?
        private var selectedURL: URL?
        init(urls: [URL]) {
            self.urls = urls
            var seen: Set<URL> = []
            order = urls.filter { seen.insert($0).inserted }
        }
        func rememberSelection(in owner: TabManager) {
            selectedTabID = owner.activeTabID
            selectedSession = owner.activeSession
            selectedURL = selectionURL(in: owner)
        }
        func selectionChanged(in owner: TabManager) -> Bool {
            owner.activeTabID != selectedTabID || selectionURL(in: owner) != selectedURL ||
                (selectedURL == nil && owner.activeSession !== selectedSession)
        }
        private func selectionURL(in owner: TabManager) -> URL? {
            // An admitted note's placeholder becomes a fresh session on read
            // completion. Its pending URL preserves selection identity across
            // that controlled replacement, unlike a new untitled document.
            (owner.activeTab?.documentURL ?? owner.activeSession?.pendingMarkdownOpen?.url)?.pageFlowCanonicalDocumentURL
        }
    }

    private func positionDroppedTab(_ tabID: UUID, url: URL, in batch: DroppedDocumentBatch) {
        guard let rank = batch.order.firstIndex(of: url.pageFlowCanonicalDocumentURL),
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let next = batch.order.dropFirst(rank + 1).compactMap { self.tabID(for: $0) }.first
        let previous = batch.order.prefix(rank).reversed().compactMap { self.tabID(for: $0) }.first
        guard next != nil || previous != nil else { return }
        let tab = tabs.remove(at: index)
        if let next, let target = tabs.firstIndex(where: { $0.id == next }) {
            tabs.insert(tab, at: target)
        } else if let previous, let target = tabs.firstIndex(where: { $0.id == previous }) {
            tabs.insert(tab, at: target + 1)
        } else {
            tabs.insert(tab, at: min(index, tabs.count))
        }
    }

    /// Loads one dropped `url`. Returns false only if the document failed to load.
    private func openDroppedDocument(_ url: URL, batch: DroppedDocumentBatch) -> Bool {
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
            openAfterDownloading(url, isSecurityScoped: false, replaceCurrent: false, dropBatch: batch)
            return true
        }
        if url.pageFlowIsMarkdown {
            activeSession?.content.markdown?.reconcileLiveText()
            if let id = activeTabID, let session = sessions[id], session.canReplaceWithoutPrompt,
               !isAwaitingPassword(for: id) {
                replaceActiveContentWithMarkdown(id, replacing: session, url: url, isSecurityScoped: false,
                                                 removeUnusedPlaceholderOnFailure: true)
            } else {
                openDocument(url: url, isSecurityScoped: false)
            }
            return true
        }
        // Reuse the empty active tab if free; otherwise a fresh tab, rolled back on failure.
        if let activeID = activeTabID, let activeTab,
           !activeTab.hasDocument, !isAwaitingPassword(for: activeID),
           sessions[activeID]?.pendingMarkdownOpen == nil,
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
    /// background-open/replace-current successes funnel through, so
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
        let wasActive = activeTabID == tabID
        closeSession(for: tabID)
        tabs.removeAll { $0.id == tabID }
        let restore = restoreTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        if wasActive { activeTabID = restore ?? tabs.last?.id }
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

}
