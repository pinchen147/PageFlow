import AppKit

/// Semantic ownership with the shared selection-bar controls, menus and link dialog.
@MainActor
final class NativeSemanticSelectionBar {
    weak var owner: NativeSemanticDocumentCoordinator?
    weak var scroll: NSScrollView?
    let bar = MarkdownSelectionBarView(frame: .zero)
    let tooltip = ChromeTooltipView(frame: .zero)
    var linkPopover: MarkdownLinkPopover?
    var menuOpen = false
    private var observers: [NSObjectProtocol] = []

    init(owner: NativeSemanticDocumentCoordinator, scroll: NSScrollView) {
        self.owner = owner
        self.scroll = scroll
        scroll.addSubview(bar)
        bar.isHidden = true
        bar.onKeyboardExit = { [weak self] in
            guard let owner = self?.owner else { return }
            owner.textView.window?.makeFirstResponder(owner.textView)
        }
        for (item, button) in bar.buttons {
            button.onPress = { [weak self] button in self?.perform(item, from: button) }
            button.onHover = { [weak self] button, inside in
                guard let self, let scroll = self.scroll else { return }
                if inside { self.tooltip.schedule(button.tooltip, for: button, in: scroll) }
                else { self.tooltip.cancel() }
            }
        }
        bar.moreButton.onPress = { [weak self] button in
            guard let self else { return }
            self.openMenu(self.bar.folded.map { item in
                ChromeMenuView.Row(title: self.bar.buttons[item]?.tooltip ?? "Format", glyph: "", checked: false) { [weak self] in
                    self?.perform(item, from: button)
                }
            }, from: button)
        }
        for name in [NSTextView.didChangeSelectionNotification, NSView.boundsDidChangeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func uninstall() {
        linkPopover?.close()
        tooltip.cancel()
        tooltip.removeFromSuperview()
        bar.removeFromSuperview()
    }

    func update() {
        guard let owner, let scroll else { return }
        if menuOpen { return }
        let view = editingView()
        let selection = view.selectedRange()
        guard owner.configuration.showsSelectionBar, view.isEditable, !view.hasMarkedText(),
              !owner.isWritingToolsActive, selection.length > 0, !scroll.isHiddenOrHasHiddenAncestor,
              scroll.window?.isKeyWindow == true, linkPopover == nil else { bar.isHidden = true; return }
        let state = owner.currentFormatState
        bar.showsComments = owner.onKeyCommand != nil
        let selectedImage: Bool
        if let storage = view.textStorage, selection.location < storage.length,
           case .image? = storage.attribute(NativeSemanticAttributes.object, at: selection.location, effectiveRange: nil) as? SemanticInlineObject {
            selectedImage = selection.length == 1
        } else { selectedImage = false }
        bar.arrange(inTable: view !== owner.textView, inCode: state.context == .codeBlock, image: selectedImage)
        for (item, enabled) in [(MarkdownSelectionBarView.Item.bold, state.bold), (.italic, state.italic),
                                (.underline, state.underline), (.strikethrough, state.strikethrough),
                                (.highlight, state.highlight), (.code, state.code), (.link, state.link)] {
            bar.buttons[item]?.isPressed = enabled
            bar.buttons[item]?.setAccessibilityValue(NSNumber(value: enabled))
        }
        if case .heading(let level)? = state.textStyle { bar.buttons[.textStyle]?.content = .text("H\(level)") }
        else { bar.buttons[.textStyle]?.content = .symbol("textformat") }
        bar.buttons[.list]?.isPressed = state.listPressed != nil
        bar.layoutItems(maximumWidth: max(0, scroll.bounds.width - 16))
        let anchor = anchorRect(selection, in: view)
        bar.setFrameOrigin(NSPoint(x: min(max(8, anchor.midX - bar.frame.width / 2), max(8, scroll.bounds.width - bar.frame.width - 8)),
                                   y: min(max(8, anchor.minY - bar.frame.height - 8), max(8, scroll.bounds.height - bar.frame.height - 8))))
        bar.isHidden = false
    }

    func focusBar() -> Bool {
        update()
        guard !bar.isHidden else { return false }
        bar.beginKeyboardFocus(inTable: editingView() !== owner?.textView)
        return true
    }

    func showLinkEditor() {
        guard let owner, let scroll else { return }
        let view = editingView()
        let range = view.selectedRange()
        guard range.length > 0, let storage = view.textStorage else { return }
        let selected = storage.attributedSubstring(from: range)
        let descriptor = selected.attribute(NativeSemanticAttributes.link, at: 0, effectiveRange: nil) as? SemanticInlineLink
        let url: String
        if case .url(let destination, _)? = descriptor { url = destination } else { url = "" }
        let popover = MarkdownLinkPopover(mode: .edit, target: .init(range: range, text: selected.string, url: url, isExistingLink: descriptor != nil))
        let expectedRevision = owner.revision
        popover.onSave = { [weak owner, weak view] label, destination in
            guard let owner, let view, owner.revision == expectedRevision else { return }
            let inline = SemanticInlineText(runs: [.init(text: label, link: .url(destination: destination, title: nil))])
            let replacement = NSMutableAttributedString(attributedString: NativeSemanticAttributes.attributedText(inline, font: view.font ?? .systemFont(ofSize: 16)))
            for key in [NativeSemanticAttributes.blockID, NativeSemanticAttributes.paragraphRole, NativeSemanticAttributes.blockLineEnding] {
                if let value = selected.attribute(key, at: 0, effectiveRange: nil) {
                    replacement.addAttribute(key, value: value, range: NSRange(location: 0, length: replacement.length))
                }
            }
            if view === owner.textView { _ = owner.replaceVisible(range, with: replacement, actionName: "Edit Link") }
            else { view.insertText(replacement, replacementRange: range) }
        }
        popover.onClose = { [weak self] in self?.linkPopover = nil; self?.update() }
        linkPopover = popover
        bar.isHidden = true
        popover.present(in: scroll, anchor: anchorRect(range, in: view), topInset: scroll.contentInsets.top)
    }

    private func editingView() -> NSTextView {
        guard let owner else { return NSTextView() }
        if let view = owner.textView.window?.firstResponder as? NSTextView,
           let session = view.delegate as? NativeSemanticTableSession,
           session.grid?.superview === owner.textView { return view }
        return owner.textView
    }

    private func anchorRect(_ range: NSRange, in view: NSTextView) -> NSRect {
        guard let scroll, let window = view.window else { return .zero }
        let screen = view.firstRect(forCharacterRange: range, actualRange: nil)
        let rect = scroll.convert(window.convertFromScreen(screen), from: nil)
        return NSRect(x: rect.minX, y: scroll.isFlipped ? rect.minY : scroll.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func perform(_ item: MarkdownSelectionBarView.Item, from button: SelectionBarButton) {
        guard let owner else { return }
        tooltip.cancel()
        let format: MarkdownFormat
        switch item {
        case .bold: format = .bold
        case .italic: format = .italic
        case .underline: format = .underline
        case .strikethrough: format = .strikethrough
        case .highlight: format = .highlight
        case .code: format = .code
        case .alignLeft: _ = owner.editSelectedImage { $0.alignment = .left }; update(); return
        case .alignCenter: _ = owner.editSelectedImage { $0.alignment = .center }; update(); return
        case .alignRight: _ = owner.editSelectedImage { $0.alignment = .right }; update(); return
        case .link: showLinkEditor(); return
        case .comment: _ = owner.onKeyCommand?(.comment); return
        case .textStyle:
            let rows = [("Text", MarkdownFormat.paragraph)] + (1...6).map { ("Heading \($0)", MarkdownFormat.heading(level: $0)) }
            openMenu(rows.map { title, format in .init(title: title, glyph: "", checked: false) { [weak owner] in _ = owner?.applyFormat(format) } }, from: button)
            return
        case .list:
            let rows: [(String, MarkdownFormat)] = [("Bulleted List", .bulletedList), ("Numbered List", .numberedList),
                ("Checklist", .checklist), ("Indent", .indent), ("Outdent", .outdent)]
            openMenu(rows.map { title, format in .init(title: title, glyph: "", checked: false) { [weak owner] in _ = owner?.applyFormat(format) } }, from: button)
            return
        case .crop: owner.beginImageCrop(); return
        case .imageMore:
            openMenu([
                .init(title: "Edit alt text") { [weak owner] in owner?.editImageAltText() },
                .init(title: "Edit source") { [weak owner] in
                    guard let owner else { return }; owner.editObject(at: owner.textView.selectedRange().location)
                },
                .init(title: "Reset crop") { [weak owner] in _ = owner?.editSelectedImage { $0.crop = nil } },
                .init(title: "Natural size") { [weak owner] in _ = owner?.editSelectedImage { $0.width = nil } }
            ], from: button)
            return
        }
        _ = owner.applyFormat(format)
        update()
    }

    private func openMenu(_ rows: [ChromeMenuView.Row], from button: SelectionBarButton) {
        guard let scroll else { return }
        menuOpen = true
        ChromeMenuView.present(rows, below: button, in: scroll) { [weak self] in
            self?.menuOpen = false
            self?.update()
        }
    }
}
