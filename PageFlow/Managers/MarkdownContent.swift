//
//  MarkdownContent.swift
//  PageFlow
//
//  The Markdown backend of a tab (ADR-0006 `TabContent.markdown`; ADR-0012 D3) —
//  the peer of `PDFContent`. Owns the durable text document, a per-editor undo
//  stack (text edits, never the PDF page-op stack), the synchronous save-time
//  controller (fork P1), and the scroll snapshot restored on re-activation.
//  Per-content state behind content-agnostic surfaces (ADR-0012 D3).
//

import Foundation
import AppKit
import Observation
import MarkdownEngine

@Observable
@MainActor
final class MarkdownContent {
    /// The durable text document — the source of truth when the editor is
    /// unmounted (ADR-0012 D2).
    let documentManager: MarkdownDocumentManager
    @ObservationIgnored private(set) var recoverySession: MarkdownRecoverySession?

    /// Per-editor undo stack for text edits + its observable availability mirror.
    /// Distinct from the PDF page-op undo so ⌘Z in a markdown tab can never pop
    /// a PDF page operation (ADR-0012 D3). The engine's text view registers its
    /// edits HERE (routed through the fork's `undoManager(for:)` seam via
    /// `MarkdownEditorView`), and the Edit menu drives the same object via
    /// `TabSession.undoManager` — one stack, two doors.
    let undo = UndoAvailabilityMirror()
    var undoManager: UndoManager { undo.manager }
    var undoAvailability: UndoAvailability { undo.availability }

    /// Host-retained handle for the synchronous quit/close text read + flush
    /// (fork P1). Lives here, on the durable content, so it persists across warm
    /// tab switches and re-binds to the editor's coordinator on each mount.
    @ObservationIgnored let editorController: MarkdownEditorController

    /// The native editor survives window moves and retains native undo targets.
    @ObservationIgnored var retainedEditorSurface: RetainedMarkdownEditorSurface?

    /// Detach cold editors from layout work. Native undo actions target the text
    /// view, so retain that view while its document has undo or redo history.
    func evictEditorSurface() {
        reconcileLiveText()
        armReadingPositionRestore()
        if undoManager.canUndo || undoManager.canRedo {
            retainedEditorSurface?.suspend()
        } else {
            releaseEditorSurface()
        }
    }

    private func releaseEditorSurface() {
        retainedEditorSurface?.release()
        retainedEditorSurface = nil
        undoManager.removeAllActions()
    }

    /// Stable per-tab id (= `TabSession.id`), used as the engine `documentId` and
    /// the scoped-bus `object` stamp so this tab's find posts reach only its editor.
    let documentId: String

    /// This tab's PER-TAB scoped editor bus (fork P2): unique `Notification.Name`s
    /// suffixed by `documentId` AND `scopeByObject: true`. Durable (one per tab) so
    /// it is stable across warm switches; the editor adapter wires the engine to it
    /// and `searchManager` posts find requests through it.
    @ObservationIgnored let bus: MarkdownEditorBus

    /// This tab's Find backend (S7a). Lives here so it survives warm tab switches;
    /// the shared Find bar drives it (via `MarkdownTabView`) when this tab is active.
    /// Searches the live editor's exact native source, falling back to the
    /// durable document when unmounted. Live preview conceals link suffixes
    /// through attributes; native find and source ranges share UTF-16 coordinates.
    @ObservationIgnored lazy var searchManager: MarkdownSearchManager = {
        MarkdownSearchManager(
            bus: bus,
            documentId: documentId,
            textProvider: { [weak self] in
                guard let self else { return "" }
                return self.editorController.currentDisplayText ?? self.documentManager.text
            },
            editorController: editorController
        )
    }()

    /// Test seam: the live editor's storage-form text (fork P1). Production reads
    /// the `editorController`; tests inject a stub since no coordinator is mounted
    /// headlessly, so the real `currentStorageText` always returns `nil`.
    @ObservationIgnored var liveStorageText: () -> String?

    /// Resolves `![alt](path)` images relative to this note's folder; one per
    /// note so decoded images (and misses) outlive restyles and warm switches.
    @ObservationIgnored private(set) lazy var imageProvider = DocumentImageProvider { [weak self] in
        MainActor.assumeIsolated { self?.documentManager.documentURL }
    }

    init(documentId: String, documentManager: MarkdownDocumentManager? = nil) {
        self.documentManager = documentManager ?? MarkdownDocumentManager()
        let controller = MarkdownEditorController()
        self.editorController = controller
        // The commit writes the live storage into the binding AND updates the
        // engine's de-dupe guard, so the editor sees an echo of its own text,
        // not a foreign change to rebuild from (which relaid the whole note).
        self.liveStorageText = { [weak controller] in controller?.commitPendingText() }
        self.documentId = documentId
        self.bus = Self.makeBus(documentId: documentId)
        controller.onFoldingStateChange = { [weak self] in self?.foldingRevision &+= 1 }
        controller.onFormatStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.formatState = state }
        }
        controller.onTableColumnWidthsChange = { [weak self] widths in
            MainActor.assumeIsolated { self?.persistTableColumnWidths(widths) }
        }
        controller.onCommentThreadsChange = { [weak self] threads in
            MainActor.assumeIsolated {
                self?.persistComments(threads)
                self?.openCommentCount = threads.filter { !$0.resolved }.count
            }
        }
        controller.onCommentsModeChange = { [weak self] mode in
            MainActor.assumeIsolated { self?.commentsMode = mode }
        }
        // Settings > Shortcuts, live: the editor's own chords follow every change.
        controller.keyBindings = ShortcutCatalog.editorKeyBindings()
        shortcutObserver = NotificationCenter.default.addMainActorObserver(forName: SettingsManager.shortcutsDidChange) { [weak controller] in
            controller?.keyBindings = ShortcutCatalog.editorKeyBindings()
        }
        if !TestEnvironment.isRunningTests {
            #if DEBUG
            if !RecoveryQA.isRequested, QAPresentation.runsInBackground || QAReplay.isRequested || WindowCloseQA.isRequested { return }
            #endif
            recoverySession = MarkdownRecoverySession(content: self, store: .shared)
        }
    }

    @ObservationIgnored private var shortcutObserver: NSObjectProtocol?

    deinit {
        if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
    }

    /// The formatting at the editor's selection, shared by the selection bar,
    /// the Format menu's check marks and the toolbar (doc 24 §6.4).
    var formatState = MarkdownFormatState()
    var foldingRevision = 0

    /// Whether `command` can apply at the selection. A table cell takes no
    /// block command (a list, heading or table can't live in a cell), and code
    /// takes none but leaving the code block; their buttons and menu items show
    /// disabled rather than doing nothing.
    func isFormatEnabled(_ command: MarkdownFormatCommand) -> Bool {
        if formatState.inTableCell { return !command.isBlock }
        switch formatState.context {
        case .cellText, .cellRange: return !command.isBlock
        case .codeBlock: return !command.isBlock || command == .codeBlock
        case .image: return false
        case .none, .text: return true
        }
    }

    /// Whether `command`'s Format menu item carries a check mark now.
    func isFormatOn(_ command: MarkdownFormatCommand) -> Bool {
        let state = formatState
        switch command {
        case .bold: return state.bold
        case .italic: return state.italic
        case .underline: return state.underline
        case .strikethrough: return state.strikethrough
        case .code: return state.code
        case .highlight: return state.highlight
        case .link: return state.link
        case .text: return state.textStyle == .text
        case .heading: return state.textStyle == .heading(1)
        case .heading2: return state.textStyle == .heading(2)
        case .heading3: return state.textStyle == .heading(3)
        case .bulletedList: return state.listChecked == .bulleted
        case .numberedList: return state.listChecked == .numbered
        case .checklist: return state.listChecked == .checklist
        case .quote, .codeBlock, .divider, .table: return false
        }
    }

    /// Builds this tab's scoped bus (fork P2 "Host wiring"): every `Notification.Name`
    /// is suffixed with the documentId so warm tabs never share a channel, and
    /// `scopeByObject: true` activates the engine-side object filter (belt-and-
    /// suspenders against an accidental name collision). Format commands go
    /// through the editor controller instead; the bus carries only find.
    private static func makeBus(documentId id: String) -> MarkdownEditorBus {
        MarkdownEditorBus(
            findScrollToRange: Notification.Name("pf.md.findScroll.\(id)"),
            findClearHighlights: Notification.Name("pf.md.findClear.\(id)"),
            scopeByObject: true
        )
    }

    // MARK: - Formatting commands

    /// Applies a format command to this tab's live selection (one undoable
    /// edit); a no-op while no editor is mounted.
    func requestFormat(_ command: MarkdownFormatCommand) {
        editorController.apply(command.engineFormat)
    }

    /// Scrolls the mounted editor to an outline heading (sidebar click) through
    /// the find reveal+scroll bus leg's navigate-only mode (empty `allRanges` —
    /// an engine contract, see PAGEFLOW-FORK.md): reveal + scroll, no highlight.
    /// Ranges are computed over the DISPLAY text (what the engine scrolls),
    /// same contract as `searchManager`. Records the departure point on the
    /// navigation trail, so ⌘[ returns here (PDF outline-click behavior).
    func scrollToOutlineItem(_ item: MarkdownOutlineItem) {
        scrollToLine(item.lineIndex)
    }

    /// Before a Save As: images pasted while the note had no folder move next
    /// to it, and their absolute links turn relative, as one undoable edit.
    @discardableResult
    func adoptPastedImages(savedAt url: URL, store: PastedImageStore = .shared, whileApproved: () -> Bool = { true }) -> Bool {
        reconcileLiveText()
        let source = documentManager.text
        let edits = store.adoptFallbackImages(in: source, savedAt: url, whileApproved: {
            whileApproved() && (self.editorController.currentStorageText ?? self.documentManager.text).hasSameSource(as: source)
        })
        guard let first = edits.first, let last = edits.last else { return false }
        let ns = source as NSString
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var rebuilt = ""
        var cursor = span.location
        for edit in edits {
            rebuilt += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)) + edit.link
            cursor = NSMaxRange(edit.range)
        }
        if !editorController.replaceCharacters(in: [span], with: rebuilt, expectedSource: source,
                                               actionName: "Move Pasted Images") {
            documentManager.text = ns.replacingCharacters(in: span, with: rebuilt)
        }
        reconcileLiveText()
        return true
    }

    /// A `#heading` link: the first heading whose title matches by slug
    /// (`#Some Heading`, `#some-heading` and `#Some%20Heading` all match).
    func scrollToHeading(_ fragment: String) {
        let wanted = Self.headingSlug(fragment.removingPercentEncoding ?? fragment)
        guard let item = documentManager.outline.first(where: { Self.headingSlug($0.title) == wanted }) else { return }
        scrollToOutlineItem(item)
    }

    /// Lowercase words joined by hyphens, punctuation dropped (GitHub's anchors).
    static func headingSlug(_ title: String) -> String {
        title.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .joined(separator: "-")
    }

    /// A clicked local link's file: a `file:` URL as given, a path from the
    /// note's folder; `nil` for a relative link in an untitled note.
    func localLinkTarget(_ link: URL) -> URL? {
        if link.isFileURL {
            var components = URLComponents(url: link, resolvingAgainstBaseURL: true)
            components?.fragment = nil
            components?.query = nil
            return components?.url?.standardizedFileURL
        }
        let path = link.path(percentEncoded: false)
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let folder = documentManager.documentURL?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: path, relativeTo: folder).standardizedFileURL
    }

    /// Jump to a 0-based source line (outline click, Go to Line dialog).
    func scrollToLine(_ lineIndex: Int) {
        let text = editorController.currentDisplayText ?? documentManager.text
        guard let location = MarkdownOutline.lineStartLocation(ofLine: lineIndex, in: text) else { return }
        if let departure = editorController.readingPosition {
            navigationTrail.recordJump(from: departure)
        }
        bus.postFindScroll(
            documentId: documentId,
            range: NSRange(location: location, length: 0),
            currentIndex: 0,
            allRanges: []
        )
    }

    /// Number of source lines (1-based upper bound for the Go to Line dialog).
    var lineCount: Int {
        let text = editorController.currentDisplayText ?? documentManager.text
        return MarkdownOutline.lineCount(in: text)
    }

    // MARK: - Reading position (D7 — the PDF DocumentStateStore peer)

    /// The position the editor lands on next: armed at load from the store and
    /// re-armed with the live position whenever the editor is about to be built
    /// after warm-set eviction or a window transfer changes its viewport. Each
    /// request carries its own token, so the editor applies it once.
    var pendingReadingPosition: ReadingPositionRequest?

    /// Pulls this document's persisted reading position (if any) so the first
    /// mount restores it. Called by the load funnels right after a successful
    /// `documentManager.load` — the markdown peer of the PDF restore-at-load.
    func restoreReadingPositionIfAvailable() {
        guard let url = documentManager.documentURL,
              let state = DocumentStateStore.shared.state(for: url) else { return }
        if let scale = state.markdownScaleFactor { zoomScale = Self.clampZoom(scale) }
        // Table widths before the first styling pass, so tables open at the widths left.
        let widths = state.markdownTableColumnWidths?.mapValues { $0.map { $0.map { CGFloat($0) } } } ?? [:]
        if widths != editorController.tableColumnWidths {
            restoringTableWidths = true
            editorController.tableColumnWidths = widths
            restoringTableWidths = false
        }
        if let anchor = state.markdownAnchorOffset {
            let position = ReadingPosition(anchorOffset: anchor,
                                           offsetInViewport: state.markdownOffsetInViewport ?? 0,
                                           magnification: zoomScale)
            pendingReadingPosition = ReadingPositionRequest(position)
        }
    }

    /// Re-arms the restore with the LIVE position while the editor still exists
    /// (eviction, tear-off), so the rebuilt editor lands where the reader is —
    /// not where the document was loaded. A no-op without a mounted editor.
    func armReadingPositionRestore() {
        guard let position = editorController.readingPosition else { return }
        pendingReadingPosition = ReadingPositionRequest(position)
    }

    /// Persists the current reading position AND the zoom in one record. The
    /// position falls back to the last-saved value when no editor is mounted, so
    /// a zoom change alone never clobbers the saved position (and vice versa).
    /// The markdown peer of `persistViewState`.
    func persistReadingPosition() {
        guard let url = documentManager.documentURL else { return }
        let existing = DocumentStateStore.shared.state(for: url)
        let position = editorController.readingPosition
        DocumentStateStore.shared.save(
            .markdown(anchorOffset: position?.anchorOffset ?? existing?.markdownAnchorOffset,
                      offsetInViewport: position?.offsetInViewport ?? existing?.markdownOffsetInViewport,
                      scaleFactor: zoomScale, tableColumnWidths: existing?.markdownTableColumnWidths),
            for: url
        )
    }

    /// Set while the stored widths load into the editor, so loading writes nothing back.
    @ObservationIgnored private var restoringTableWidths = false

    // MARK: - Comments (doc 25)

    /// Whether the editor holds this note's comments (so a save writes them).
    @ObservationIgnored private var commentsLoaded = false

    /// Margin cards, the list, or hidden (the toolbar's Comments button).
    private(set) var commentsMode: MarkdownCommentsMode = .margin
    /// Open threads, for the Comments button's badge while comments are hidden.
    private(set) var openCommentCount = 0

    /// The Comments button's tooltip for the mode it is in.
    var commentsButtonHelp: String {
        switch commentsMode {
        case .hidden: return "Show comments"
        case .margin: return "All comments"
        case .list: return "Floating comments"
        }
    }

    /// The open count the button shows, only while comments are hidden.
    var hiddenCommentBadge: Int? { commentsMode == .hidden && openCommentCount > 0 ? openCommentCount : nil }

    /// the reference editor's Comments button: shows hidden comments, else switches
    /// between the margin and the list.
    func toggleCommentsList() {
        switch commentsMode {
        case .hidden, .list: editorController.commentsMode = .margin
        case .margin: editorController.commentsMode = .list
        }
        commentsMode = editorController.commentsMode
    }

    /// Where the reference editor's comment toasts ("Link copied") show.
    func showCommentToasts(_ post: @escaping (String) -> Void) {
        recoverySession?.onFailure = post
        editorController.onCommentsToast = { message in MainActor.assumeIsolated { post(message) } }
    }

    /// A `#thread-‹id›` link to this note: opens that comment.
    func openCommentThread(_ id: String) {
        editorController.openCommentThread(id)
        commentsMode = editorController.commentsMode
    }

    /// ⌥⇧C: hide comments, or show them again.
    func toggleCommentsHidden() {
        editorController.commentsMode = commentsMode == .hidden ? .margin : .hidden
        commentsMode = editorController.commentsMode
    }

    /// Loads the note's comments (the block its file ends with) into the
    /// editor. Called by the load funnels right after a successful
    /// `documentManager.load`, and after a reload.
    func loadComments() {
        let threads = MarkdownCommentBlock.threads(in: documentManager.commentBlock)
        commentsLoaded = true
        editorController.commentLinkBase = documentManager.documentURL
        editorController.commentThreads = threads
        openCommentCount = threads.filter { !$0.resolved }.count
    }

    /// A comment was posted, answered, edited, reacted to, resolved, reopened
    /// or deleted: the note's comment block changes, so the note is unsaved.
    private func persistComments(_ threads: [MarkdownCommentThread]) {
        commentsLoaded = true
        documentManager.setCommentBlock(Self.commentBlock(for: threads, keeping: documentManager.commentBlock))
    }

    /// Before the note is written: the comments' anchors move to the text being
    /// saved.
    private func syncCommentBlock() {
        guard commentsLoaded else { return }
        let threads = editorController.commentThreadsForSaving(text: documentManager.text)
        documentManager.setCommentBlock(Self.commentBlock(for: threads, keeping: documentManager.commentBlock))
    }

    /// The block for `threads`; the current one, byte for byte, when it already
    /// holds them.
    static func commentBlock(for threads: [MarkdownCommentThread], keeping block: String) -> String {
        MarkdownCommentBlock.threads(in: block) == threads ? block : MarkdownCommentBlock.block(for: threads)
    }

    /// After the note is written: links to its comments name the file it is now.
    func noteWasSaved() {
        editorController.commentLinkBase = documentManager.documentURL
        recoverySession?.checkpoint()
    }

    /// Keeps the table column widths the user set with the document's view
    /// state, next to its reading position and zoom.
    private func persistTableColumnWidths(_ widths: [String: [CGFloat?]]) {
        guard !restoringTableWidths, let url = documentManager.documentURL else { return }
        let existing = DocumentStateStore.shared.state(for: url)
        DocumentStateStore.shared.save(
            .markdown(anchorOffset: existing?.markdownAnchorOffset, offsetInViewport: existing?.markdownOffsetInViewport,
                      scaleFactor: zoomScale,
                      tableColumnWidths: widths.mapValues { $0.map { $0.map { Double($0) } } }),
            for: url
        )
    }

    // MARK: - Visual zoom (PDF-style, per-document, persisted)

    /// This document's magnification (1.0 = 100%). Projected onto the editor's
    /// scroll view; a two-finger pinch / Ctrl-scroll reports back through
    /// ``handleMagnificationChanged(_:)``. Persisted with the reading position, so
    /// each file reopens at the zoom it was left at — PDF parity, not a font-size
    /// change.
    var zoomScale: CGFloat = 1.0

    private static func clampZoom(_ v: CGFloat) -> CGFloat {
        min(max(v, DesignTokens.markdownMinZoom), DesignTokens.markdownMaxZoom)
    }

    /// A user gesture (pinch end / Ctrl-scroll) changed the magnification — adopt
    /// and persist it. Guarded so re-projecting the same value is a no-op.
    func handleMagnificationChanged(_ value: CGFloat) { setZoom(value) }

    /// ⌘+ / ⌘− / ⌘0 (routed from the View menu). Multiplicative steps, PDF-style.
    func zoomIn() { setZoom(zoomScale * DesignTokens.markdownZoomStepFactor) }
    func zoomOut() { setZoom(zoomScale / DesignTokens.markdownZoomStepFactor) }
    func resetZoom() { setZoom(1.0) }

    /// Coalesces the per-gesture-tick zoom persist: `DocumentStateStore.save`
    /// JSON-encodes the whole store into UserDefaults, and a Ctrl-scroll burst
    /// fires setZoom dozens of times a second — writing each tick contributed
    /// visible zoom lag. Trailing-debounced; lifecycle boundaries flush the
    /// settled value anyway via `persistReadingPosition`.
    @ObservationIgnored private var zoomPersistWorkItem: DispatchWorkItem?

    private func setZoom(_ target: CGFloat) {
        let clamped = Self.clampZoom(target)
        guard abs(clamped - zoomScale) > 0.0001 else { return }
        #if DEBUG
        NSLog("[ZOOMCMD] %.3f → %.3f", zoomScale, clamped)
        #endif
        zoomScale = clamped
        // Persist the zoom WITHOUT the live scroll offset: a centered zoom shifts
        // the clip origin only AFTER the wrapper projects (next update), so the
        // live offset here is stale. Keep the last-saved offset; the normal
        // reading-position persist (scroll / blur / quit) captures the settled one.
        zoomPersistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = self.documentManager.documentURL else { return }
            let existing = DocumentStateStore.shared.state(for: url)
            DocumentStateStore.shared.save(
                .markdown(anchorOffset: existing?.markdownAnchorOffset,
                          offsetInViewport: existing?.markdownOffsetInViewport,
                          scaleFactor: self.zoomScale, tableColumnWidths: existing?.markdownTableColumnWidths),
                for: url
            )
        }
        zoomPersistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    // MARK: - Navigation trail (⌘[ / ⌘] — the PDF page-history peer)

    /// Scroll-jump history. A stored property on @Observable content, so the
    /// Go menu's canGoBack/canGoForward gates re-evaluate on every mutation.
    private(set) var navigationTrail = MarkdownNavigationTrail<ReadingPosition>()

    var canGoBack: Bool { navigationTrail.canGoBack }
    var canGoForward: Bool { navigationTrail.canGoForward }

    func goBack() {
        guard let current = editorController.readingPosition,
              let target = navigationTrail.goBack(from: current) else { return }
        editorController.restore(target)
    }

    func goForward() {
        guard let current = editorController.readingPosition,
              let target = navigationTrail.goForward(from: current) else { return }
        editorController.restore(target)
    }

    // MARK: - External-change reload (ADR-0012 D5, S9)

    /// Whether the external-change Reload/Keep prompt should be shown for this tab
    /// now: it is backed by a file whose on-disk bytes changed since our baseline.
    /// Pure decision (no UI), so the host's activation hook and the tests share it.
    var shouldPromptForExternalChange: Bool {
        documentManager.hasDocumentURL && documentManager.diskWasModifiedExternally()
    }

    /// Applies "Reload" from the external-change prompt: re-read the file and reset
    /// the editor undo stack (⌘Z can't cross an external rewrite). Reconciling the
    /// live editor is intentionally skipped — Reload discards the in-memory draft.
    /// The re-read `documentManager.text` propagates to the mounted editor through
    /// its SwiftUI binding; the editor keeps the caret and the reading position
    /// across that rebuild. Throws if the file can't be read (caller keeps the buffer).
    func reloadFromDisk() throws {
        editorController.keepPositionAcrossNextRebuild()
        let previous = documentManager.text
        try documentManager.reload()
        if !documentManager.text.hasSameSource(as: previous) { editorController.resetFolds() }
        loadComments()
        undoManager.removeAllActions()
    }

    @ObservationIgnored private(set) var isReloadingFromDisk = false

    @discardableResult
    func reloadFromDiskInBackground(whileCurrent: () -> Bool) async throws -> Bool {
        guard !isReloadingFromDisk else { return false }
        isReloadingFromDisk = true
        defer { isReloadingFromDisk = false }
        reconcileLiveText()
        let previous = documentManager.text
        let applied = try await documentManager.reloadWithCompletion(whileCurrent: {
            self.reconcileLiveText()
            return whileCurrent()
        }, willApply: {
            self.editorController.keepPositionAcrossNextRebuild()
        })
        if applied {
            if !documentManager.text.hasSameSource(as: previous) { editorController.resetFolds() }
            loadComments()
            undoManager.removeAllActions()
        }
        return applied
    }

    // MARK: - Print (S9)

    /// A throwaway, page-width `NSView` that renders the live document for printing
    /// (S9). Wraps the fork seam `MarkdownEditorController.makePrintTextView(pageWidth:)`
    /// so the engine dependency stays inside this content type (the host receives a
    /// plain `NSView` to drive `NSPrintOperation`). The engine styles the source for
    /// paper; math and diagrams render in dark ink even when the editor is pinned
    /// dark. `nil` when no editor is mounted.
    func makePrintView(pageWidth: CGFloat) -> NSView? {
        MarkdownEditorView.renderingForPrint { editorController.makePrintTextView(pageWidth: pageWidth) }
    }

    // MARK: - Encoding-downgrade note (ADR-0008, S9)

    /// One-shot latch: the UTF-8 encoding-downgrade note has been surfaced for this
    /// document, so a subsequent save won't nag (ADR-0008 / S9).
    @ObservationIgnored private var didShowEncodingDowngradeNote = false

    /// Whether to surface the one-time "saved as UTF-8" note now: the last save
    /// downgraded a UTF-16/32 (or 8-bit-overflow) source to UTF-8 and the note has
    /// not been shown for this document yet. Flips the one-shot latch so a later save
    /// can't nag. Pure decision, so the host save call site and the tests share it.
    func consumeEncodingDowngradeNote() -> Bool {
        guard documentManager.encodingWasDowngraded, !didShowEncodingDowngradeNote else { return false }
        didShowEncodingDowngradeNote = true
        return true
    }

    /// Reconcile the live editor's storage-form text into the durable document
    /// (fork P1, ADR-0012 D2/R3) — the single canonical bridge the host calls
    /// BEFORE any dirty/content/save read, so a tab edited <1s before ⌘Q/⌘O is
    /// never judged on stale `text`. A no-op when no editor is mounted (the live
    /// read returns `nil`). Routed through the `liveStorageText` seam so tests can
    /// drive it headlessly without a mounted coordinator.
    func reconcileLiveText() {
        // The production seam already wrote the binding (an echo the editor
        // ignores); this assignment is for the test seam and the no-editor case.
        // Skipped when nothing changed: assigning the same string still fires
        // @Observable and re-derives the outline + word count.
        if let latest = liveStorageText(), latest != documentManager.text {
            documentManager.text = latest
        }
        syncCommentBlock()
    }

    /// Ordered teardown when the tab is closed (peer of `PDFContent.cleanup`).
    func cleanup() {
        recoverySession?.retire()
        reconcileLiveText()
        releaseEditorSurface()
        documentManager.close()
    }

    /// Surfaces the one-time "saved as UTF-8" note if the last save downgraded the
    /// encoding and it hasn't been shown yet (ADR-0008 / S9). The single owner of
    /// this decision — the interactive ⌘S / Save-As paths (TabManager) and the
    /// modal quit path (DirtyDoc) both call it, so a document is never nagged twice
    /// and tests never flip the latch. A no-op in the test host.
    func presentEncodingDowngradeNoteIfNeeded() {
        guard !TestEnvironment.isRunningTests else { return }
        guard consumeEncodingDowngradeNote() else { return }
        presentMarkdownEncodingDowngradeNote(title: documentManager.documentTitle,
                                             originalEncoding: documentManager.fidelity.encoding)
    }

    /// Warns once per open that the file had damaged UTF-8 bytes. A no-op in
    /// the test host and for clean files.
    func presentInvalidUTF8NoteIfNeeded() {
        guard !TestEnvironment.isRunningTests, documentManager.hasInvalidUTF8 else { return }
        let title = documentManager.documentTitle
        // After the opening tab is on screen, so the sheet lands on its window.
        DispatchQueue.main.async { presentMarkdownInvalidUTF8Note(title: title) }
    }
}

// MARK: - MarkdownContent: TabDocument

/// Markdown's half of the content contract. `undoManager`, `undoAvailability`,
/// and `cleanup()` already live on the class; this adds the open/save predicates
/// (formerly `switch` arms in `TabSession`) and the modal quit-path save recipe
/// (formerly the `DirtyDoc.markdown` arm — reconcile the live editor first so the
/// trailing keystroke isn't dropped, then surface the one-time UTF-8 note).
extension MarkdownContent: TabDocument {
    var restoreBookmark: Data? { documentManager.securityScopedBookmark }

    var hasContent: Bool {
        documentManager.hasDocumentURL || !documentManager.text.isEmpty
    }

    var canReplaceWithoutPrompt: Bool {
        !documentManager.hasDocumentURL && !documentManager.isDirty
    }

    /// Native edits publish to the model later. Keep Save available so its action
    /// can reconcile the live source before checking whether a write is needed.
    var canSave: Bool { true }

    /// Save As… always applies — even an untitled buffer can be written to a new file.
    var canSaveAs: Bool { true }

    var isDirty: Bool { documentManager.isDirty }

    var documentTitle: String { documentManager.documentTitle }

    /// A dirty untitled buffer must route to Save-As; `saveSync()` returns false for it.
    /// A Save-As still in flight is a destination: `saveSync()` drains it first.
    var needsSaveAs: Bool { !documentManager.hasSaveDestination }

    @discardableResult
    func saveSync() -> Bool {
        reconcileLiveText()
        let saved = documentManager.saveSync()
        // The quit path has no `TabManager` on hand, so it surfaces the one-time
        // UTF-8 downgrade note through this shared entry — the same latch/guard
        // the interactive ⌘S path uses, so a document is never nagged twice.
        if saved {
            presentEncodingDowngradeNoteIfNeeded()
            noteWasSaved()
        }
        return saved
    }

    func finishPendingWrites() { documentManager.finishPendingWrites() }

    func saveAsSync(to url: URL, isSecurityScoped: Bool) -> Bool {
        reconcileLiveText()
        let saved = documentManager.saveAsSync(to: url, isSecurityScoped: isSecurityScoped)
        if saved {
            presentEncodingDowngradeNoteIfNeeded()
            noteWasSaved()
        }
        return saved
    }

    // Markdown has no cross-activation view snapshot yet (deferred). The methods
    // are deliberate no-ops, but required by the contract so a new content type
    // must decide its own snapshot behavior rather than silently inheriting one.
    func captureViewSnapshot() {}
    func restoreViewSnapshot() {}
    func clearSearchSnapshot() {}
}

// MARK: - Find-scroll post helper (the one userInfo shape the engine reads)

extension MarkdownEditorBus {
    /// Posts the scoped reveal+scroll request in the ONE userInfo shape
    /// `handleFindScrollToRange` reads. Empty `allRanges` = navigate-only
    /// (outline clicks): reveal + scroll without painting highlights — an
    /// engine contract (PAGEFLOW-FORK.md). A no-op when the bus has no leg.
    func postFindScroll(documentId: String, range: NSRange, currentIndex: Int, allRanges: [NSRange]) {
        guard let name = findScrollToRange else { return }
        NotificationCenter.default.post(
            name: name,
            object: documentId,
            userInfo: [
                "range": range,
                "currentIndex": currentIndex,
                "allRanges": allRanges
            ]
        )
    }
}

private extension MarkdownFormatCommand {
    var engineFormat: MarkdownFormat {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .underline: return .underline
        case .strikethrough: return .strikethrough
        case .code: return .code
        case .highlight: return .highlight
        case .link: return .link
        case .text: return .paragraph
        case .heading: return .heading(level: 1)
        case .heading2: return .heading(level: 2)
        case .heading3: return .heading(level: 3)
        case .bulletedList: return .bulletedList
        case .numberedList: return .numberedList
        case .checklist: return .checklist
        case .quote: return .quote
        case .codeBlock: return .codeBlock
        case .divider: return .divider
        case .table: return .table
        }
    }
}
