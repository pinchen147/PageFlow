import AppKit

/// What the cards do (doc 25 §5–§6): open, reply, react, resolve, edit and
/// delete, each written to the store (and so to the sidecar) at once.
extension MarkdownCommentsController: CommentCardDelegate {

    func isCommentChord(_ event: NSEvent) -> Bool {
        coordinator?.keyBindings[.comment].contains { $0.matches(event) } == true
    }

    func cardClicked(_ card: CommentCardView) {
        closeMenu()
        guard store.focusID != card.threadID else { return }
        guard !isEditorDirty else { return refuseWhileWriting() }
        open(card.threadID, focusCard: false)
    }

    func cardHovered(_ card: CommentCardView, inside: Bool) {
        setActive(inside ? card.threadID : nil, fromCard: true)
    }

    func cardNeedsLayout(_ card: CommentCardView) { setNeedsRefresh() }

    /// The cards in visual order (top, then left), where the keyboard moves.
    private var keyboardCards: [CommentCardView] {
        let cards: [CommentCardView]
        if store.mode == .list, let listPanel { cards = Array(listPanel.cards.values) } else if let peek { cards = peek.cards } else {
            cards = Array(rail.cards.values)
        }
        return cards.filter { $0.window != nil }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: nil), right = rhs.convert(rhs.bounds, to: nil)
            return abs(left.maxY - right.maxY) > 0.5 ? left.maxY > right.maxY : left.minX < right.minX
        }
    }

    func card(_ card: CommentCardView, move: CommentCardView.Move) {
        let cards = keyboardCards
        guard let index = cards.firstIndex(where: { $0 === card }) else { return }
        let target: Int
        switch move {
        case .next: target = min(cards.count - 1, index + 1)
        case .previous: target = max(0, index - 1)
        case .first: target = 0
        case .last: target = cards.count - 1
        }
        guard target != index else { return }
        let next = cards[target]
        next.window?.makeFirstResponder(next)
        if store.mode == .margin, peek == nil { revealCard(next) }
    }

    func cardEscape(_ card: CommentCardView) {
        if card.isExpanded {
            collapse(announce: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, let again = self.cardView(for: card.threadID) else { return }
                again.window?.makeFirstResponder(again)
            }
        } else if let range = store.ranges[card.threadID] {
            returnToText(caret: NSMaxRange(range))
        } else if let main = textView {
            main.window?.makeFirstResponder(main)
        }
    }

    func cardFocusChanged(_ card: CommentCardView, focused: Bool) {
        setActive(focused ? card.threadID : nil, fromCard: true)
    }

    func card(_ card: CommentCardView, reply text: String) {
        store.replyDrafts[card.threadID] = nil
        store.update(card.threadID) { $0.replies.append(MarkdownComment(body: text)) }
        announce("Reply posted")
        DispatchQueue.main.async { [weak self] in self?.cardView(for: card.threadID)?.focusReply() }
    }

    func card(_ card: CommentCardView, replyDraftChanged text: String) {
        store.replyDrafts[card.threadID] = text.isEmpty ? nil : text
    }

    /// A pill toggles my reaction. On a reaction-only thread the root's
    /// emoji removes the whole thread ("Remove reaction").
    func card(_ card: CommentCardView, toggle emoji: String, on commentID: String) {
        guard let thread = store.thread(card.threadID) else { return }
        if thread.reactionOnly, commentID == thread.root.id, thread.root.body == emoji, thread.replies.isEmpty {
            store.remove(thread.id)
            return announce("Reaction removed")
        }
        store.update(card.threadID) { thread in
            func toggle(_ comment: inout MarkdownComment) {
                if let index = comment.reactions.firstIndex(of: emoji) { comment.reactions.remove(at: index) } else {
                    comment.reactions.append(emoji)
                }
            }
            if thread.root.id == commentID { toggle(&thread.root) }
            for index in thread.replies.indices where thread.replies[index].id == commentID { toggle(&thread.replies[index]) }
        }
    }

    /// Add reaction: the eight emoji in a popover above the button, right-aligned.
    func card(_ card: CommentCardView, pickReactionFor commentID: String, from button: CommentButton) {
        pickReaction(from: button) { [weak self] emoji in
            guard let self else { return }
            self.store.update(card.threadID) { thread in
                if thread.root.id == commentID, !thread.root.reactions.contains(emoji) { thread.root.reactions.append(emoji) }
                for index in thread.replies.indices where thread.replies[index].id == commentID
                    && !thread.replies[index].reactions.contains(emoji) {
                    thread.replies[index].reactions.append(emoji)
                }
            }
            self.announce("Reacted with \(emoji)")
        }
    }

    /// The eight emoji in a popover above `button`, right-aligned, 4 apart from it.
    func pickReaction(from button: NSView, onPick: @escaping (String) -> Void) {
        closeMenu()
        guard let scrollView else { return }
        let picker = CommentEmojiPicker(popover: true)
        picker.onPick = { [weak self] emoji in
            self?.closeMenu()
            onPick(emoji)
        }
        picker.onClose = { [weak self] in self?.closeMenu() }
        let anchor = button.convert(button.bounds, to: scrollView)
        let size = picker.intrinsicContentSize
        let topDown = scrollView.isFlipped ? anchor : NSRect(x: anchor.minX, y: scrollView.bounds.height - anchor.maxY,
                                                             width: anchor.width, height: anchor.height)
        var y = topDown.minY - 4 - size.height
        if y < scrollView.contentInsets.top + 4 { y = topDown.maxY + 4 }
        let x = max(8, min(topDown.maxX - size.width, scrollView.bounds.width - size.width - 8))
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        picker.frame = scrollView.isFlipped ? frame : NSRect(x: x, y: scrollView.bounds.height - frame.maxY, width: size.width, height: size.height)
        scrollView.addSubview(picker, positioned: .above, relativeTo: nil)
        picker.closesOnOutsideClick()
        openMenu = picker
    }

    /// More actions: Edit, Reopen (a resolved root), then Delete comment.
    func card(_ card: CommentCardView, moreFor commentID: String, from button: CommentButton) {
        closeMenu()
        guard let scrollView, let thread = store.thread(card.threadID) else { return }
        typealias Item = TableMenuView.Item
        var items: [Item] = []
        if let base = MainActor.assumeIsolated({ coordinator?.editorController?.commentLinkBase }) {
            items.append(Item("Copy link", symbol: "link") { [weak self] in self?.copyLink(base: base, threadID: card.threadID) })
        }
        if !thread.resolved, !(thread.reactionOnly && commentID == thread.root.id) {
            items.append(Item("Edit", symbol: "pencil") { [weak self] in
                guard let self, let comment = self.store.thread(card.threadID)?.comments.first(where: { $0.id == commentID }) else { return }
                self.store.editing = (commentID, comment.body)
                self.open(card.threadID, focusCard: false)
                self.cardView(for: card.threadID)?.editing = self.store.editing
                self.setNeedsRefresh()
            })
        }
        if thread.resolved, commentID == thread.root.id {
            items.append(Item("Reopen", symbol: "arrow.uturn.backward") { [weak self] in
                self?.store.update(card.threadID) { $0.resolved = false }
                self?.announce("Comment reopened")
            })
        }
        if !items.isEmpty { items.append(.separator) }
        items.append(Item("Delete comment", symbol: "trash", isDanger: true) { [weak self] in
            guard let self else { return }
            let target = self.cardView(for: card.threadID) ?? card
            target.pendingDelete = commentID
            self.setNeedsRefresh()
            DispatchQueue.main.async { target.focusDeleteCancel() }
        })
        let rect = button.convert(button.bounds, to: scrollView)
        let anchor = scrollView.isFlipped ? rect : NSRect(x: rect.minX, y: scrollView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        let menu = TableMenuView.present(items, family: .object, label: "Comment actions", minimumWidth: 160,
                                         placement: .below(anchor, rightAligned: true), in: scrollView, fromKeyboard: false,
                                         returningFocusTo: textView) { [weak self] _ in
            self?.openMenu = nil
        }
        openMenu = menu
    }

    /// Resolve: the check draws in, the card flips away and the highlight
    /// wipes out; then the thread is resolved ("Comment resolved").
    func cardResolve(_ card: CommentCardView) {
        let id = card.threadID
        guard !resolving.contains(id) else { return }
        resolving.insert(id)
        let finish = { [weak self] in
            guard let self else { return }
            self.resolving.remove(id)
            if self.store.focusID == id { self.store.focusID = nil }
            self.store.update(id) { $0.resolved = true }
            self.announce("Comment resolved")
        }
        highlights.playResolve(of: id) {}
        if CommentPalette.skipsMotion { return finish() }
        guard !CommentPalette.reducesMotion, let layer = card.layer else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                card.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
            return
        }
        // The check (240 ms), a short fade (42 ms), the flip to the right (156 ms).
        var flip = CATransform3DIdentity
        flip.m34 = -1 / 900
        flip = CATransform3DTranslate(flip, card.bounds.width * 1.3, 0, 0)
        flip = CATransform3DRotate(flip, -28 * .pi / 180, 0, 1, 0)
        let start = CACurrentMediaTime() + 0.24
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = start
        fade.duration = 0.042 + 0.156
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        let away = CABasicAnimation(keyPath: "transform")
        away.fromValue = CATransform3DIdentity
        away.toValue = flip
        away.beginTime = start + 0.042
        away.duration = 0.156
        away.timingFunction = CommentPalette.exit
        away.fillMode = .both
        away.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        layer.add(fade, forKey: "resolve-fade")
        layer.add(away, forKey: "resolve-flip")
        CATransaction.commit()
    }

    func card(_ card: CommentCardView, saveEdit text: String, of commentID: String) {
        store.editing = nil
        card.editing = nil
        store.update(card.threadID) { thread in
            if thread.root.id == commentID { thread.root.body = text; thread.root.edited = true }
            for index in thread.replies.indices where thread.replies[index].id == commentID {
                thread.replies[index].body = text
                thread.replies[index].edited = true
            }
        }
    }

    func cardCancelEdit(_ card: CommentCardView) {
        store.editing = nil
        card.editing = nil
        setNeedsRefresh()
    }

    /// Deleting the root deletes the thread; a reply goes alone.
    func card(_ card: CommentCardView, confirmDelete commentID: String) {
        guard let thread = store.thread(card.threadID) else { return }
        card.pendingDelete = nil
        if thread.root.id == commentID {
            store.remove(thread.id)
            rail.removeCard(thread.id)
        } else {
            store.update(thread.id) { $0.replies.removeAll { $0.id == commentID } }
        }
        announce("Comment deleted")
        if let main = textView { main.window?.makeFirstResponder(main) }
    }

    func cardCancelDelete(_ card: CommentCardView) {
        card.pendingDelete = nil
        setNeedsRefresh()
    }

    func card(_ card: CommentCardView, tooltip button: CommentButton, inside: Bool) {
        guard let scrollView else { return }
        if inside { tooltip.schedule(button.tooltip, for: button, in: scrollView) } else { tooltip.cancel() }
    }

    /// Copy link: the note's address with `#thread-‹id›`, and a "Link copied" toast.
    func copyLink(base: URL, threadID: String, pasteboard: NSPasteboard = .general) {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = "thread-\(threadID)"
        guard let link = components?.url?.absoluteString else { return }
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        if let toast = coordinator?.editorController?.onCommentsToast { toast("Link copied") } else { announce("Link copied") }
    }

    func closeMenu() {
        tooltip.cancel()
        if let menu = openMenu as? TableMenuView { menu.close(.dismissed) } else { openMenu?.removeFromSuperview() }
        openMenu = nil
    }
}
