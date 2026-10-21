import AppKit

/// the reference editor's comments in one mounted editor (doc 25): it follows the
/// text's edits into the store, paints the highlights, and hosts the rail,
/// the composer and the cards. The threads themselves live in the host's
/// `MarkdownCommentStore`, so they outlive this controller.
@MainActor
final class MarkdownCommentsController {
    weak var coordinator: NativeTextViewCoordinator?
    weak var scrollView: NSScrollView?
    private(set) var store: MarkdownCommentStore
    let highlights = CommentHighlightView(frame: .zero)
    /// Highlights inside rendered tables, painted over the raster.
    let tableHighlights = CommentHighlightView(frame: .zero)
    var tableHighlightsDark: Bool?
    /// Table layouts by table start, kept until the next edit.
    var tableGeometries: [Int: (generation: Int, range: NSRange, layout: MarkdownTableLayout)] = [:]
    /// Everything painted now, in text view coordinates (hit testing, card tops).
    private(set) var currentPaints: [String: CommentHighlightView.Paint] = [:]
    let rail = CommentRailView(frame: .zero)
    let tooltip = ChromeTooltipView(frame: .zero)
    let hoverTracker = CommentHoverTracker()
    /// The draft composer (in the rail, or floating over the editor's right).
    var composer: CommentComposerView?
    /// The composer floats: no attached thread yet, or a narrow editor.
    var composerFloats = false
    /// the reference editor's width hysteresis; nil until the first measure.
    var isWide: Bool?
    var lastPivot: String?
    /// The menu or picker a card opened.
    var openMenu: NSView?
    /// A thread posted a moment ago whose highlight sweeps in once painted.
    var arriving: String?
    /// The last ⌥⌘M cycle: the caret and the thread it opened.
    var cycle: (location: Int, id: String)?
    /// Comments painted over code blocks at the last refresh.
    var codeBlockComments: [String: NSRange] = [:]
    /// An empty draft's fate waits for the mouse-up of a click in the text.
    var pendingClickAway = false
    /// The threads the caret was last announced in.
    var lastCaretThreads: [String] = []
    /// Threads whose resolve animation is playing.
    var resolving: Set<String> = []
    /// The list panel, in list mode.
    var listPanel: CommentListPanel?
    /// "Resolved (N)" is unfolded in the list.
    var resolvedFoldOpen = false
    /// The docked list's width (240–600).
    var listWidth = CommentListPanel.savedWidth
    /// The narrow layout's icon lane.
    let iconLane = CommentIconLaneView(frame: .zero)
    /// The peek over the text (narrow, or full width): the open cluster's cards.
    var peek: CommentPeekView?
    /// A hovered icon lights every thread of its cluster.
    var litCluster: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?
    private weak var observedStorage: NSTextStorage?
    private var refreshScheduled = false

    init(coordinator: NativeTextViewCoordinator, scrollView: NSScrollView, store: MarkdownCommentStore) {
        self.coordinator = coordinator
        self.scrollView = scrollView
        self.store = store
        install()
    }

    func uninstall() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let trackingArea { scrollView?.removeTrackingArea(trackingArea) }
        highlights.removeFromSuperview()
        tableHighlights.removeFromSuperview()
        rail.removeFromSuperview()
        iconLane.removeFromSuperview()
        peek?.removeFromSuperview()
        listPanel?.removeFromSuperview()
        composer?.removeFromSuperview()
        openMenu?.removeFromSuperview()
        tooltip.cancel()
        tooltip.removeFromSuperview()
        textView?.commentLaneReserve = 0
        store.onDisplayChange = nil
    }

    /// The host swapped documents on this editor: follow the new store.
    func bind(_ next: MarkdownCommentStore) {
        guard next !== store else { return }
        store.onDisplayChange = nil
        store = next
        closeComposer()
        rail.keepCards([])
        connectStore()
    }

    var textView: NativeTextView? { coordinator?.textView as? NativeTextView }

    private func install() {
        guard let main = textView, let scrollView else { return }
        highlights.frame = main.bounds
        highlights.autoresizingMask = [.width, .height]
        main.addSubview(highlights, positioned: .below, relativeTo: nil)
        connectStore()
        observeStorage()
        let center = NotificationCenter.default
        main.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: main, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        })
        scrollView.postsFrameChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsRefresh() }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        })
        // ⌥⇧C hides or shows comments while the keyboard is outside the text (the reference editor's chrome scope).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let number = event.window?.windowNumber else { return event }
            let handled = MainActor.assumeIsolated { self?.handlesHideChord(event, inWindow: number) ?? false }
            return handled ? nil : event
        }
        hoverTracker.onMove = { [weak self] event in self?.pointerMoved(event) }
        hoverTracker.onExit = { [weak self] in self?.pointerLeft() }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: hoverTracker, userInfo: nil)
        scrollView.addTrackingArea(area)
        trackingArea = area
    }

    private func connectStore() {
        store.observeUndoBoundaries(of: textView?.undoManager)
        store.onDisplayChange = { [weak self] in self?.setNeedsRefresh() }
        if let main = textView { store.resolveIfNeeded(in: main.string as NSString) }
        setNeedsRefresh()
        // A link asked for a thread before this editor existed.
        if let id = store.pendingOpenID {
            store.pendingOpenID = nil
            DispatchQueue.main.async { [weak self] in self?.openLinked(id) }
        }
    }

    /// Every character edit moves the anchors, whoever made it (typing, Undo,
    /// a table command, a host reload).
    private func observeStorage() {
        guard let storage = textView?.textStorage, storage !== observedStorage else { return }
        observedStorage = storage
        observers.append(NotificationCenter.default.addObserver(
            // didProcessEditing expands editedRange while fixing paragraph attributes.
            // Map the character edit before that expansion can swallow an anchor.
            forName: NSTextStorage.willProcessEditingNotification, object: storage, queue: nil
        ) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edit = MarkdownTextEdit(editedRange: storage.editedRange, changeInLength: storage.changeInLength)
            let text = storage.mutableString
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.textDidChange(edit, text: text)
                // Typing in the document closes a peek (unless a reply is being written).
                if self.peek != nil, !self.isEditorDirty { self.collapse(announce: false) }
            }
        })
    }

    // MARK: - Refresh

    /// Repaint and re-stack on the next run-loop turn (once per turn).
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    /// TextKit laid out or drew text: anchors may have moved.
    func layoutDidChange() { setNeedsRefresh() }

    func refresh() {
        guard let main = textView else { return }
        if main.subviews.first !== highlights { main.addSubview(highlights, positioned: .below, relativeTo: nil) }
        let paints = paints(in: main)
        currentPaints = paints
        highlights.apply(paints.filter { !$0.value.overTable }, animated: true)
        // Table interiors paint over the raster, in the document's coordinates.
        let overTable = paints.filter(\.value.overTable)
        if let container = main.superview, !overTable.isEmpty || !tableHighlights.paints.isEmpty {
            placeTableHighlights(in: container, main: main)
            let origin = main.frame.origin
            tableHighlights.apply(overTable.mapValues { paint in
                var moved = paint
                moved.rects = paint.rects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                return moved
            }, animated: true)
        }
        redrawCodeBlocksUnderComments()
        if let id = arriving, highlights.paints[id] != nil {
            arriving = nil
            highlights.playArrival(of: id)
        }
        refreshRail(paints: paints)
        refreshPeek(paints: paints)
        refreshList()
    }

    /// The card showing `id`, in the rail or the list.
    func cardView(for id: String) -> CommentCardView? {
        rail.cards[id] ?? listPanel?.cards[id] ?? peek?.cards.first { $0.threadID == id }
    }

    /// Scrolling moves the cards with the text; ones whose anchors come into
    /// view are placed when TextKit draws them.
    private func scrolled() {
        if composerFloats { placeFloatingComposer() }
        if openMenu != nil, !(openMenu is TableMenuView) { closeMenu() }
    }

    // MARK: - Highlights

    /// What each visible thread paints now: the lit one (hovered, else open)
    /// at 45 %, the rest at 20 %, the open one underlined; the draft paints
    /// the selection it will anchor to at rest.
    func paints(in main: NativeTextView) -> [String: CommentHighlightView.Paint] {
        guard store.mode != .hidden, let viewport = main.viewportCharacterRange else { return [:] }
        let lit = store.activeID ?? store.focusID
        let showsResolved = store.mode == .list && (store.filter == .resolved || store.filter == .all)
        var result: [String: CommentHighlightView.Paint] = [:]
        for thread in store.threads where !thread.resolved || showsResolved || resolving.contains(thread.id) {
            guard let range = store.ranges[thread.id],
                  coordinator?.foldLayout.hiddenRange(containing: range.location) == nil else { continue }
            let visible = NSIntersectionRange(range, viewport)
            guard visible.length > 0 else { continue }
            if let rect = imageRect(range, in: main) {
                let selected = coordinator?.objectSelection?.token == range
                let isLit = lit == thread.id || litCluster.contains(thread.id)
                let dark = ChromePalette.isDark(main.effectiveAppearance)
                let rest = dark ? NSColor(calibratedRed: 0.859, green: 0.576, blue: 0, alpha: 1)
                    : NSColor(calibratedRed: 0.718, green: 0.467, blue: 0, alpha: 1)
                let outline: NSColor = selected ? .clear : thread.resolved ? CommentPalette.resolved.withAlphaComponent(isLit ? 0.32 : 0.18)
                    : store.focusID == thread.id ? ImageChromeView.ringColor
                    : isLit ? ImageChromeView.ringColor.withAlphaComponent(0.5) : rest
                result[thread.id] = CommentHighlightView.Paint(rects: [rect], alpha: 0, underlined: false,
                    outline: outline, outlineOffset: 3, cornerRadius: 4, overTable: true)
                continue
            }
            let interior = thread.table ? nil : tableInteriorRects(for: range, cells: thread.cells, in: main)
            let rects = thread.table ? tableRect(range, in: main).map { [$0] } ?? [] : interior ?? segmentRects(for: visible, in: main)
            guard !rects.isEmpty else { continue }
            let isLit = lit == thread.id || litCluster.contains(thread.id)
            if thread.table {
                // A commented table: the outline, accent at 50 % lit and 100 % open.
                let outline = store.focusID == thread.id ? CommentPalette.accent
                    : isLit ? CommentPalette.accent.withAlphaComponent(0.5) : CommentPalette.tableOutline
                result[thread.id] = CommentHighlightView.Paint(rects: rects, alpha: 0, underlined: false, outline: outline)
                continue
            }
            result[thread.id] = CommentHighlightView.Paint(
                rects: rects,
                alpha: thread.resolved && !resolving.contains(thread.id)
                    ? (isLit ? CommentPalette.resolvedActiveAlpha : CommentPalette.resolvedRestAlpha)
                    : (isLit ? CommentPalette.activeAlpha : CommentPalette.restAlpha),
                underlined: store.focusID == thread.id && !thread.resolved && !thread.cells,
                resolved: thread.resolved && !resolving.contains(thread.id),
                overTable: interior != nil
            )
        }
        if let draft = store.draft, draft.range.length > 0 {
            let visible = NSIntersectionRange(draft.range, viewport)
            if let rect = imageRect(draft.range, in: main) {
                let color: NSColor = coordinator?.objectSelection?.token == draft.range ? .clear
                    : NSColor(calibratedRed: 0.651, green: 0.416, blue: 0, alpha: 1)
                result[Self.draftID] = CommentHighlightView.Paint(rects: [rect], alpha: 0, underlined: false,
                    outline: color, outlineOffset: 3, cornerRadius: 4, overTable: true)
            } else if draft.table, let rect = tableRect(draft.range, in: main) {
                result[Self.draftID] = CommentHighlightView.Paint(rects: [rect], alpha: 0, underlined: false, outline: CommentPalette.composingTarget)
            } else if let interior = tableInteriorRects(for: draft.range, cells: draft.cells, in: main) {
                result[Self.draftID] = CommentHighlightView.Paint(rects: interior, alpha: CommentPalette.restAlpha, underlined: false,
                                                                  overTable: true)
            } else if visible.length > 0 {
                result[Self.draftID] = CommentHighlightView.Paint(rects: segmentRects(for: visible, in: main),
                                                                  alpha: CommentPalette.restAlpha, underlined: false)
            }
        }
        return result
    }

    static let draftID = "__draft"

    /// The text ranges painted gold now (filled, not outlined), for a code
    /// block's fill to leave showing.
    func paintedRanges(intersecting range: NSRange) -> [NSRange] {
        highlights.paints.compactMap { id, paint -> NSRange? in
            guard paint.outline == nil else { return nil }
            let painted = id == Self.draftID ? store.draft?.range : store.ranges[id]
            return painted.flatMap { NSIntersectionRange($0, range).length > 0 ? $0 : nil }
        }
    }

    /// A code block draws its own fill: when the comments over one change,
    /// it draws again so the fill's holes follow.
    func redrawCodeBlocksUnderComments() {
        guard let main = textView, let coordinator, let tlm = main.textLayoutManager, let content = tlm.textContentManager,
              let parsed = coordinator.parsedDocumentIfCached(for: main.string) else { return }
        let blocks = parsed.codeTokens.filter { $0.kind == .codeBlock }.map(\.range)
        guard !blocks.isEmpty || !codeBlockComments.isEmpty else { return }
        var current: [String: NSRange] = [:]
        for id in highlights.paints.keys {
            guard let range = id == Self.draftID ? store.draft?.range : store.ranges[id],
                  blocks.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            current[id] = range
        }
        guard current != codeBlockComments else { return }
        let touched = Set(current.values).union(codeBlockComments.values)
        codeBlockComments = current
        for block in blocks where touched.contains(where: { NSIntersectionRange($0, block).length > 0 }) {
            guard let start = content.location(content.documentRange.location, offsetBy: block.location),
                  let end = content.location(start, offsetBy: block.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            tlm.invalidateRenderingAttributes(for: textRange)
        }
        main.needsDisplay = true
    }

    /// An ordinary thread whose exact range is a rendered image token.
    func imageRect(_ range: NSRange, in main: NativeTextView) -> NSRect? {
        guard let storage = main.textStorage,
              let image = NativeTextViewCoordinator.renderedImage(around: range, in: storage), image.token == range else { return nil }
        return main.renderedImageRect(at: image.anchor)
    }

    /// A rendered table's rect in the text view, for `range` starting at the table.
    func tableRect(_ range: NSRange, in main: NativeTextView) -> NSRect? {
        guard let canvas = main.tableCanvas(forTableAt: range),
              let geometry = coordinator?.tableEditingSession.geometry(forTableAt: range) else { return nil }
        var rect = main.convertTableRect(NSRect(origin: .zero, size: geometry.size), canvas: canvas)
        // A wide table shows only its scroller's span.
        if canvas.view !== main, let overlay = canvas.view.enclosingScrollView {
            rect = rect.intersection(overlay.contentView.convert(overlay.contentView.bounds, to: main))
        }
        return rect.isEmpty ? nil : rect
    }

    /// The text segments of `range` in the text view, one rect per line run
    /// (touching runs on a line merged so overlaps never seam).
    func segmentRects(for range: NSRange, in main: NativeTextView) -> [NSRect] {
        guard let tlm = main.textLayoutManager, let content = tlm.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        let origin = main.textContainerOrigin
        var rects: [NSRect] = []
        tlm.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
            if frame.width >= 0.5, frame.height > 0 { rects.append(frame.offsetBy(dx: origin.x, dy: origin.y)) }
            return true
        }
        rects.sort { abs($0.minY - $1.minY) > 0.5 ? $0.minY < $1.minY : $0.minX < $1.minX }
        var merged: [NSRect] = []
        for rect in rects {
            if let last = merged.last, abs(last.minY - rect.minY) < 0.5, abs(last.height - rect.height) < 0.5,
               rect.minX <= last.maxX + 0.5 {
                merged[merged.count - 1] = last.union(rect)
            } else {
                merged.append(rect)
            }
        }
        // Rounded to whole points, never outward, so stacked lines do not overlap.
        return merged.map { rect in
            NSRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.maxX.rounded() - rect.minX.rounded(),
                   height: rect.maxY.rounded() - rect.minY.rounded())
        }
    }

    /// The threads painted under `point` (text view coordinates), innermost first.
    func threads(at point: NSPoint) -> [String] {
        currentPaints.filter { id, paint in
            id != Self.draftID && paint.rects.contains { $0.contains(point) }
        }.map(\.key).sorted { lhs, rhs in
            let left = store.ranges[lhs]?.length ?? .max, right = store.ranges[rhs]?.length ?? .max
            return left != right ? left < right : lhs < rhs
        }
    }

    // MARK: - Pointer

    /// Hovering a highlight lights it (and raises its card).
    private func pointerMoved(_ event: NSEvent) {
        guard let main = textView else { return }
        let point = main.convert(event.locationInWindow, from: nil)
        let hovered = main.visibleRect.contains(point) ? threads(at: point).first : nil
        setActive(hovered, fromCard: false)
    }

    private func pointerLeft() { setActive(nil, fromCard: false) }

    private var cardHover: String?

    func setActive(_ id: String?, fromCard: Bool) {
        if fromCard { cardHover = id }
        let next = fromCard ? id : (id ?? cardHover)
        guard next != store.activeID else { return }
        store.activeID = next
        refresh()
    }

    /// A click in the text: on a highlight it opens that thread's card
    /// (again on the same spot cycles to the next one under it); elsewhere it
    /// closes the open card. An empty draft waits for the mouse-up (the reference
    /// editor's click-away): a drag that selects new text moves the draft there,
    /// a plain click drops it; a draft with text in it stays.
    func documentMouseDown(_ event: NSEvent) {
        guard let main = textView else { return }
        closeMenu()
        let point = main.convert(event.locationInWindow, from: nil)
        let stack = threads(at: point)
        pendingClickAway = false
        if let draft = store.draft, draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, stack.isEmpty {
            pendingClickAway = true
        }
        guard !stack.isEmpty else {
            if !isEditorDirty { collapse(announce: false) }
            return
        }
        guard !isEditorDirty else { return refuseWhileWriting() }
        let next: String
        if let focus = store.focusID, let index = stack.firstIndex(of: focus) {
            next = stack[(index + 1) % stack.count]
        } else {
            next = stack[0]
        }
        open(next, focusCard: false)
    }

    // MARK: - The caret in commented text (doc 25 §7.2)

    /// When the chord hint was last spoken (at most once every 2 minutes).
    private static var lastChordHint: TimeInterval = -.infinity

    /// A keyboard caret move into commented text says so.
    func selectionDidChange() {
        guard store.mode != .hidden, let main = textView, NSApp.currentEvent?.type == .keyDown else { return }
        let selection = main.selectedRange()
        guard selection.length == 0 else { return }
        let under = store.threads(at: selection.location).filter { range in
            // Strictly inside: a caret at the edge is beside the text, not in it.
            guard let anchor = store.ranges[range.id] else { return false }
            return selection.location > anchor.location && selection.location < NSMaxRange(anchor)
        }
        guard !under.isEmpty, under.map(\.id) != lastCaretThreads else {
            if under.isEmpty { lastCaretThreads = [] }
            return
        }
        lastCaretThreads = under.map(\.id)
        let now = ProcessInfo.processInfo.systemUptime
        let hint = now - Self.lastChordHint >= 120
        if hint { Self.lastChordHint = now }
        if under.count == 1 {
            announce(hint ? "Commented text, press \u{2325}\u{2318}M to open the comment" : "Commented text")
        } else {
            announce(hint ? "Text with \(under.count) comments, press \u{2325}\u{2318}M to open the first" : "Text with \(under.count) comments")
        }
    }

    // MARK: - ⌥⇧C

    /// ⌥⇧C (as bound) in this editor's window with the keyboard outside any
    /// text (a card, the list, the rail, chrome): comments hide, or show
    /// again. In text it stays a character (Ç); a chord with ⌘ or ⌃ works
    /// there too.
    func handlesHideChord(_ event: NSEvent, inWindow number: Int) -> Bool {
        guard let chords = coordinator?.keyBindings[.toggleComments],
              let chord = chords.first(where: { $0.matches(event) }),
              let window = scrollView?.window, window.windowNumber == number,
              chord.command || chord.control || !(window.firstResponder is NSTextView) else { return false }
        // Only the editor this window shows (a hidden warm tab keeps its own mode).
        guard let scrollView, !scrollView.isHiddenOrHasHiddenAncestor else { return false }
        setMode(store.mode == .hidden ? .margin : .hidden)
        return true
    }

    /// The click that began over the text is over (the selection is final).
    func documentMouseUp() {
        guard pendingClickAway else { return }
        pendingClickAway = false
        guard let draft = store.draft, draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let target = commentTarget, target.range != draft.range {
            reanchorDraft(to: target)
        } else {
            discardDraft(restoreFocus: false)
        }
    }

    /// A click a table or a checkbox took: the draft stays.
    func documentClickHandledElsewhere() { pendingClickAway = false }

    // MARK: - Announcements

    func announce(_ text: String) {
        let element: Any = textView ?? NSApp as Any
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
