import AppKit

/// The comments modes and the list (doc 25 §5.6): margin cards, the list
/// panel (with the resolved and detached threads), or nothing at all.
extension MarkdownCommentsController {

    /// Switches mode: hidden drops the composer and the open card and paints
    /// nothing; the list and the margin keep them.
    func setMode(_ mode: MarkdownCommentsMode) {
        guard mode != store.mode else { return }
        closeMenu()
        let wasHidden = store.mode == .hidden
        if mode == .hidden {
            closeComposer()
            store.focusID = nil
        }
        store.mode = mode
        refresh()
        if mode == .hidden { announce("Comments hidden") } else if wasHidden { announce("Comments shown") }
    }

    /// The filter the list uses now: Open while open threads exist, else All.
    var listFilter: MarkdownCommentStore.Filter {
        store.filter ?? (store.threads.contains { !$0.resolved } ? .open : .all)
    }

    /// Open threads first, then document order, then creation; detached
    /// threads after the attached ones of their group.
    func orderedForList(_ threads: [MarkdownCommentThread]) -> [MarkdownCommentThread] {
        threads.sorted { lhs, rhs in
            if lhs.resolved != rhs.resolved { return !lhs.resolved }
            let left = store.ranges[lhs.id]?.location ?? .max, right = store.ranges[rhs.id]?.location ?? .max
            return left != right ? left < right : lhs.root.createdAt < rhs.root.createdAt
        }
    }

    func refreshList() {
        guard store.mode == .list, let scrollView, let main = textView else {
            listPanel?.removeFromSuperview()
            listPanel = nil
            return
        }
        let panel = listPanel ?? makeListPanel()
        if panel.superview !== scrollView { scrollView.addSubview(panel, positioned: .above, relativeTo: nil) }
        // Docked beside a wide editor; a popover over a narrow one.
        let top = scrollView.contentInsets.top
        let wide = isWide == true
        panel.isPopover = !wide
        let topDown: NSRect
        if wide {
            topDown = NSRect(x: scrollView.bounds.width - listWidth, y: top, width: listWidth, height: scrollView.bounds.height - top)
        } else {
            let height = min(scrollView.bounds.height * 0.7, scrollView.bounds.height - top - 16)
            topDown = NSRect(x: scrollView.bounds.width - 8 - CommentListPanel.popoverWidth, y: top + 8,
                             width: CommentListPanel.popoverWidth, height: height)
        }
        let frame = scrollView.isFlipped ? topDown
            : NSRect(x: topDown.minX, y: scrollView.bounds.height - topDown.maxY, width: topDown.width, height: topDown.height)
        if panel.frame != frame { panel.frame = frame }

        let filter = listFilter
        let ordered = orderedForList(store.threads)
        func row(_ thread: MarkdownCommentThread) -> CommentListPanel.Row {
            let range = store.ranges[thread.id]
            let quote = range.map { (main.string as NSString).substring(with: $0) } ?? thread.anchor.exact
            return CommentListPanel.Row(thread: thread, quote: Self.displayQuote(quote), detached: range == nil)
        }
        let open = ordered.filter { !$0.resolved }.map(row)
        let resolved = ordered.filter(\.resolved).map(row)
        let rows: [CommentListPanel.Row]
        var folded: [CommentListPanel.Row] = []
        switch filter {
        case .open: rows = open
        case .resolved: rows = resolved
        case .all:
            rows = open
            folded = resolved
        }
        let openCount = store.threads.filter { !$0.resolved }.count
        panel.count.stringValue = openCount > 0 ? "\(openCount)" : ""
        panel.show(rows, resolvedFolded: folded, foldOpen: resolvedFoldOpen, focusID: store.focusID, delegate: self,
                   emptyText: rows.isEmpty && folded.isEmpty ? "No comments" : nil)
        for card in panel.cards.values {
            card.isLit = store.activeID == card.threadID || store.focusID == card.threadID
            configureEditing(card)
        }
    }

    private func configureEditing(_ card: CommentCardView) {
        card.editing = store.editing.flatMap { editing in
            store.thread(card.threadID)?.comments.contains { $0.id == editing.commentID } == true ? editing : nil
        }
    }

    private func makeListPanel() -> CommentListPanel {
        let panel = CommentListPanel(frame: .zero)
        panel.filterButton.onPress = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.showFilterMenu(from: panel.filterButton)
        }
        panel.moreButton.onPress = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.showListMoreMenu(from: panel.moreButton)
        }
        panel.closeButton.onPress = { [weak self] in self?.setMode(.margin) }
        panel.resizeHandle.currentWidth = { [weak self] in self?.listWidth ?? CommentListPanel.width }
        panel.resizeHandle.onResize = { [weak self] width, done in
            guard let self else { return }
            self.listWidth = width
            if done { CommentListPanel.savedWidth = width }
            self.refresh()
        }
        panel.onToggleFold = { [weak self] in
            guard let self else { return }
            self.resolvedFoldOpen.toggle()
            self.refresh()
        }
        for button in [panel.filterButton, panel.moreButton, panel.closeButton] {
            button.onHover = { [weak self] button, inside in
                guard let self, let scrollView = self.scrollView else { return }
                if inside { self.tooltip.schedule(button.tooltip, for: button, in: scrollView) } else { self.tooltip.cancel() }
            }
        }
        listPanel = panel
        return panel
    }

    /// Filter: Open, Resolved or All, as radio rows; the count is announced.
    private func showFilterMenu(from button: CommentButton) {
        closeMenu()
        guard let scrollView else { return }
        let current = listFilter
        typealias Item = TableMenuView.Item
        let choices: [(String, MarkdownCommentStore.Filter)] = [("Open", .open), ("Resolved", .resolved), ("All", .all)]
        let items = choices.map { title, filter in
            Item(title, symbol: nil, checked: current == filter) { [weak self] in
                guard let self else { return }
                self.store.filter = filter
                self.refresh()
                self.announceFilter(filter)
            }
        }
        presentMenu(items, label: "Filter comments", from: button, in: scrollView)
    }

    private func announceFilter(_ filter: MarkdownCommentStore.Filter) {
        let open = store.threads.filter { !$0.resolved }.count
        let resolved = store.threads.count - open
        func phrase(_ count: Int, _ kind: String) -> String {
            count == 0 ? "No \(kind) comments" : count == 1 ? "1 \(kind) comment" : "\(count) \(kind) comments"
        }
        switch filter {
        case .open: announce(phrase(open, "open"))
        case .resolved: announce(phrase(resolved, "resolved"))
        case .all: announce(store.threads.isEmpty ? "No comments" : store.threads.count == 1 ? "1 comment" : "\(store.threads.count) comments")
        }
    }

    private func showListMoreMenu(from button: CommentButton) {
        closeMenu()
        guard let scrollView else { return }
        let items = [TableMenuView.Item("Hide comments", symbol: "eye.slash", shortcut: "\u{2325}\u{21E7}C") { [weak self] in
            self?.setMode(.hidden)
        }]
        presentMenu(items, label: "More", from: button, in: scrollView)
    }

    func presentMenu(_ items: [TableMenuView.Item], label: String, from button: NSView, in scrollView: NSScrollView) {
        let rect = button.convert(button.bounds, to: scrollView)
        let anchor = scrollView.isFlipped ? rect
            : NSRect(x: rect.minX, y: scrollView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        openMenu = TableMenuView.present(items, family: .object, label: label, minimumWidth: 160,
                                         placement: .below(anchor, rightAligned: true), in: scrollView, fromKeyboard: false,
                                         returningFocusTo: textView) { [weak self] _ in
            self?.openMenu = nil
        }
    }

    /// A `#thread-‹id›` link: an open, attached thread opens where it is (its
    /// text centred); a resolved or detached one opens in the list.
    func openLinked(_ id: String) {
        guard let thread = store.thread(id) else { return announce("Can't open that comment here") }
        if thread.resolved || store.ranges[id] == nil {
            store.filter = .all
            resolvedFoldOpen = true
            setMode(.list)
        } else if store.mode == .hidden {
            setMode(.margin)
        }
        revealAnchor(of: id)
        refresh()
        open(id, focusCard: false)
    }

    /// A list row opened: the text it is on comes into view, centred.
    func revealAnchor(of id: String) {
        guard let main = textView, let scrollView, let range = store.ranges[id], let line = main.lineFrame(at: range.location) else { return }
        let visible = main.visibleRect
        let target = line.midY - visible.height / 2
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, target)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The quote as the list shows it: one line, Markdown marks dropped.
    static func displayQuote(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\n", with: " ")
        for mark in ["**", "__", "~~", "==", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
