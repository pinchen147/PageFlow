import AppKit

/// What a card asks of the comments controller.
@MainActor
protocol CommentCardDelegate: AnyObject {
    func cardClicked(_ card: CommentCardView)
    func cardHovered(_ card: CommentCardView, inside: Bool)
    func cardNeedsLayout(_ card: CommentCardView)
    func card(_ card: CommentCardView, reply text: String)
    func card(_ card: CommentCardView, replyDraftChanged text: String)
    func card(_ card: CommentCardView, toggle emoji: String, on commentID: String)
    func card(_ card: CommentCardView, pickReactionFor commentID: String, from button: CommentButton)
    func card(_ card: CommentCardView, moreFor commentID: String, from button: CommentButton)
    func cardResolve(_ card: CommentCardView)
    func card(_ card: CommentCardView, move: CommentCardView.Move)
    func cardEscape(_ card: CommentCardView)
    func cardFocusChanged(_ card: CommentCardView, focused: Bool)
    func announce(_ text: String)
    func card(_ card: CommentCardView, saveEdit text: String, of commentID: String)
    func cardCancelEdit(_ card: CommentCardView)
    func card(_ card: CommentCardView, confirmDelete commentID: String)
    func cardCancelDelete(_ card: CommentCardView)
    func card(_ card: CommentCardView, tooltip button: CommentButton, inside: Bool)
    /// Whether `event` is the comment command's chord.
    func isCommentChord(_ event: NSEvent) -> Bool
}

/// One thread in the rail or the list (doc 25 §4.2, §5): a card of radius
/// 10 and padding 12 holding the root and its replies, each a time line,
/// a 13/19 pt body and reaction pills; expanded, it pins its actions and
/// shows the Reply box. No author line: PageFlow has one user.
final class CommentCardView: CommentSurfaceView {
    weak var delegate: CommentCardDelegate?
    private(set) var thread: MarkdownCommentThread
    let threadID: String

    /// Open: actions pinned, every reply, the Reply box.
    var isExpanded = false { didSet { if isExpanded != oldValue { rebuild() } } }
    /// Crowded rail: bodies cut to 3 lines, replies hidden.
    var isCompact = false { didSet { if isCompact != oldValue { rebuild() } } }
    /// In the list: the quote shows above the thread.
    var quote: (text: String, detached: Bool)? { didSet { rebuild() } }
    var isLit = false { didSet { isRaised = isLit || isExpanded } }
    override var isFlat: Bool { didSet { if isFlat != oldValue { needsLayout = true } } }
    var editing: (commentID: String, text: String)? { didSet { if editing?.commentID != oldValue?.commentID { rebuild() } } }
    var pendingDelete: String? { didSet { if pendingDelete != oldValue { rebuild() } } }
    var replyDraft = ""
    /// "Show N replies" was pressed.
    private var unfolded = false
    private var expandedBodies: Set<String> = []
    private var isHovered = false { didSet { if isHovered != oldValue { updateActions() } } }

    private(set) var replyField: CommentFieldView?
    private(set) var editField: CommentFieldView?
    private var replySend: CommentButton?
    private var entries: [Entry] = []
    private var quoteLabel: NSTextField?
    private var quoteRule: NSView?
    private var foldButton: CommentTextButton?
    private var editParts: (box: ReplyBox, cancel: CommentTextButton, save: CommentTextButton)?
    private var deleteParts: (rule: NSView, prompt: NSTextField, cancel: CommentTextButton, delete: CommentTextButton)?
    private var deleteShownAt: TimeInterval = 0
    /// The pills shown last build ("comment|emoji"): a new one pops in.
    private var shownPills: Set<String>?
    private var pillsBuilt: Set<String> = []

    static let width: CGFloat = 260
    static let padding: CGFloat = 12

    /// The card's tallest (the reference editor: `min(456, 55vh + 16)` in the margin);
    /// past it the thread scrolls inside. Nil: as tall as it needs.
    var heightCap: CGFloat? { didSet { if heightCap != oldValue { needsLayout = true } } }
    private let scroller = CardScrollView()
    private let content = CardContentView()
    private let seeMore = CommentTextButton("\u{2193} See more", style: .secondary)
    /// List rows pad 16 at the sides.
    private var sidePadding: CGFloat { isFlat ? 16 : Self.padding }

    /// One comment's views.
    private struct Entry {
        let id: String
        let time: NSTextField
        let actions: [CommentButton]
        let body: NSTextField?
        let fade: CAGradientLayer?
        let more: CommentTextButton?
        let pills: [CommentReactionPill]
    }

    init(thread: MarkdownCommentThread) {
        self.thread = thread
        threadID = thread.id
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 56))
        scroller.documentView = content
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.borderType = .noBorder
        addSubview(scroller)
        seeMore.isHidden = true
        seeMore.onPress = { [weak self] in self?.scrollFurther() }
        addSubview(seeMore)
        scroller.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentScrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroller.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("comment")
        setAccessibilityHelp("Enter opens a comment (press it again to reply) and Escape closes it. The Up and Down arrows move between comments.")
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func update(_ next: MarkdownCommentThread) {
        guard next != thread else { return }
        thread = next
        rebuild()
    }

    // MARK: - Building

    private func rebuild() {
        let keepReply = replyField?.text ?? replyDraft
        let replyHadFocus = replyField?.hasFocus == true
        let editHadFocus = editField?.hasFocus == true
        content.subviews.forEach { $0.removeFromSuperview() }
        pillsBuilt = []
        defer { shownPills = pillsBuilt }
        entries = []
        quoteLabel = nil
        quoteRule = nil
        foldButton = nil
        editParts = nil
        deleteParts = nil
        replyField = nil
        editField = nil
        replySend = nil
        alphaValue = thread.resolved ? 0.7 : 1
        isRaised = isLit || isExpanded

        if let quote {
            let label = NSTextField(wrappingLabelWithString: "")
            let text = NSMutableAttributedString()
            if quote.detached {
                text.append(NSAttributedString(string: "was on: ", attributes: [.font: CommentPalette.caption, .foregroundColor: CommentPalette.mutedText]))
            }
            text.append(NSAttributedString(string: quote.text.isEmpty ? "(deleted)" : quote.text,
                                           attributes: [.font: CommentPalette.caption, .foregroundColor: CommentPalette.secondaryText]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = quote.text
            label.setAccessibilityLabel(quote.detached ? "Was on \u{201C}\(quote.text)\u{201D}" : quote.text)
            content.addSubview(label)
            quoteLabel = label
            // the reference editor's quote: a 2 pt leading rule in the strong border.
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = CommentPalette.alpha3.cgColor
            content.addSubview(rule)
            quoteRule = rule
        }

        if isChip {
            buildChip()
            updateActions()
            updateAccessibility()
            needsLayout = true
            return
        }
        var comments = thread.comments
        if isCompact && !isExpanded { comments = [thread.root] } else if thread.replies.count >= 2 && !unfolded {
            comments = [thread.root, thread.replies.last!]
        }
        for (index, comment) in comments.enumerated() {
            if index == 1, thread.replies.count >= 2, !unfolded, !(isCompact && !isExpanded) {
                let hidden = thread.replies.count - 1
                let fold = CommentTextButton(hidden == 1 ? "Show 1 reply" : "Show \(hidden) replies", style: .link)
                fold.onPress = { [weak self] in
                    self?.unfolded = true
                    self?.rebuild()
                    self?.notifyResize()
                }
                content.addSubview(fold)
                foldButton = fold
            }
            entries.append(makeEntry(for: comment, isRoot: comment.id == thread.root.id))
        }

        if isExpanded && !thread.resolved && editing == nil {
            let box = ReplyBox()
            let field = CommentFieldView(frame: .zero)
            field.placeholder = "Reply"
            field.maximumHeight = 272
            field.text = keepReply
            field.onChange = { [weak self] text in
                guard let self else { return }
                self.replyDraft = text
                self.replySend?.isHidden = field.isBlank
                self.delegate?.card(self, replyDraftChanged: text)
                self.notifyResize()
            }
            field.onSubmit = { [weak self] in self?.submitReply() }
            field.onEscape = { [weak self] in
                guard let self else { return }
                field.text = ""
                self.window?.makeFirstResponder(self)
            }
            let send = CommentButton(symbol: "arrow.up", tooltip: "Send")
            send.isHidden = field.isBlank
            send.onPress = { [weak self] in self?.submitReply() }
            box.addSubview(field)
            box.addSubview(send)
            content.addSubview(box)
            replyField = field
            replySend = send
            if replyHadFocus { DispatchQueue.main.async { field.focus() } }
        }
        if editHadFocus, let editField { DispatchQueue.main.async { editField.focus() } }
        updateActions()
        updateAccessibility()
        needsLayout = true
    }

    private func makeEntry(for comment: MarkdownComment, isRoot: Bool) -> Entry {
        let time = NSTextField(labelWithString: CommentTimeFormat.string(for: comment.createdAt) + (comment.edited ? " (edited)" : ""))
        time.font = CommentPalette.caption
        time.textColor = CommentPalette.mutedText
        content.addSubview(time)

        var actions: [CommentButton] = []
        if !thread.resolved {
            let react = CommentButton(symbol: "face.smiling.inverse", tooltip: "Add reaction", side: 20, iconSize: 14)
            react.onPress = { [weak self, weak react] in
                guard let self, let react else { return }
                self.delegate?.card(self, pickReactionFor: comment.id, from: react)
            }
            actions.append(react)
        }
        let more = CommentButton(symbol: "ellipsis", tooltip: "More actions")
        more.onPress = { [weak self, weak more] in
            guard let self, let more else { return }
            self.delegate?.card(self, moreFor: comment.id, from: more)
        }
        actions.append(more)
        if isRoot, !thread.resolved {
            let resolve = CommentButton(symbol: "checkmark", tooltip: "Resolve")
            resolve.onPress = { [weak self] in
                guard let self else { return }
                self.delegate?.cardResolve(self)
            }
            actions.append(resolve)
        }
        if isRoot, thread.resolved {
            let mark = CommentButton(symbol: "checkmark.circle.fill", tooltip: "Resolved")
            mark.tint = CommentPalette.accent
            mark.isEnabled = true
            actions.insert(mark, at: 0)
        }
        for button in actions {
            button.onHover = { [weak self] button, inside in
                guard let self else { return }
                self.delegate?.card(self, tooltip: button, inside: inside)
            }
            content.addSubview(button)
        }

        var body: NSTextField?
        var fade: CAGradientLayer?
        var more2: CommentTextButton?
        if editing?.commentID == comment.id {
            let box = ReplyBox()
            let field = CommentFieldView(frame: .zero)
            field.placeholder = "Edit comment"
            field.text = editing?.text ?? comment.body
            field.onSubmit = { [weak self, weak field] in self?.saveEdit(field?.text ?? "", of: comment) }
            field.onEscape = { [weak self] in
                guard let self else { return }
                self.delegate?.cardCancelEdit(self)
            }
            field.onChange = { [weak self] text in
                self?.editing?.text = text
                self?.notifyResize()
            }
            box.addSubview(field)
            content.addSubview(box)
            editField = field
            let cancel = CommentTextButton("Cancel", style: .secondary)
            cancel.onPress = { [weak self] in
                guard let self else { return }
                self.delegate?.cardCancelEdit(self)
            }
            let save = CommentTextButton("Save", style: .primary)
            save.onPress = { [weak self, weak field] in self?.saveEdit(field?.text ?? "", of: comment) }
            content.addSubview(cancel)
            content.addSubview(save)
            editParts = (box, cancel, save)
            DispatchQueue.main.async { [weak field] in field?.focus() }
        } else {
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = CommentBodyText.attributed(comment.body)
            label.isSelectable = false
            label.allowsEditingTextAttributes = true
            content.addSubview(label)
            body = label
            let limit = bodyLineLimit(for: comment)
            if limit != nil || expandedBodies.contains(comment.id) {
                let toggle = CommentTextButton(expandedBodies.contains(comment.id) ? "Show less" : "Show more", style: .link)
                toggle.onPress = { [weak self] in
                    guard let self else { return }
                    if self.expandedBodies.contains(comment.id) { self.expandedBodies.remove(comment.id) } else {
                        self.expandedBodies.insert(comment.id)
                    }
                    self.rebuild()
                    self.notifyResize()
                }
                content.addSubview(toggle)
                more2 = toggle
            }
            if limit != nil {
                let gradient = CAGradientLayer()
                gradient.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
                label.wantsLayer = true
                fade = gradient
            }
        }

        var pills: [CommentReactionPill] = []
        for emoji in comment.reactions {
            let pill = CommentReactionPill(emoji: emoji, count: 1, isMine: true)
            notePill(pill, key: "\(comment.id)|\(emoji)")
            pill.toolTip = "Remove reaction"
            pill.onPress = { [weak self] in
                guard let self else { return }
                self.delegate?.card(self, toggle: emoji, on: comment.id)
            }
            content.addSubview(pill)
            pills.append(pill)
        }

        if pendingDelete == comment.id {
            let rule = NSBox()
            rule.boxType = .custom
            rule.borderWidth = 0
            rule.fillColor = CommentPalette.alpha2
            let prompt = NSTextField(labelWithString: "Delete this comment?")
            prompt.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            prompt.textColor = CommentPalette.text
            let cancel = CommentTextButton("Cancel", style: .secondary)
            cancel.onPress = { [weak self] in
                guard let self else { return }
                self.delegate?.cardCancelDelete(self)
            }
            let delete = CommentTextButton("Delete", style: .danger)
            delete.onPress = { [weak self] in
                guard let self else { return }
                // Clicks within 500 ms of the question are ignored.
                guard ProcessInfo.processInfo.systemUptime - self.deleteShownAt >= 0.5 else { return }
                self.delegate?.card(self, confirmDelete: comment.id)
            }
            for view in [rule, prompt, cancel, delete] as [NSView] { content.addSubview(view) }
            deleteParts = (rule, prompt, cancel, delete)
            deleteShownAt = ProcessInfo.processInfo.systemUptime
        }
        return Entry(id: comment.id, time: time, actions: actions, body: body, fade: fade, more: more2, pills: pills)
    }

    // MARK: - Reaction chip (doc 25 §6.2)

    /// A reaction on text shows as the reference editor's chip: its pills, and on hover
    /// Add reaction and Resolve; opened, it is an ordinary card.
    var isChip: Bool { thread.reactionOnly && thread.replies.isEmpty && !isExpanded && !thread.resolved && quote == nil }

    private func buildChip() {
        var pills: [CommentReactionPill] = []
        for emoji in [thread.root.body] + thread.root.reactions.filter({ $0 != thread.root.body }) {
            let pill = CommentReactionPill(emoji: emoji, count: 1, isMine: true)
            notePill(pill, key: "\(thread.root.id)|\(emoji)")
            pill.toolTip = emoji == thread.root.body ? "Remove reaction" : "Remove your reaction"
            pill.onPress = { [weak self] in
                guard let self else { return }
                self.delegate?.card(self, toggle: emoji, on: self.thread.root.id)
            }
            content.addSubview(pill)
            pills.append(pill)
        }
        let react = CommentButton(symbol: "face.smiling.inverse", tooltip: "Add reaction", side: 20, iconSize: 14)
        react.onPress = { [weak self, weak react] in
            guard let self, let react else { return }
            self.delegate?.card(self, pickReactionFor: self.thread.root.id, from: react)
        }
        let resolve = CommentButton(symbol: "checkmark", tooltip: "Resolve thread")
        resolve.onPress = { [weak self] in
            guard let self else { return }
            self.delegate?.cardResolve(self)
        }
        for button in [react, resolve] {
            button.onHover = { [weak self] button, inside in
                guard let self else { return }
                self.delegate?.card(self, tooltip: button, inside: inside)
            }
            content.addSubview(button)
        }
        let time = NSTextField(labelWithString: "")
        entries.append(Entry(id: thread.root.id, time: time, actions: [react, resolve], body: nil, fade: nil, more: nil, pills: pills))
    }

    private func layoutChip(apply: Bool) -> CGFloat {
        guard let entry = entries.first else { return 40 }
        let padding: CGFloat = 8
        var x = padding
        for pill in entry.pills {
            let size = pill.intrinsicContentSize
            if apply { pill.frame = NSRect(x: x, y: padding, width: size.width, height: size.height) }
            x += size.width + 6
        }
        var actionX = bounds.width - padding
        for button in entry.actions.reversed() {
            actionX -= button.side
            if apply { button.frame = NSRect(x: actionX, y: padding + (26 - button.side) / 2, width: button.side, height: button.side) }
            actionX -= 2
        }
        return padding * 2 + 26
    }

    /// the reference editor's own-pill motion: a reaction just added scales in from
    /// 0.8 over 200 ms with an overshoot (none with reduced motion).
    private func notePill(_ pill: CommentReactionPill, key: String) {
        pillsBuilt.insert(key)
        guard let shown = shownPills, !shown.contains(key), !CommentPalette.reducesMotion else { return }
        pill.wantsLayer = true
        DispatchQueue.main.async { [weak pill] in
            guard let pill, let layer = pill.layer else { return }
            let size = pill.bounds.size
            var from = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
            from = CATransform3DScale(from, 0.8, 0.8, 1)
            from = CATransform3DTranslate(from, -size.width / 2, -size.height / 2, 0)
            let pop = CABasicAnimation(keyPath: "transform")
            pop.fromValue = from
            pop.toValue = CATransform3DIdentity
            pop.duration = 0.2
            pop.timingFunction = CommentPalette.overshoot
            layer.add(pop, forKey: "pill-in")
        }
    }

    /// Lines a body shows before "Show more": 3 when compact, 15 past 16, else all.
    private func bodyLineLimit(for comment: MarkdownComment) -> Int? {
        guard !expandedBodies.contains(comment.id) else { return nil }
        let lines = Self.lineCount(of: comment.body, width: max(100, bounds.width - sidePadding * 2))
        if isCompact && !isExpanded { return lines > 3 ? 3 : nil }
        return lines > 16 ? 15 : nil
    }

    static func lineCount(of body: String, width: CGFloat) -> Int {
        let text = CommentBodyText.attributed(body)
        let height = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        return Int((height / CommentPalette.bodyLineHeight).rounded(.up))
    }

    private func saveEdit(_ text: String, of comment: MarkdownComment) {
        // Empty or unchanged text counts as Cancel.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || text == comment.body { delegate?.cardCancelEdit(self); return }
        delegate?.card(self, saveEdit: text, of: comment.id)
    }

    private func submitReply() {
        guard let field = replyField, !field.isBlank else { return }
        let text = field.text
        field.text = ""
        replyDraft = ""
        delegate?.card(self, reply: text)
    }

    func focusReply() { replyField?.focus() }

    func focusDeleteCancel() {
        deleteParts?.cancel.hasKeyboardFocus = true
    }

    private func notifyResize() {
        needsLayout = true
        delegate?.cardNeedsLayout(self)
    }

    // MARK: - Keyboard (doc 25 §7.2)

    enum Move { case next, previous, first, last }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        showsFocusRing = true
        delegate?.cardFocusChanged(self, focused: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        showsFocusRing = false
        delegate?.cardFocusChanged(self, focused: false)
        return true
    }

    /// ↑ ↓ Home End move between cards (no wrap); Enter or Space opens the
    /// card, Enter again goes to its Reply box; Escape closes it, and on a
    /// closed card goes back to the text.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: delegate?.card(self, move: .next)
        case 126: delegate?.card(self, move: .previous)
        case 115: delegate?.card(self, move: .first)
        case 119: delegate?.card(self, move: .last)
        case 36, 76, 49:
            if !isExpanded { delegate?.cardClicked(self) } else if event.keyCode != 49 { focusReply() }
        case 53: delegate?.cardEscape(self)
        default: super.keyDown(with: event)
        }
    }

    /// ⌥⌘M (as bound) on the card it opened: the way back is Escape.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, delegate?.isCommentChord(event) == true {
            delegate?.announce("First press Escape to go back to the text")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Hover and actions

    private func updateActions() {
        // Collapsed cards show their actions on hover; expanded ones pin them.
        let shows = isExpanded || isHovered || thread.resolved
        for entry in entries {
            for button in entry.actions { button.isHidden = !shows }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        delegate?.cardHovered(self, inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        delegate?.cardHovered(self, inside: false)
    }

    override func mouseDown(with event: NSEvent) {
        delegate?.cardClicked(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    /// The card's height at its width (260 in the rail).
    func fittingHeight() -> CGFloat {
        let height = layoutContent(apply: false)
        return heightCap.map { min($0, height) } ?? height
    }

    override func layout() {
        super.layout()
        let height = layoutContent(apply: true)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(height, bounds.height))
        scroller.frame = bounds
        updateSeeMore()
    }

    /// "↓ See more" floats at the bottom while more than 24 pt is hidden below.
    private func updateSeeMore() {
        let hidden = content.frame.height - scroller.contentView.bounds.maxY
        seeMore.isHidden = hidden <= 24
        guard !seeMore.isHidden else { return }
        let size = seeMore.intrinsicContentSize
        seeMore.frame = NSRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8,
                               width: size.width, height: size.height)
    }

    @objc private func contentScrolled() { updateSeeMore() }

    private func scrollFurther() {
        let clip = scroller.contentView
        let target = min(content.frame.height - clip.bounds.height, clip.bounds.minY + clip.bounds.height - 24)
        clip.scroll(to: NSPoint(x: 0, y: max(0, target)))
        scroller.reflectScrolledClipView(clip)
    }

    @discardableResult
    private func layoutContent(apply: Bool) -> CGFloat {
        if isChip { return layoutChip(apply: apply) }
        let inner = bounds.width - sidePadding * 2
        var y = Self.padding
        let x = sidePadding
        func place(_ view: NSView, _ frame: NSRect) { if apply { view.frame = frame } }
        /// Cancel and a primary button at the right, 8 apart.
        func placePair(_ cancel: CommentTextButton, _ primary: CommentTextButton) {
            let primaryWidth = primary.intrinsicContentSize.width
            let cancelWidth = cancel.intrinsicContentSize.width
            place(primary, NSRect(x: x + inner - primaryWidth, y: y, width: primaryWidth, height: 24))
            place(cancel, NSRect(x: x + inner - primaryWidth - 8 - cancelWidth, y: y, width: cancelWidth, height: 24))
            y += 24
        }

        if let label = quoteLabel {
            let height = min(ceil(label.sizeThatFits(NSSize(width: inner - 10, height: .greatestFiniteMagnitude)).height), 34)
            place(label, NSRect(x: x + 10, y: y, width: inner - 10, height: height))
            if let quoteRule { place(quoteRule, NSRect(x: x, y: y, width: 2, height: height)) }
            y += height + 8
        }

        for (index, entry) in entries.enumerated() {
            if index == 1, let fold = foldButton {
                place(fold, NSRect(x: x, y: y, width: fold.intrinsicContentSize.width, height: 17))
                y += 17 + 8
            }
            if index > 0 { y += 4 }
            // Header: the time, then the actions at the right.
            let rowHeight: CGFloat = 24
            place(entry.time, NSRect(x: x, y: y + (rowHeight - 17) / 2, width: inner - 72, height: 17))
            var actionX = x + inner
            for button in entry.actions.reversed() {
                actionX -= button.side
                place(button, NSRect(x: actionX, y: y + (rowHeight - button.side) / 2, width: button.side, height: button.side))
                actionX -= 2
            }
            y += rowHeight + 2

            if let body = entry.body {
                let full = ceil(body.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
                var height = full
                if let limit = bodyLineLimit(for: thread.comments.first { $0.id == entry.id }!) {
                    height = min(full, CGFloat(limit) * CommentPalette.bodyLineHeight)
                }
                place(body, NSRect(x: x, y: y, width: inner, height: height))
                if apply, let fade = entry.fade {
                    body.layer?.mask = fade
                    fade.frame = body.bounds
                    // Fade the last 16 pt.
                    let stop = max(0, (height - 16) / max(height, 1))
                    fade.locations = body.isFlipped ? [NSNumber(value: stop), 1] : [0, NSNumber(value: 1 - stop)]
                    fade.colors = body.isFlipped ? [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
                        : [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
                }
                y += height
                if let toggle = entry.more {
                    y += 2
                    place(toggle, NSRect(x: x, y: y, width: toggle.intrinsicContentSize.width, height: 17))
                    y += 17
                }
            } else if editing?.commentID == entry.id, let parts = editParts, let field = editField {
                let fieldHeight = field.fittingHeight(forWidth: inner - 16)
                place(parts.box, NSRect(x: x, y: y, width: inner, height: fieldHeight + 12))
                place(field, NSRect(x: 8, y: 6, width: inner - 16, height: fieldHeight))
                y += fieldHeight + 12 + 8
                placePair(parts.cancel, parts.save)
            }

            if !entry.pills.isEmpty {
                y += 8
                var pillX = x
                for pill in entry.pills {
                    let size = pill.intrinsicContentSize
                    if pillX + size.width > x + inner, pillX > x { pillX = x; y += size.height + 6 }
                    place(pill, NSRect(x: pillX, y: y, width: size.width, height: size.height))
                    pillX += size.width + 6
                }
                y += 26
            }

            if pendingDelete == entry.id, let parts = deleteParts {
                y += 8
                place(parts.rule, NSRect(x: x, y: y, width: inner, height: 1))
                y += 9
                place(parts.prompt, NSRect(x: x, y: y, width: inner, height: 17))
                y += 17 + 8
                placePair(parts.cancel, parts.delete)
            }
        }

        if let field = replyField, let box = field.superview {
            y += 8
            let fieldHeight = field.fittingHeight(forWidth: inner - 16 - 28)
            place(box, NSRect(x: x, y: y, width: inner, height: fieldHeight + 12))
            if apply {
                field.frame = NSRect(x: 8, y: 6, width: inner - 16 - 28, height: fieldHeight)
                replySend?.frame = NSRect(x: inner - 4 - 24, y: 6 + fieldHeight - 24, width: 24, height: 24)
            }
            y += fieldHeight + 12
        }
        return ceil(y + Self.padding)
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        var parts = [CommentTimeFormat.string(for: thread.root.createdAt) + "."]
        parts.append(String(thread.root.body.prefix(140)) + ".")
        if !thread.replies.isEmpty { parts.append(thread.replies.count == 1 ? "1 reply." : "\(thread.replies.count) replies.") }
        if let quote, !quote.text.isEmpty { parts.append("On \u{201C}\(quote.text.prefix(60))\u{201D}.") }
        if thread.resolved { parts.append("Resolved.") }
        if isExpanded { parts.append("Expanded.") }
        setAccessibilityLabel(parts.joined(separator: " "))
    }
}

/// The Reply and Edit boxes (doc 25 §5.2): radius 8, the field fill, a 1 pt
/// inset ring, padding 6 × 8.
final class ReplyBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = CommentPalette.alpha1.cgColor
            layer?.borderColor = CommentPalette.alpha2.cgColor
        }
        layer?.borderWidth = 1
    }
}

/// The card's inner scroller: a card that fits passes the wheel on to the
/// document (the rail never scrolls itself).
final class CardScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let document = documentView, document.frame.height <= contentView.bounds.height + 0.5 {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The card's content, top-down.
final class CardContentView: NSView {
    override var isFlipped: Bool { true }
}
