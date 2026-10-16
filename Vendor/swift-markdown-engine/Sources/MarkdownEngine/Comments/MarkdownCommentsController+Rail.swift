import AppKit

/// The rail (doc 25 §4): which cards show, where they stack, and the room
/// the text column leaves for them.
extension MarkdownCommentsController {

    /// Whether the editor is wide enough for the rail, with the reference editor's
    /// hysteresis around the width the column and the lane need (1040 /
    /// 1060 / 1080 for its 672 measure): wide collapses below it, narrow
    /// expands 40 past it, and the first measure splits the difference.
    func measureWidth() -> Bool {
        guard let main = textView, let scrollView else {
            isWide = false
            return false
        }
        // Full-width text measures against the reference editor's 672 pt column.
        let need = (main.configuration.readingWidth ?? 672) + 368
        let width = scrollView.contentView.bounds.width
        let wide: Bool
        switch isWide {
        case nil: wide = width >= need + 20
        case true?: wide = width >= need
        case false?: wide = width > need + 40
        }
        // Frozen while a reply or an edit has text in it.
        if let current = isWide, current != wide, isEditorDirty { return current }
        isWide = wide
        return wide
    }

    /// The rail shows in the margin mode of a wide editor with at least one
    /// open, attached thread.
    var railSeated: Bool {
        store.mode == .margin && isWide == true && !store.seatedThreads.isEmpty
    }

    /// A reply or an edit holds typed text (some actions wait for it).
    var isEditorDirty: Bool {
        store.replyDrafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || (store.editing.map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
            || !(store.draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    func refreshRail(paints: [String: CommentHighlightView.Paint]) {
        guard let main = textView, let container = main.superview else { return }
        _ = measureWidth()
        let seated = railSeated
        // The list docks in the same lane as the rail; a narrow page keeps the icon lane.
        let iconsSeated = iconLaneSeated
        main.commentLaneReserve = store.mode == .list && isWide == true ? listWidth + 20
            : seated ? CommentRailView.keepout : (iconsSeated ? CommentIconLaneView.keepout : 0)
        // Wide tables stop short of the lane (the reference editor's 308 keepout beside the rail).
        main.commentTableKeepout = store.mode == .list && isWide == true ? listWidth
            : seated ? CommentRailView.tableKeepout : (iconsSeated ? CommentIconLaneView.keepout : 0)
        refreshIconLane(paints: paints, seated: iconsSeated)
        guard seated else {
            main.tablesFreedIntoCommentLane = []
            main.commentOverhang = 0
            rail.keepCards([])
            rail.removeFromSuperview()
            if composer != nil, !composerFloats { floatComposer() }
            return
        }
        if rail.superview !== container { container.addSubview(rail, positioned: .above, relativeTo: main) }
        let right = max(0, (container.bounds.width - 1600) / 2)
        let railFrame = NSRect(x: container.bounds.width - right - CommentRailView.width, y: main.frame.minY,
                               width: CommentRailView.width, height: main.frame.height)
        if rail.frame != railFrame { rail.frame = railFrame }
        if composer != nil, composerFloats { seatComposer() }

        // One slot per open thread on screen, plus the draft.
        var slots: [CommentRailLayout.Slot] = []
        var visible: Set<String> = []
        var cards: [String: CommentCardView] = [:]
        for thread in store.seatedThreads {
            guard let top = paints[thread.id]?.rects.first?.minY else { continue }
            let card = rail.card(for: thread, delegate: self)
            configure(card)
            cards[thread.id] = card
            visible.insert(thread.id)
            slots.append(.init(id: thread.id, y: top, height: card.fittingHeight(), created: thread.root.createdAt))
        }
        rail.keepCards(visible)
        if let composer, !composerFloats, let top = paints[Self.draftID]?.rects.first?.minY {
            slots.append(.init(id: Self.draftID, y: top, height: composer.fittingHeight(forWidth: CommentCardView.width),
                               created: .distantFuture))
        }
        let pivot = (composer != nil && !composerFloats) ? Self.draftID : store.focusID
        // The document's own end, without the padding an earlier overhang added.
        let bottom = main.frame.height - main.commentOverhang
        var result = CommentRailLayout.solve(slots, pivot: pivot, bottom: bottom)
        // A stack that would hang 400 past the end goes compact.
        let compact = result.overhang > CommentRailLayout.maximumFloat
        if compact {
            for index in slots.indices where slots[index].id != Self.draftID {
                guard let card = cards[slots[index].id] else { continue }
                card.isCompact = true
                slots[index].height = card.fittingHeight()
            }
            result = CommentRailLayout.solve(slots, pivot: pivot, bottom: bottom)
        } else {
            cards.values.forEach { $0.isCompact = false }
        }
        main.commentOverhang = result.overhang
        let slides = pivot != lastPivot
        lastPivot = pivot
        var spans: [ClosedRange<CGFloat>] = []
        for slot in slots {
            guard let top = result.tops[slot.id] else { continue }
            spans.append(top...(top + slot.height))
            if slot.id == Self.draftID, let composer {
                rail.place(composer, top: top, height: slot.height, animated: false)
            } else if let card = cards[slot.id] {
                rail.place(card, top: top, height: slot.height, animated: slides)
            }
        }
        freeWideTables(clearOf: spans, in: main)
    }

    /// the reference editor's narrow layout: an editor too narrow for the rail keeps a
    /// 64 wide icon lane.
    var iconLaneSeated: Bool {
        store.mode == .margin && isWide == false && !store.seatedThreads.isEmpty
    }

    private func refreshIconLane(paints: [String: CommentHighlightView.Paint], seated: Bool) {
        guard seated, let main = textView, let container = main.superview else {
            iconLane.removeFromSuperview()
            return
        }
        if iconLane.superview !== container { container.addSubview(iconLane, positioned: .above, relativeTo: main) }
        let frame = NSRect(x: container.bounds.width - CommentIconLaneView.width, y: main.frame.minY,
                           width: CommentIconLaneView.width, height: main.frame.height)
        if iconLane.frame != frame { iconLane.frame = frame }
        let anchors = store.seatedThreads.compactMap { thread -> (id: String, top: CGFloat, count: Int)? in
            guard let top = paints[thread.id]?.rects.first?.minY else { return nil }
            return (thread.id, top, 1 + thread.replies.count)
        }
        iconLane.show(CommentIconLaneView.clusters(anchors))
        iconLane.onHover = { [weak self] cluster in
            guard let self else { return }
            self.litCluster = Set(cluster?.ids ?? [])
            self.refresh()
        }
        iconLane.onOpen = { [weak self] cluster in
            guard let self, let first = cluster.ids.first else { return }
            self.open(first, focusCard: false)
        }
    }

    // MARK: - Peek (doc 25 §4.6)

    /// Whether opening a thread peeks (no rail to open it in).
    var opensInPeek: Bool { store.mode == .margin && !railSeated }

    /// The open cluster's cards float beside the text, level with the
    /// anchor (12 above it), kept on screen.
    func refreshPeek(paints: [String: CommentHighlightView.Paint]) {
        guard opensInPeek, let focus = store.focusID, let main = textView, let container = main.superview,
              let anchorTop = paints[focus]?.rects.first?.minY else {
            peek?.removeFromSuperview()
            peek = nil
            return
        }
        // The cluster: threads whose anchors start within 32 of this one's.
        let ids = store.seatedThreads.filter { thread in
            guard let top = paints[thread.id]?.rects.first?.minY else { return false }
            return abs(top - anchorTop) < CommentIconLaneView.clusterJoin
        }.map(\.id)
        if peek?.ids != ids {
            peek?.removeFromSuperview()
            peek = CommentPeekView(ids: ids)
        }
        guard let peek else { return }
        if peek.superview !== container { container.addSubview(peek, positioned: .above, relativeTo: nil) }
        let lane = iconLane.superview != nil ? CommentIconLaneView.width : 16
        let width = min(CommentPeekView.maximumWidth, container.bounds.width - lane - 16)
        peek.show(ids.compactMap(store.thread), focusID: focus, delegate: self, width: width)
        let visible = main.visibleRect
        let top = min(max(anchorTop - 12, visible.minY + 8), max(visible.minY + 8, visible.maxY - 8 - peek.frame.height))
        peek.setFrameOrigin(NSPoint(x: container.bounds.width - lane - width, y: main.frame.minY + top))
    }

    /// the reference editor's table/rail rule (doc 25 §0): a wide table that overflows
    /// the keepout runs into the rail's lane while every card is at least 8
    /// clear of it, and stops short again once a card overlaps it by more than 24.
    private func freeWideTables(clearOf spans: [ClosedRange<CGFloat>], in main: NativeTextView) {
        var freed = main.tablesFreedIntoCommentLane
        let blockedEdge = (main.superview?.bounds.width ?? 0) - main.commentTableKeepout
        for (sourceID, overlay) in main.wideTableOverlays where !overlay.isHidden {
            guard let superview = overlay.superview, let document = overlay.documentView else { continue }
            let frame = superview.convert(overlay.frame, to: main)
            func overlap(_ span: ClosedRange<CGFloat>) -> CGFloat { min(span.upperBound, frame.maxY) - max(span.lowerBound, frame.minY) }
            if freed.contains(sourceID) {
                if spans.contains(where: { overlap($0) > 24 }) { freed.remove(sourceID) }
            } else {
                let overflows = overlay.leftContentInset + document.frame.width > blockedEdge + 0.5
                if overflows, spans.allSatisfy({ overlap($0) <= -8 }) { freed.insert(sourceID) }
            }
        }
        freed.formIntersection(main.wideTableOverlays.keys)
        if freed != main.tablesFreedIntoCommentLane { main.tablesFreedIntoCommentLane = freed }
    }

    /// A card's state from the store.
    func configure(_ card: CommentCardView) {
        let id = card.threadID
        // the reference editor's margin cap: min(456, 55 % of the viewport + 16).
        if let height = scrollView?.contentView.bounds.height { card.heightCap = min(456, height * 0.55 + 16) }
        card.isExpanded = store.focusID == id
        card.isLit = store.activeID == id || store.focusID == id
        card.editing = store.editing.flatMap { editing in
            store.thread(id)?.comments.contains { $0.id == editing.commentID } == true ? editing : nil
        }
        if card.replyDraft.isEmpty, let draft = store.replyDrafts[id] { card.replyDraft = draft }
    }

    // MARK: - Opening and closing cards

    /// Opens a thread's card: lit and underlined, actions pinned, the Reply
    /// box shown; the document scrolls so the card and 48 below it show.
    func open(_ id: String, focusCard: Bool) {
        guard store.thread(id) != nil else { return }
        store.focusID = id
        refresh()
        announce("Comment expanded")
        if store.mode == .list { revealAnchor(of: id) }
        guard let card = cardView(for: id) else { return }
        if store.mode == .margin { revealCard(card) }
        if focusCard { card.window?.makeFirstResponder(card) }
    }

    /// Collapses the open card (Escape, a click elsewhere).
    func collapse(announce: Bool) {
        guard store.focusID != nil else { return }
        store.focusID = nil
        litCluster = []
        refresh()
        if announce { self.announce("Comment collapsed") }
    }

    /// Scrolls the least that shows `card` and 48 pt under it.
    func revealCard(_ card: NSView) {
        guard let main = textView, let scrollView else { return }
        let frame = card.convert(card.bounds, to: main)
        let visible = main.visibleRect
        let top = visible.minY + scrollView.contentInsets.top + 16
        let bottom = visible.maxY - 48
        var delta: CGFloat = 0
        if frame.maxY > bottom { delta = frame.maxY - bottom }
        if frame.minY - delta < top { delta = frame.minY - top }
        guard abs(delta) > 0.5 else { return }
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    /// "Finish or cancel what you're writing first": a pulse on the draft.
    func refuseWhileWriting() {
        announce("Finish or cancel what you're writing first")
        guard let layer = composer?.layer, !CommentPalette.reducesMotion else { return }
        let pulse = CABasicAnimation(keyPath: "borderWidth")
        pulse.fromValue = 3
        pulse.toValue = 0
        pulse.duration = 0.6
        pulse.timingFunction = CommentPalette.easeOut
        let color = CABasicAnimation(keyPath: "borderColor")
        color.fromValue = CommentPalette.accent.cgColor
        color.toValue = CommentPalette.accent.withAlphaComponent(0).cgColor
        color.duration = 0.6
        layer.add(pulse, forKey: "refuse")
        layer.add(color, forKey: "refuse-color")
    }
}
