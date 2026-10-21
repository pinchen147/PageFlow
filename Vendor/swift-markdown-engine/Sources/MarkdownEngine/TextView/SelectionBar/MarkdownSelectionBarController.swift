import AppKit

/// Shows the reference editor's floating selection bar over a non-empty selection
/// (doc 24 §6, §7.8). It lives in the editor's scroll view, above the clip
/// view, so it never scrolls or magnifies with the text. One reducer decides
/// visibility; placement is a port of the reference editor's functions; the bar pops in
/// only when it appears.
final class MarkdownSelectionBarController {
    weak var coordinator: NativeTextViewCoordinator?
    weak var scrollView: NSScrollView?
    let bar = MarkdownSelectionBarView(frame: .zero)
    let tooltip = ChromeTooltipView(frame: .zero)
    private(set) var state = MarkdownFormatState()
    private(set) var isShown = false
    /// A mouse drag is extending the selection (the bar waits for mouse-up).
    var isDragSelecting = false {
        didSet { if isDragSelecting != oldValue { setNeedsUpdate() } }
    }
    /// Escape hid the bar for this selection; any other selection brings it back.
    private var escapeSuppressed: NSRange?
    private var imageSuppressed: NSRange?

    func suppressImageUntilClick() {
        imageSuppressed = coordinator?.objectSelection?.token
        update()
    }

    func imageClicked() { imageSuppressed = nil; update() }
    /// A right-click hid the bar until the next primary mouse-down or key-down.
    var rightClickSuppressed = false {
        didSet { if rightClickSuppressed != oldValue { setNeedsUpdate() } }
    }
    /// Set while a dropdown or popover belonging to the bar is open.
    var isMenuOpen = false
    /// Off only in tests, whose windows cannot become key.
    var requiresKeyWindow = true
    /// the reference editor's link dialog, while it is open (the bar hides meanwhile).
    private(set) var linkPopover: MarkdownLinkPopover?
    private var updateScheduled = false
    private var observers: [NSObjectProtocol] = []

    init(coordinator: NativeTextViewCoordinator, scrollView: NSScrollView) {
        self.coordinator = coordinator
        self.scrollView = scrollView
        bar.isHidden = true
        scrollView.addSubview(bar, positioned: .above, relativeTo: nil)
        wireButtons()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSWindow) === self.scrollView?.window else { return }
                    self.update()
                    self.coordinator?.textView.flatMap { $0 as? NativeTextView }?.redisplayTablesUnderSelection()
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func uninstall() {
        tooltip.cancel()
        tooltip.removeFromSuperview()
        bar.removeFromSuperview()
    }

    // MARK: - Triggers

    /// Recompute on the next run-loop turn (one recompute per turn).
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateScheduled = false
                self.update()
            }
        }
    }

    /// Escape in the text: hide until the selection changes (the reference editor's Escape ladder, step 3).
    func suppressForEscape() -> Bool {
        guard isShown, let selection = currentSelection() else { return false }
        escapeSuppressed = selection
        update()
        return true
    }

    /// The scroll view moved or resized: keep the bar on its anchor.
    func reposition() {
        guard isShown else { return }
        place(animated: false)
    }

    // MARK: - Reducer

    /// Shows the bar only when every gate passes (doc 24 §6.1), hides it at once otherwise.
    func update() {
        PerfTrace.time("selectionBar.update") { updateNow() }
    }

    private func updateNow() {
        guard let coordinator, let scrollView, let main = coordinator.textView as? NativeTextView else { return hide() }
        let session = coordinator.tableEditingSession
        guard let selection = currentSelection(), selection.length > 0 || session.isRangeMode else {
            escapeSuppressed = nil
            refreshState()
            return hide()
        }
        if let suppressed = escapeSuppressed, suppressed != selection { escapeSuppressed = nil }
        refreshState()
        let window = scrollView.window
        let responder = window?.firstResponder
        let focused = responder === main || responder === session.editor || responder === bar || isMenuOpen
        let composing = main.hasMarkedText() || session.editor.hasMarkedText()
        let zooming = (scrollView as? ClampedScrollView)?.isZoomInProgress == true
        let comments = coordinator.comments != nil
        bar.showsComments = comments
        let visible = (window?.isKeyWindow == true || !requiresKeyWindow) && focused && linkPopover == nil && !isDragSelecting && !composing
            && escapeSuppressed == nil && !rightClickSuppressed && (state.context != .codeBlock || comments)
            && main.isEditable && !coordinator.isWritingToolsActive && !zooming && !scrollView.isHiddenOrHasHiddenAncestor
            // An image selected as a whole gets its own arrangement (doc 26 §4, Phase 3), never the text bar.
            && coordinator.imageControls?.isInteracting != true && imageSuppressed != selection
        guard visible else { return hide() }
        bar.arrange(inTable: session.isActive, inCode: state.context == .codeBlock && !session.isActive, image: coordinator.objectSelection != nil)
        applyState(maximumWidth: scrollView.bounds.width - 16)
        let appearing = !isShown
        isShown = true
        bar.isHidden = false
        // Above the clip view, scrollers and pockets, every time it shows.
        if bar.superview !== scrollView || scrollView.subviews.last !== bar {
            scrollView.addSubview(bar, positioned: .above, relativeTo: nil)
        }
        place(animated: appearing)
    }

    private func hide() {
        tooltip.cancel()
        guard isShown || !bar.isHidden else { return }
        isShown = false
        bar.layer?.removeAllAnimations()
        bar.isHidden = true
    }

    /// The selection the bar is for: the focused cell's, else the document's.
    private func currentSelection() -> NSRange? {
        guard let coordinator else { return nil }
        let session = coordinator.tableEditingSession
        if session.isActive { return session.editor.selectedRange() }
        guard let main = coordinator.textView else { return nil }
        return main.selectedRange()
    }

    private func refreshState() {
        guard let coordinator else { return }
        var computed: MarkdownFormatState?
        PerfTrace.time("selectionBar.state") { computed = coordinator.currentFormatState() }
        guard let next = computed else {
            // No parse yet for a long note's latest edit: look again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.setNeedsUpdate() }
            return
        }
        if next != state {
            state = next
            coordinator.publishFormatState(next)
        }
    }

    private func applyState(maximumWidth: CGFloat = .greatestFiniteMagnitude) {
        let buttons = bar.buttons
        if case .image(let alignment, let hasCrop, _) = state.context {
            buttons[.alignLeft]?.isPressed = alignment == .left
            buttons[.alignCenter]?.isPressed = alignment == .center
            buttons[.alignRight]?.isPressed = alignment == .right
            for (item, value) in [(MarkdownSelectionBarView.Item.alignLeft, ImageAltTokens.Alignment.left), (.alignCenter, .center), (.alignRight, .right)] {
                buttons[item]?.setAccessibilityValue(NSNumber(value: alignment == value))
            }
            buttons[.crop]?.isPressed = hasCrop
        }
        buttons[.bold]?.isPressed = state.bold
        buttons[.italic]?.isPressed = state.italic
        buttons[.underline]?.isPressed = state.underline
        buttons[.strikethrough]?.isPressed = state.strikethrough
        buttons[.code]?.isPressed = state.code
        buttons[.highlight]?.isPressed = state.highlight
        buttons[.link]?.isPressed = state.link
        buttons[.link]?.isEnabled = state.linkEnabled
        buttons[.link]?.tooltip = state.linkEnabled ? "Link" : "Select a single cell to link"
        // Comment is disabled saying why.
        let commentable = MainActor.assumeIsolated { coordinator?.comments?.commentableSelection != nil }
        buttons[.comment]?.isEnabled = commentable
        buttons[.comment]?.tooltip = commentable ? "Comment" : "Select some text or table cells to comment"
        switch state.textStyle {
        case .heading(let level)?:
            buttons[.textStyle]?.content = .text("H\(level)")
            buttons[.textStyle]?.setAccessibilityLabel("H\(level), Heading \(level) — text style")
        default:
            buttons[.textStyle]?.content = .symbol("textformat")
            buttons[.textStyle]?.setAccessibilityLabel("Aa, text style")
        }
        let listSymbol: String
        switch state.listPressed {
        case .numbered?: listSymbol = "list.number"
        case .checklist?: listSymbol = "checklist"
        default: listSymbol = "list.bullet"
        }
        buttons[.list]?.content = .symbol(listSymbol)
        buttons[.list]?.isPressed = state.listPressed != nil
        bar.layoutItems(maximumWidth: maximumWidth)
    }

    // MARK: - Keyboard

    /// F6 / ⌘F6 (the reference editor): the keyboard moves into the visible bar.
    func focusBar() -> Bool {
        guard isShown else { return false }
        escapeSuppressed = nil
        bar.beginKeyboardFocus(inTable: coordinator?.tableEditingSession.isActive == true)
        return true
    }

    private func returnKeyboardToText() {
        guard let coordinator else { return }
        let session = coordinator.tableEditingSession
        let target: NSView? = session.isActive ? session.editor : coordinator.textView
        scrollView?.window?.makeFirstResponder(target)
    }

    // MARK: - Placement

    /// Places the bar over its anchor; pops it in when it is appearing.
    private func place(animated: Bool) {
        guard let scrollView, let anchor = anchor() else { return hide() }
        let width = bar.frame.width
        let height = MarkdownSelectionBarView.height
        let insets = scrollView.contentInsets
        let top = insets.top + MarkdownSelectionBarPlacement.margin
        let bottom = scrollView.bounds.height - insets.bottom
        let placed = MarkdownSelectionBarPlacement.top(anchor: anchor.rect, barHeight: height, top: top, bottom: bottom,
                                                       caret: anchor.caret)
        let cx = MarkdownSelectionBarPlacement.centerX(anchor.rect.midX, width: width, left: 0, right: scrollView.bounds.width)
        let topDown = NSRect(x: (cx - width / 2).rounded(), y: placed.y.rounded(), width: width, height: height)
        bar.frame = fromTopDown(topDown)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = bar.layer else { return }
        // the reference editor's pop: fade in over 120 ms while rising (or dropping) 4 pt.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        let downward: CGFloat = scrollView.isFlipped ? 1 : -1
        rise.fromValue = (placed.below ? -4 : 4) * downward
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = 0.12
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "pop")
    }

    private func fromTopDown(_ rect: NSRect) -> NSRect {
        guard let scrollView, !scrollView.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: scrollView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func toTopDown(_ rect: NSRect) -> NSRect {
        guard let scrollView, !scrollView.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: scrollView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The union of the carets at the selection's two ends (the reference editor's
    /// anchor), in top-down scroll-view points, and the head caret to dodge.
    private func anchor() -> (rect: NSRect, caret: NSRect?)? {
        guard let coordinator, let scrollView else { return nil }
        if let object = coordinator.objectSelection, let main = coordinator.textView as? NativeTextView,
           let rect = main.renderedImageRect(at: object.anchor) {
            return (toTopDown(scrollView.convert(rect, from: main)), nil)
        }
        let session = coordinator.tableEditingSession
        let view: NSTextView
        let selection: NSRange
        if session.isRangeMode, let rect = session.rangeRect(in: scrollView) {
            return (toTopDown(rect), nil)
        }
        if session.isActive, session.editor.window != nil {
            view = session.editor
            selection = session.editor.selectedRange()
        } else if let main = coordinator.textView as? NativeTextView {
            view = main
            selection = main.selectedRange()
            // Never lay text out to find an anchor: ends outside the laid-out
            // viewport count as above or below it.
            if let viewport = main.viewportCharacterRange {
                let startVisible = NSLocationInRange(selection.location, viewport)
                let endVisible = NSMaxRange(selection) <= NSMaxRange(viewport) && NSMaxRange(selection) > viewport.location
                if !startVisible && !endVisible {
                    // Both ends above, or both below: the selection scrolled away with its bar.
                    if NSMaxRange(selection) <= viewport.location || selection.location >= NSMaxRange(viewport) { return nil }
                    // Straddling the viewport: pinned, like ⌘A.
                    return (NSRect(x: scrollView.bounds.midX, y: -1_000_000, width: 0, height: 2_000_000), nil)
                }
                if !startVisible || !endVisible {
                    let visibleEnd = startVisible ? selection.location : max(selection.location, NSMaxRange(selection) - 1)
                    guard let rect = caretRect(visibleEnd, in: view, trailing: !startVisible) else { return nil }
                    let stretched = startVisible
                        ? NSRect(x: rect.minX, y: rect.minY, width: max(1, scrollView.bounds.width - rect.minX), height: 1_000_000)
                        : NSRect(x: 0, y: -1_000_000, width: max(1, rect.maxX), height: rect.maxY + 1_000_000)
                    return (stretched, nil)
                }
            }
        } else {
            return nil
        }
        guard selection.length > 0,
              let start = caretRect(selection.location, in: view, trailing: false),
              let end = caretRect(NSMaxRange(selection) - 1, in: view, trailing: true) else { return nil }
        let union = NSRect(x: min(start.minX, end.maxX), y: min(start.minY, end.minY),
                           width: abs(end.maxX - start.minX), height: max(start.maxY, end.maxY) - min(start.minY, end.minY))
        return (union, end)
    }

    /// The caret before (or, `trailing`, after) the character at `location`, in top-down scroll-view points.
    private func caretRect(_ location: Int, in view: NSTextView, trailing: Bool) -> NSRect? {
        guard let scrollView, let window = view.window else { return nil }
        let length = (view.string as NSString).length
        guard length > 0 else { return nil }
        let index = min(max(0, location), length - 1)
        let screen = view.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        guard !screen.isNull, screen.origin.x.isFinite, screen.size.height > 0 else { return nil }
        let inWindow = window.convertFromScreen(screen)
        let inScroll = toTopDown(scrollView.convert(inWindow, from: nil))
        let x = trailing ? inScroll.maxX : inScroll.minX
        return NSRect(x: x, y: inScroll.minY, width: 0, height: inScroll.height)
    }

    // MARK: - Actions

    private func wireButtons() {
        bar.onKeyboardExit = { [weak self] in self?.returnKeyboardToText() }
        bar.moreButton.onPress = { [weak self] button in self?.showMoreMenu(from: button) }
        for (item, button) in bar.buttons {
            button.snapshot = { [weak self] in AnyHashable(self?.currentSelection().map { [$0.location, $0.length] } ?? []) }
            button.onHover = { [weak self] button, inside in
                guard let self, let scrollView = self.scrollView else { return }
                if inside { self.tooltip.schedule(button.tooltip, for: button, in: scrollView) } else { self.tooltip.cancel() }
            }
            button.onPress = { [weak self] button in self?.perform(item, from: button) }
        }
    }

    private func perform(_ item: MarkdownSelectionBarView.Item, from button: SelectionBarButton) {
        guard let coordinator else { return }
        tooltip.cancel()
        switch item {
        case .comment:
            hide()
            MainActor.assumeIsolated { coordinator.comments?.beginComment() }
            return
        case .alignLeft: coordinator.setImageAlignment(.left)
        case .alignCenter: coordinator.setImageAlignment(.center)
        case .alignRight: coordinator.setImageAlignment(.right)
        case .crop: coordinator.imageControls?.beginCrop()
        case .imageMore: coordinator.imageControls?.showMenu(from: button)
        case .bold: coordinator.applyInlineStyle(.bold)
        case .italic: coordinator.applyInlineStyle(.italic)
        case .underline: coordinator.applyInlineStyle(.underline)
        case .strikethrough: coordinator.apply(.strikethrough)
        case .code: coordinator.apply(.code)
        case .highlight: coordinator.apply(.highlight)
        case .link: showLinkEditor()
        case .textStyle: showTextStyleMenu(from: button)
        case .list: showListMenu(from: button)
        }
        announce(item)
        update()
    }

    /// VoiceOver hears "Bold on" / "Bold off" after a mark changes (the reference editor's announcements).
    private func announce(_ item: MarkdownSelectionBarView.Item) {
        let names: [MarkdownSelectionBarView.Item: (String, KeyPath<MarkdownFormatState, Bool>)] = [
            .bold: ("Bold", \.bold), .italic: ("Italic", \.italic), .underline: ("Underline", \.underline),
            .strikethrough: ("Strikethrough", \.strikethrough), .code: ("Code", \.code), .highlight: ("Highlight", \.highlight),
        ]
        guard let (name, key) = names[item], let coordinator, let next = coordinator.currentFormatState() else { return }
        NSAccessibility.post(element: bar, notification: .announcementRequested,
                             userInfo: [.announcement: "\(name) \(next[keyPath: key] ? "on" : "off")",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Link dialog

    /// Link or ⌘K (doc 24 §6.7): edit the link at the selection, or make the
    /// selection a link. Text and Link are empty for a caret outside a link.
    func showLinkEditor() {
        guard let coordinator, let main = coordinator.textView, main.isEditable,
              !coordinator.tableEditingSession.isActive else { return }
        let selection = main.selectedRange()
        let target = coordinator.linkTarget(around: selection) ?? MarkdownLinkPopover.Target(
            range: selection, text: (main.string as NSString).substring(with: selection), url: "", isExistingLink: false
        )
        presentLink(.edit, target)
    }

    /// A click on a rendered link opens its actions (the reference editor never navigates on click).
    func showLinkActions(at index: Int) -> Bool {
        guard let coordinator, let target = coordinator.linkTarget(around: NSRange(location: index, length: 0)) else { return false }
        presentLink(.actions, target)
        return true
    }

    private func presentLink(_ mode: MarkdownLinkPopover.Mode, _ target: MarkdownLinkPopover.Target) {
        guard let coordinator, let scrollView, let main = coordinator.textView else { return }
        linkPopover?.close()
        let popover = MarkdownLinkPopover(mode: mode, target: target)
        popover.onSave = { [weak coordinator] text, url in
            coordinator?.writeLink(MarkdownLinkURL.markdown(text: text, url: url), over: target.range,
                                   actionName: target.isExistingLink ? "Edit Link" : "Add Link")
            NSAccessibility.post(element: main, notification: .announcementRequested,
                                 userInfo: [.announcement: target.isExistingLink ? "Link updated" : "Link added"])
        }
        popover.onRemove = { [weak coordinator] in
            coordinator?.writeLink(target.text, over: target.range, actionName: "Remove Link")
            NSAccessibility.post(element: main, notification: .announcementRequested, userInfo: [.announcement: "Link removed"])
        }
        popover.onClose = { [weak self] in
            self?.linkPopover = nil
            self?.update()
        }
        linkPopover = popover
        hide()
        let anchor = anchorRect(for: target.range, in: main) ?? NSRect(x: scrollView.bounds.midX, y: scrollView.bounds.midY, width: 0, height: 0)
        popover.present(in: scrollView, anchor: anchor, topInset: scrollView.contentInsets.top)
    }

    /// `range`'s caret union in top-down scroll-view points, if it is laid out.
    private func anchorRect(for range: NSRange, in view: NSTextView) -> NSRect? {
        guard let start = caretRect(range.location, in: view, trailing: false),
              let end = caretRect(max(range.location, NSMaxRange(range) - 1), in: view, trailing: range.length > 0) else { return nil }
        return NSRect(x: min(start.minX, end.maxX), y: min(start.minY, end.minY),
                      width: abs(end.maxX - start.minX), height: max(start.maxY, end.maxY) - min(start.minY, end.minY))
    }

    // MARK: - Dropdowns

    private func showTextStyleMenu(from button: SelectionBarButton) {
        let checked: Int? = {
            switch state.textStyle {
            case .text?: return 0
            case .heading(let level)? where level <= 3: return level
            default: return nil
            }
        }()
        let rows: [ChromeMenuView.Row] = [
            .init(title: "Text", glyph: "Aa", shortcut: "⌥⌘0", checked: checked == 0) { [weak self] in self?.coordinator?.apply(.paragraph) },
            .init(title: "Heading 1", glyph: "H1", shortcut: "⌥⌘1", checked: checked == 1) { [weak self] in self?.coordinator?.apply(.heading(level: 1)) },
            .init(title: "Heading 2", glyph: "H2", shortcut: "⌥⌘2", checked: checked == 2) { [weak self] in self?.coordinator?.apply(.heading(level: 2)) },
            .init(title: "Heading 3", glyph: "H3", shortcut: "⌥⌘3", checked: checked == 3) { [weak self] in self?.coordinator?.apply(.heading(level: 3)) },
        ]
        openMenu(rows, from: button)
    }

    private func showListMenu(from button: SelectionBarButton) {
        var rows: [ChromeMenuView.Row] = [
            .init(title: "Bulleted list", symbol: "list.bullet", shortcut: "⇧⌘8", checked: state.listChecked == .bulleted) { [weak self] in
                self?.coordinator?.apply(.bulletedList)
            },
            .init(title: "Numbered list", symbol: "list.number", shortcut: "⇧⌘7", checked: state.listChecked == .numbered) { [weak self] in
                self?.coordinator?.apply(.numberedList)
            },
            .init(title: "Checklist", symbol: "checklist", checked: state.listChecked == .checklist) { [weak self] in
                self?.coordinator?.apply(.checklist)
            },
        ]
        if state.showsIndentRows {
            rows.append(.separator)
            rows.append(.init(title: "Indent", symbol: "increase.indent", shortcut: "Tab", checked: false) { [weak self] in
                self?.coordinator?.apply(.indent)
            })
            rows.append(.init(title: "Outdent", symbol: "decrease.indent", shortcut: "⇧Tab", checked: false) { [weak self] in
                self?.coordinator?.apply(.outdent)
            })
        }
        openMenu(rows, from: button)
    }

    /// "More formatting": the folded controls, each with its chord.
    private func showMoreMenu(from button: SelectionBarButton) {
        let names: [MarkdownSelectionBarView.Item: (String, String, String?)] = [
            .alignLeft: ("Align left", "text.alignleft", nil), .alignCenter: ("Align center", "text.aligncenter", nil),
            .alignRight: ("Align right", "text.alignright", nil), .crop: ("Crop image", "crop", nil),
            .imageMore: ("More actions", "ellipsis", nil),
            .textStyle: ("Text style", "textformat", nil), .bold: ("Bold", "bold", "⌘B"), .italic: ("Italic", "italic", "⌘I"),
            .underline: ("Underline", "underline", "⌘U"), .strikethrough: ("Strikethrough", "strikethrough", "⇧⌘X"),
            .code: ("Code", "chevron.left.forwardslash.chevron.right", nil), .highlight: ("Highlight", "highlighter", nil),
            .list: ("List", "list.bullet", nil), .link: ("Link", "link", "⌘K"),
        ]
        let rows = bar.folded.compactMap { item -> ChromeMenuView.Row? in
            guard let (title, symbol, chord) = names[item], let control = bar.buttons[item] else { return nil }
            return .init(title: title, symbol: symbol, shortcut: chord, checked: control.isPressed) { [weak self, weak control] in
                guard let self, let control else { return }
                self.perform(item, from: control.isHidden ? self.bar.moreButton : control)
            }
        }
        openMenu(rows, from: button)
    }

    private func openMenu(_ rows: [ChromeMenuView.Row], from button: SelectionBarButton) {
        guard let scrollView else { return }
        button.isMenuOpen = true
        isMenuOpen = true
        ChromeMenuView.present(rows, below: button, in: scrollView) { [weak self, weak button] in
            button?.isMenuOpen = false
            self?.isMenuOpen = false
            self?.update()
        }
    }
}
