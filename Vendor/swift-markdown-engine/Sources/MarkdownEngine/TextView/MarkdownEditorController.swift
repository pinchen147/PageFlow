//
//  MarkdownEditorController.swift
//  MarkdownEngine
//
//  PageFlow fork seam (doc 10 §3 / ADR-0010): a public, host-retained handle over
//  the live editor. It started as patch P1 — a SYNCHRONOUS read of the editor's
//  source plus a force-flush of its pending binding write, because the engine
//  publishes the source to the host @Binding<String> on the trailing edge of a
//  typing burst (a 1 s debounce, `scheduleTextSync` in
//  NativeTextViewCoordinator+TextDelegate.swift) and a synchronous quit/close
//  saveSync would otherwise read STALE text and drop the last burst (risk R3).
//  It has since accreted the other host↔editor seams that need the SAME bound
//  editor: format commands, a throwaway print-view factory (makePrintTextView,
//  S9) and reading-position + scroll seams for navigation history.
//
//  The host creates one of these per editor session (a strict 1:1 with one mounted
//  editor) and passes it into NativeTextViewWrapper(editorController:). The coordinator
//  binds itself on make and re-binds on update; the link clears automatically when
//  either side is torn down (both references are weak). Every method is a no-op
//  (returning nil / doing nothing) when no editor is currently bound.
//

import AppKit

/// Host-retained seam over a bound `NativeTextViewWrapper`'s live editor, covering the
/// host↔editor concerns that all need the same mounted text view: synchronous save-time
/// source read + pending-write flush (PageFlow's modal quit/close `saveSync` reads the
/// latest keystroke even though the binding write is debounced), format commands, a
/// print-view factory, and reading-position and scroll seams.
@MainActor
public final class MarkdownEditorController {
    /// Set by ``NativeTextViewCoordinator`` when the editor is created; cleared on teardown.
    /// Weak so the controller never keeps a torn-down editor alive.
    private weak var attachedSession: AnyObject?
    var sessionFailure: Error?
    weak var semanticHost: SemanticEditorHostSession?
    weak var semanticComments: MarkdownCommentsController?
    var pendingSemanticReload = false
    var semanticReloadPosition: ReadingPosition?

    /// Whether selection and Find offsets address visible semantic text.
    public var usesSemanticStorage: Bool { semanticCoordinator != nil }
    var coordinator: NativeTextViewCoordinator? {
        get { attachedSession as? NativeTextViewCoordinator }
        set {
            let previous = coordinator
            guard previous !== newValue else { return }
            previous?.invalidateSectionNavigation()
            attachedSession = newValue
            newValue?.refreshSectionNavigation()
        }
    }

    var semanticCoordinator: NativeSemanticDocumentCoordinator? {
        get { attachedSession as? NativeSemanticDocumentCoordinator }
        set {
            coordinator?.invalidateSectionNavigation()
            attachedSession = newValue
        }
    }

    /// Export the committed document; encoding failures must prevent saving.
    public func exportSource() throws -> String? {
        if let sessionFailure { throw sessionFailure }
        if let semanticCoordinator { return try semanticCoordinator.exportResult().source }
        return coordinator?.snapshotStorageText()
    }

    /// Publish pending committed edits before saving, without committing provisional IME text.
    @discardableResult
    public func flushCommittedSource() throws -> String? {
        if let sessionFailure { throw sessionFailure }
        if let semanticCoordinator { return try semanticCoordinator.flushCommittedSource() }
        return coordinator?.commitPendingTextNow()
    }

    /// Adopt imported image resources through structured descriptors and one Undo transaction.
    public func adoptImageLinks(ranges: [NSRange], replacements: [String], expectedSource: String) throws -> Bool? {
        guard let semanticCoordinator else { return nil }
        return try semanticCoordinator.adoptImageLinks(ranges: ranges, replacements: replacements, expectedSource: expectedSource)
    }

    /// Map an explicit source navigation target into the live visible text.
    public func visibleRange(forSourceRange range: NSRange) throws -> NSRange? {
        guard let owner = semanticCoordinator else { return range }
        let map = try owner.exportResult().sourceMap
        guard let start = map.visibleOffset(for: .init(rawValue: range.location), affinity: .leading),
              let end = map.visibleOffset(for: .init(rawValue: NSMaxRange(range)), affinity: .trailing),
              start.rawValue <= end.rawValue else { return nil }
        return NSRange(location: start.rawValue, length: end.rawValue - start.rawValue)
    }

    /// Original-byte splice provenance, available for the semantic document backend.
    public func exportSourceReceipt() throws -> SemanticMarkdownExportResult? {
        if let sessionFailure { throw sessionFailure }
        return try semanticCoordinator?.exportResult()
    }

    let foldSession = MarkdownFoldSession()

    /// Called when disclosure state or command availability changes.
    public var onFoldingStateChange: (() -> Void)?

    /// Whether the section containing the caret is collapsed.
    public var isCurrentSectionFolded: Bool {
        if let host = semanticHost, let region = host.currentRegion { return host.collapsedBlocks.contains(region.id) }
        guard let region = coordinator?.currentFoldRegion else { return false }
        return foldSession.collapsedHeadings.contains(region.heading.location)
    }

    /// Whether the view can safely perform this disclosure command now.
    public func canPerformFoldingCommand(_ command: MarkdownEditorKeyCommand) -> Bool {
        semanticHost?.canFold(command) ?? coordinator?.canPerformFolding(command) ?? false
    }

    /// Toggle one section, collapse all, or expand all without changing source or text Undo.
    @discardableResult
    public func performFoldingCommand(_ command: MarkdownEditorKeyCommand) -> Bool {
        semanticHost?.fold(command) ?? coordinator?.performFolding(command) ?? false
    }

    /// Clear session disclosure choices after an authoritative source-changing reload.
    public func resetFolds() {
        foldSession.reset()
        semanticHost?.collapsedBlocks.removeAll()
        semanticHost?.refreshFolds()
        coordinator?.applyFoldPresentation()
    }

    public init() {
        commentStore.onPersist = { [weak self] threads in self?.onCommentThreadsChange?(threads) }
        commentStore.onModeChange = { [weak self] mode in self?.onCommentsModeChange?(mode) }
    }

    /// The live editor source, read SYNCHRONOUSLY from the underlying `NSTextView` —
    /// not from the (possibly stale) host `@Binding`. The native string IS the
    /// source, so this equals ``currentDisplayText``; kept for embedders that read
    /// it by this name. Returns `nil` only when no editor is currently bound.
    ///
    /// Safe to call inside a nested modal run loop (e.g. an `NSAlert` shown from
    /// `applicationShouldTerminate`). Does NOT mutate the binding or editor state.
    public var currentStorageText: String? {
        coordinator?.snapshotStorageText()
    }

    /// The exact native string used for selection and find ranges. Live preview
    /// hides syntax through attributes, so it is the source itself, in source
    /// UTF-16 coordinates. Returns `nil` when no editor is bound.
    /// Visible Find text includes retained table cells in row order.
    public var currentSearchText: String? {
        if let semanticCoordinator { return NativeSemanticSearchIndex(owner: semanticCoordinator).text }
        return currentDisplayText
    }

    public var currentDisplayText: String? {
        semanticCoordinator?.textView.string ?? coordinator?.snapshotDisplayText()
    }

    /// Applies a format command to the mounted editor's selection.
    public func apply(_ format: MarkdownFormat) {
        if let semanticCoordinator { _ = semanticCoordinator.applyFormat(format) }
        else { coordinator?.apply(format) }
    }

    /// The formatting at the editor's selection, as the selection bar shows it.
    public var formatState: MarkdownFormatState {
        semanticCoordinator?.currentFormatState ?? coordinator?.currentFormatState() ?? MarkdownFormatState()
    }

    /// Called whenever the selection's formatting changes (selection or edit).
    public var onFormatStateChange: ((MarkdownFormatState) -> Void)?

    /// Whether `command` can act on the table the caret is in now: false
    /// outside a table, or where its Cell actions row is disabled.
    public func canPerformTableCommand(_ command: MarkdownTableCommand) -> Bool {
        semanticCoordinator?.canPerformTable(command) ?? coordinator?.tableEditingSession.canPerform(command) ?? false
    }

    /// Runs `command` on the caret's table, as its Cell actions row does.
    @discardableResult
    public func performTableCommand(_ command: MarkdownTableCommand) -> Bool {
        semanticCoordinator?.performTable(command) ?? coordinator?.tableEditingSession.performCommand(command) ?? false
    }

    /// View-only table column widths (doc 24 §7.3.6, deviation a): per table
    /// key, one box width per column, nil for Auto. They never reach the file;
    /// the host keeps them with the document's view state.
    public var tableColumnWidths: [String: [CGFloat?]] {
        get { tableWidthsStore.widths }
        set {
            guard newValue != tableWidthsStore.widths else { return }
            tableWidthsStore.widths = newValue
            semanticCoordinator?.refreshTableWidths()
            onTableColumnWidthsChange?(newValue)
        }
    }

    /// The widths, readable by the styler on any thread.
    nonisolated let tableWidthsStore = TableWidthsStore()

    /// Called when the user sets, resizes or clears a column width.
    public var onTableColumnWidthsChange: (([String: [CGFloat?]]) -> Void)?

    // MARK: - Comments (doc 25)

    /// The note's comment threads (the reference editor's comments, for one local
    /// user). The host sets them from the note's sidecar when the note opens;
    /// the editor finds each one's text by its quote.
    public var commentThreads: [MarkdownCommentThread] {
        get { commentStore.threads }
        set {
            if let anchors = semanticComments?.semanticAnchors {
                do { try anchors.load(newValue) } catch { sessionFailure = error }
            } else { commentStore.load(newValue, text: coordinator?.textView.map { $0.string as NSString }) }
        }
    }

    /// Called when a comment is posted, replied to, edited, reacted to,
    /// resolved, reopened or deleted: the host writes the sidecar. Anchors in
    /// it are the ones the saved note matches.
    public var onCommentThreadsChange: (([MarkdownCommentThread]) -> Void)?

    /// The threads with every anchor taken from `text`, the note being saved
    /// now; a thread whose text is gone is marked detached.
    public func commentThreadsForSaving(text: String) -> [MarkdownCommentThread] {
        guard !commentStore.needsResolve else { return commentStore.threads }
        return commentStore.threadsForSaving(text: text as NSString)
    }

    /// Resolve live annotation coordinates into the same committed source being saved.
    public func committedCommentThreadsForSaving(text: String) throws -> [MarkdownCommentThread] {
        if let anchors = semanticComments?.semanticAnchors { return try anchors.threadsForSaving() }
        return commentThreadsForSaving(text: text)
    }

    let commentStore = MarkdownCommentStore()

    /// Margin cards, the list, or hidden; the host's Comments button sets it.
    public var commentsMode: MarkdownCommentsMode {
        get { commentStore.mode }
        set {
            if let comments = (semanticComments ?? coordinator?.comments) { comments.setMode(newValue) } else { commentStore.mode = newValue }
        }
    }

    /// Called when the mode changes, from the host or from the list's own buttons.
    public var onCommentsModeChange: ((MarkdownCommentsMode) -> Void)?

    /// The note's address: More's Copy link copies it with `#thread-‹id›`.
    public var commentLinkBase: URL?

    /// The editor's keyboard commands, set by a host that rebinds them live
    /// (its settings change while the editor is open); nil uses the
    /// configuration's `keyBindings`.
    public var keyBindings: MarkdownKeyBindings?

    /// the reference editor's toasts ("Link copied"), for the host to show.
    public var onCommentsToast: ((String) -> Void)?

    /// Opens a thread as a `#thread-‹id›` link asks: brings its text into
    /// view and opens its card (the list for a resolved or detached one).
    public func openCommentThread(_ id: String) {
        guard let comments = semanticComments ?? coordinator?.comments else {
            commentStore.pendingOpenID = id
            return
        }
        comments.openLinked(id)
    }

    /// Whether the current responder is live editable annotation input owned by
    /// this bound editor. Hosts query the target window immediately before an
    /// automatic focus claim; open drafts alone do not own the keyboard.
    public func ownsAnnotationResponder(_ responder: NSResponder?) -> Bool {
        (semanticComments ?? coordinator?.comments)?.ownsAnnotationResponder(responder) ?? false
    }

    /// The Comment command, for a host's menu: comments on the selection, or
    /// opens the comment at the caret. With neither, `onCommentsToast` says what
    /// to select: a menu click has no selection bar to show it disabled.
    public func performCommentCommand() {
        guard let comments = semanticComments ?? coordinator?.comments else { return }
        if !comments.commandHasTarget { onCommentsToast?("Select some text or table cells to comment") }
        comments.commandComment()
    }

    /// The thread id in a comment link's fragment (`thread-‹id›`), if it is one.
    public static func commentThreadID(inFragment fragment: String?) -> String? {
        guard let fragment, fragment.hasPrefix("thread-"), fragment.count > 7 else { return nil }
        return String(fragment.dropFirst(7))
    }

    /// Builds a throwaway, print-ready `NSView` for host-side printing (PageFlow
    /// fork seam, S9): the live document's source styled for paper through the
    /// engine's own layout fragment, laid out at `pageWidth` (see
    /// ``MarkdownPrintRenderer``). Returns `nil` when no editor is bound. A pure
    /// read; does NOT mutate the binding or editor state.
    public func makePrintTextView(pageWidth: CGFloat) -> NSView? {
        if let owner = semanticCoordinator {
            do {
                let source = try owner.exportResult().source
                return MarkdownPrintRenderer.makePrintTextView(source: source, configuration: owner.configuration,
                    fontName: owner.documentStorage.baseFont.fontName, fontSize: owner.documentStorage.baseFont.pointSize,
                    baseFont: owner.documentStorage.baseFont, pageWidth: pageWidth)
            } catch { owner.onExportFailure?(error); return nil }
        }
        guard let coordinator, let textView = coordinator.textView else { return nil }
        let baseFont = (textView as? NativeTextView)?.baseFont ?? textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return MarkdownPrintRenderer.makePrintTextView(
            source: textView.string,
            configuration: coordinator.configuration,
            fontName: coordinator.fontName,
            fontSize: coordinator.fontSize,
            baseFont: baseFont,
            pageWidth: pageWidth
        )
    }

    /// Force the engine's pending (debounced) binding write to happen NOW: writes the
    /// live source straight into the host `@Binding<String>` and updates the
    /// coordinator's de-dupe guard, so any code that reads the binding afterwards sees
    /// the latest keystroke. During an input-method composition it publishes the
    /// committed source and leaves the composition open. Returns the committed text,
    /// or `nil` if no editor is bound.
    ///
    /// Synchronous and idempotent. Prefer ``currentStorageText`` for a pure read inside
    /// a modal loop; use this when the host also needs the live binding/dirty state
    /// reconciled before saving.
    @discardableResult
    public func commitPendingText() -> String? {
        coordinator?.commitPendingTextNow()
    }

    /// Replaces ordered, disjoint UTF-16 source ranges with one literal string.
    /// The edit is atomic and undoable. Returns false without changing the editor
    /// if unbound, read-only, composing, or if the exact source/ranges are stale.
    @discardableResult
    public func replaceCharacters(
        in ranges: [NSRange], with replacement: String, expectedSource: String,
        actionName: String = "Replace"
    ) -> Bool {
        coordinator?.replaceSourceRanges(
            ranges, with: replacement, expectedSource: expectedSource, actionName: actionName
        ) ?? false
    }

    /// Replaces visible emphasis-projected matches as one canonical source edit.
    /// Ranges are ordered, disjoint UTF-16 offsets in the emphasis-only visible text.
    /// Surviving emphasis stays balanced; inserted text inherits each match's first
    /// character style. Returns the resulting caret, or nil for a stale, protected,
    /// read-only or unbound editor. Replace All is one native Undo operation.
    @discardableResult
    public func replaceEmphasisMatches(
        in visibleRanges: [NSRange], with replacement: String, expectedSource: String,
        actionName: String = "Replace"
    ) -> NSRange? {
        if let semanticCoordinator {
            return semanticCoordinator.replaceSearchRanges(visibleRanges, with: replacement,
                expectedText: expectedSource, actionName: actionName)
        }
        guard let coordinator,
              let plan = MarkdownEmphasisEditPlanner.replacement(
                text: replacement, visibleRanges: visibleRanges,
                projection: MarkdownEmphasisProjection(source: expectedSource)),
              coordinator.replaceSourceRanges(
                [plan.replacementRange], with: plan.replacement, expectedSource: expectedSource,
                actionName: actionName, selectionAfter: plan.selectionAfter) else { return nil }
        return plan.selectionAfter
    }

    // MARK: - Image drops (doc 26 §9)

    /// The places near the viewport where a dropped image can land, as source
    /// offsets, top to bottom. Empty when no editor is bound.
    public var dropSlotsNearViewport: [Int] {
        if let host = semanticHost, let receipt = try? host.sourceReceipt() {
            let view = host.owner.textView
            return receipt.blockRanges.values.compactMap { range in
                guard let visible = receipt.sourceMap.visibleOffset(for: .init(rawValue: range.location), affinity: .leading),
                      let rect = host.lineRect(at: visible.rawValue), rect.intersects(view.visibleRect.insetBy(dx: 0, dy: -100)) else { return nil }
                return range.location
            }.sorted()
        }
        return (coordinator?.textView as? NativeTextView)?.dropSlotsNearViewport().map(\.offset) ?? []
    }

    /// Imports `drop` at `slot` through the same entry a real drop uses: the
    /// host's image hook, then the insertion at the slot mapped through any
    /// edit made meanwhile. Replays drive it; a synthetic drag cannot.
    public func importImages(_ drop: MarkdownImageDrop, at slot: Int) {
        if let semanticCoordinator { semanticCoordinator.importSemanticImages(drop, at: slot) }
        else { (coordinator?.textView as? NativeTextView)?.importImages(drop, at: slot) }
    }

    /// Moves a source block through the same validated transaction used by native drags.
    /// `kind` is image, equation, diagram, code, or table; offsets are UTF-16.
    @discardableResult
    public func moveBlock(kind: String, sourceRange: NSRange, to slot: Int, copying: Bool = false) -> Bool {
        if let semanticCoordinator { return semanticCoordinator.moveSemanticBlock(kind: kind, sourceRange: sourceRange, to: slot, copying: copying) }
        guard let coordinator, let kind = BlockMovePasteboard.Kind(rawValue: kind),
              let payload = coordinator.blockMovePayload(range: sourceRange, kind: kind) else { return false }
        return coordinator.moveBlock(payload, to: slot, copying: copying)
    }

    // MARK: - Section navigation

    /// Enables canonical heading publication for the displayed editor. Disabled by default.
    public var isSectionNavigationEnabled = false {
        didSet {
            guard oldValue != isSectionNavigationEnabled else { return }
            coordinator?.invalidateSectionNavigation()
            if isSectionNavigationEnabled { coordinator?.refreshSectionNavigation() }
        }
    }

    /// Delivers the committed snapshot when targets, visibility or availability change.
    /// Consume this value directly; querying `sectionNavigationSnapshot` reconciles again.
    public var onSectionNavigationChange: ((MarkdownSectionNavigationSnapshot?) -> Void)?

    /// Reconciles the native viewport and returns current headings/visible ranks;
    /// nil while unavailable. Publication callbacks receive this committed value directly.
    public var sectionNavigationSnapshot: MarkdownSectionNavigationSnapshot? {
        if let semanticHost { return semanticHost.navigationSnapshot() }
        coordinator?.refreshSectionNavigation()
        return coordinator?.sectionNavigationState.snapshot
    }

    /// Reads a bounded excerpt, or nil when the target's editor revision has retired.
    public func sectionPreview(for target: MarkdownSectionTarget) -> MarkdownSectionPreview? {
        if let semanticHost { return semanticHost.preview(target) }
        return coordinator?.sectionPreview(for: target)
    }

    /// Scrolls without changing source, selection, Find or Undo. Input protection defers
    /// execution; validity is checked again then. Reports departure only after a changed landing.
    public func scrollToSection(_ target: MarkdownSectionTarget,
                                whileValid: @escaping () -> Bool,
                                didNavigate: @escaping (ReadingPosition) -> Void) {
        if let semanticHost { semanticHost.scroll(to: target, whileValid: whileValid, didNavigate: didNavigate) }
        else { coordinator?.scrollToSection(target, whileValid: whileValid, didNavigate: didNavigate) }
    }

    // MARK: - Reading position (D7)

    /// Where the reader is, in document terms (top source line + its offset in
    /// the viewport + magnification). `nil` when no editor is bound or nothing
    /// is laid out yet. A pure O(visible) read.
    public var readingPosition: ReadingPosition? {
        semanticHost?.readingPosition() ?? (coordinator?.textView as? NativeTextView)?.readingPosition()
    }

    /// The source offset of the line the reader is at: a quarter of the way
    /// down the visible text, where Find and outline jumps land a heading.
    /// For a host's "current section"; nil when unbound or not laid out.
    public var readingLineOffset: Int? {
        semanticHost?.readingPosition()?.anchorOffset ?? (coordinator?.textView as? NativeTextView)?.readingLineOffset()
    }

    /// Lands the viewport on `position` (lays out its paragraph and aligns the
    /// source line). A no-op when no editor is bound; returns whether it landed.
    @discardableResult
    public func restore(_ position: ReadingPosition) -> Bool {
        semanticHost?.restore(position) ?? (coordinator?.textView as? NativeTextView)?.restore(position) ?? false
    }

    /// Defers restoration until protected native input settles. Reports the execution-time
    /// departure only after a successful restore, provided host ownership remains valid.
    public func restore(_ position: ReadingPosition, whileValid: @escaping () -> Bool,
                        didRestore: @escaping (ReadingPosition) -> Void) {
        if let semanticHost {
            semanticHost.restore(position, whileValid: whileValid, didRestore: didRestore)
        } else { coordinator?.restoreWhenInputSettles(position, whileValid: whileValid, didRestore: didRestore) }
    }

    /// Asks the editor to put the caret and the reader back after the NEXT
    /// host-driven rebuild (a reload of the same document replaces the whole
    /// storage). Call it right before assigning the new text.
    public func keepPositionAcrossNextRebuild() {
        if let semanticHost {
            pendingSemanticReload = true
            semanticReloadPosition = semanticHost.readingPosition()
            return
        }
        guard let coordinator, let textView = coordinator.textView else { return }
        coordinator.pendingRebuildRestore = (
            (textView as? NativeTextView)?.readingPosition(),
            textView.selectedRange().location
        )
    }

    /// The caret (insertion point) as a UTF-16 offset; `nil` when unbound.
    public var caretLocation: Int? {
        semanticCoordinator?.textView.selectedRange().location ?? coordinator?.textView?.selectedRange().location
    }

    // MARK: - Scroll seam (PageFlow fork: reading-position + navigation history)

    /// The editor's current vertical scroll offset (the clip view's bounds origin
    /// y — the same value the engine's own warm-tab scroll retention stores).
    /// `nil` when no editor is bound. A pure read.
    public var currentScrollOffset: CGFloat? {
        (semanticCoordinator?.textView ?? coordinator?.textView)?.enclosingScrollView?.contentView.bounds.origin.y
    }

    /// Scrolls the live editor to `offset` (clamped by the scroll view's own
    /// insets/height via `clampToInsets`). Drives host-side navigation history
    /// (Go Back/Forward) and cross-launch reading-position restore for an
    /// already-mounted editor. A no-op when no editor is bound.
    public func scroll(toOffset offset: CGFloat) {
        guard let textView = semanticCoordinator?.textView ?? coordinator?.textView,
              let scrollView = textView.enclosingScrollView else { return }
        ScrollTrace.stamp("controllerSeam(scrollToOffset)")
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }
}
