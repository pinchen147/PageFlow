//
//  EPUBPageView+Highlights.swift
//  PageFlow
//
//  How a page shows and edits the reader's highlights: their paint, the note
//  marker in the margin, a click on a noted highlight, and the context menu.
//  Notes open in the Notes panel beside the pages, never over the text. The
//  page reports its selection to the book's `EPUBHighlights`.
//

import AppKit
import SwiftUI
import Translation

extension EPUBPageView {

    // MARK: - Paint

    /// A highlight colour as it shows behind text on the page's paper.
    static func paint(_ color: NSColor, on palette: EPUBPagePalette) -> NSColor {
        let opacity = switch palette {
        case .light: DesignTokens.epubHighlightOpacityLight
        case .sepia: DesignTokens.epubHighlightOpacitySepia
        case .dark: DesignTokens.epubHighlightOpacityDark
        }
        return color.withAlphaComponent(opacity)
    }

    /// Every temporary attribute a highlight paints with.
    static let highlightPaintKeys: [NSAttributedString.Key] = [.backgroundColor, .underlineStyle, .underlineColor]

    /// How a highlight paints its words: a tint behind them, or a thick
    /// line under them in its colour, deepened on light paper to show and,
    /// on dark paper, the text's colour if it would sink into the paper.
    static func paintAttributes(_ highlight: EPUBPageHighlight,
                                on palette: EPUBPagePalette) -> [NSAttributedString.Key: Any] {
        switch highlight.style {
        case .tint:
            return [.backgroundColor: paint(highlight.color, on: palette)]
        case .underline:
            let color: NSColor
            if palette == .dark {
                let brightness = highlight.color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1
                color = brightness < DesignTokens.epubUnderlineLeastBrightnessOnDark
                    ? EPUBTextStyling.themeTextColor(for: .dark) : highlight.color
            } else {
                color = highlight.color.blended(withFraction: DesignTokens.epubUnderlineDeepening, of: .black) ?? highlight.color
            }
            return [.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: color]
        }
    }

    /// What VoiceOver hears for the page's highlights.
    var highlightsDescription: String? {
        guard let content, !content.highlights.isEmpty else { return nil }
        let string = textView.string as NSString
        return content.highlights.compactMap { highlight in
            guard NSMaxRange(highlight.range) <= string.length else { return nil }
            let words = string.substring(with: highlight.range)
            let shown = words.count > 80 ? String(words.prefix(80)) + "…" : words
            return "\(highlight.style.passageLabel): \(shown)" + (highlight.hasNote ? ", with a note" : "")
        }.joined(separator: "; ")
    }

    // MARK: - Note markers

    /// The dots beside highlights with notes, in the page's coordinates, on
    /// the first line of each, in the margin past the text.
    func noteMarkers(_ content: EPUBPageContent) -> [(id: UUID, rect: NSRect)] {
        guard let layout = textView.layoutManager else { return [] }
        let string = textView.string as NSString
        let size = DesignTokens.epubNoteMarkerSize
        return content.highlights.compactMap { highlight -> (id: UUID, rect: NSRect)? in
            // Beside the first painted word: a highlight may start on a line's break.
            guard highlight.hasNote, highlight.startsHere, NSMaxRange(highlight.range) <= string.length,
                  let first = Self.runsWithoutLineBreaks(highlight.range, in: string).first else { return nil }
            if let line = lineRectOnFixedPage(first.location) {
                // Beside the text, kept on the page's paper.
                let x = min(line.maxX + DesignTokens.epubNoteMarkerGap, textView.frame.maxX - size)
                return (highlight.id, NSRect(x: x, y: line.midY - size / 2, width: size, height: size))
            }
            let glyph = layout.glyphIndexForCharacter(at: first.location)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            if textView.layoutOrientation == .vertical {
                // Above the column, in the margin its line starts from.
                let midX = textView.convert(NSPoint(x: 0, y: line.midY), to: self).x
                return (highlight.id, NSRect(x: midX - size / 2,
                                             y: textView.frame.minY - DesignTokens.epubNoteMarkerGap - size,
                                             width: size, height: size))
            }
            let midY = textView.frame.minY + textView.textContainerOrigin.y + line.midY
            return (highlight.id, NSRect(x: textView.frame.maxX + DesignTokens.epubNoteMarkerGap,
                                         y: midY - size / 2, width: size, height: size))
        }
    }

    private func lineRectOnFixedPage(_ index: Int) -> NSRect? {
        textView.fixedLineRect(at: index)?.offsetBy(dx: textView.frame.minX, dy: textView.frame.minY)
    }

    /// A fixed page's context menu: the page's items from what is under the
    /// pointer as drawn, over the system's, which read the selection.
    func fixedPageMenu(for event: NSEvent, systemMenu: NSMenu?) -> NSMenu? {
        let index = textView.characterIndex(at: textView.convert(event.locationInWindow, from: nil))
        var menu = systemMenu
        if menu == nil {
            menu = NSMenu()
            menu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        }
        return menu.map { pageMenu($0, hit: index) }
    }

    func drawNoteMarkers(_ content: EPUBPageContent) {
        for marker in noteMarkers(content) {
            let color = content.highlights.first { $0.id == marker.id }?.color ?? DesignTokens.highlightYellow
            color.setFill()
            NSBezierPath(ovalIn: marker.rect).fill()
        }
    }

    // MARK: - Selection

    // The text view delegate's own selectors: the conformance is on the class.
    /// A native selection becomes the book's, painted like the rest; the
    /// native one is dropped so it never draws over the paint. A context
    /// click's word is left out: `selectForContextClick` has already chosen.
    @objc(textViewDidChangeSelection:)
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !textView.isHoldingMenuSelection, let content, let annotator = content.annotator else { return }
        let native = textView.selectedRange()
        guard native.length > 0 else { return }
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        if !isContextClick { annotator.select(content.chapterSelection(native)) }
        textView.setSelectedRange(NSRange(location: NSMaxRange(native), length: 0))
    }

    // MARK: - Clicks and the context menu

    /// A click on a highlight with a note selects the note; a plain highlight
    /// is just text to click in (its note is added from Add Note, the context
    /// menu or the panel), and a link inside either still opens.
    func clicked(characterAt index: Int) -> Bool {
        guard let content, content.annotator != nil,
              let hit = content.highlights.first(where: { NSLocationInRange(index, $0.range) }), hit.hasNote,
              textView.textStorage?.attribute(.link, at: index, effectiveRange: nil) == nil else { return false }
        content.annotator?.selectNote(hit.id)
        return true
    }

    /// A book's text can't be edited: the system's editing items have no place.
    private static let editingActions: Set<Selector> = [
        #selector(NSText.cut(_:)), #selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
        #selector(NSFontManager.orderFrontFontPanel(_:)), #selector(NSText.showGuessPanel(_:)),
        #selector(NSTextView.orderFrontSubstitutionsPanel(_:)),
    ]

    private static func removeEditingItems(from menu: NSMenu) {
        for item in menu.items {
            let actions = [item.action].compactMap { $0 } + (item.submenu?.items.compactMap(\.action) ?? [])
            if actions.contains(where: editingActions.contains) { menu.removeItem(item) }
        }
        var previousIsSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousIsSeparator { menu.removeItem(item) } else { previousIsSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
    }

    /// A selection running past this page: Look Up stays on this page's part, the
    /// words the reader clicked, for a meaning a whole passage doesn't have. Translate
    /// is for the passage, so it takes all of it. The system's item can only read this
    /// page's text, and comes second of the two it adds for the selection.
    private func translateWholeSelection(in menu: NSMenu) {
        guard let content, let annotator = content.annotator, let whole = annotator.selectedText?.string,
              let local = content.localRange(of: annotator.selection), local.length < whole.utf16.count,
              let system = menu.items.filter({ $0.action.map(NSStringFromSelector) == "_rvMenuItemAction" }).dropFirst().first else { return }
        let index = menu.index(of: system)
        menu.removeItem(at: index)
        menu.insertItem(EPUBMenuItem("Translate Selection") { [weak self] in self?.presentTranslation(of: whole) }, at: index)
    }

    /// The system's translation panel, over the selection on this page.
    func presentTranslation(of text: String) {
        var anchor: NSView?
        let host = NSHostingView(rootView: EPUBTranslationAnchor(text: text) { anchor?.removeFromSuperview() })
        anchor = host
        let selected = content.flatMap { $0.localRange(of: $0.annotator?.selection) }
        host.frame = selected.flatMap { lineRect(atLocal: $0.location) } ?? bounds
        addSubview(host)
    }

    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        pageMenu(menu, hit: charIndex)
    }

    private func pageMenu(_ menu: NSMenu, hit charIndex: Int?) -> NSMenu {
        Self.removeEditingItems(from: menu)
        translateWholeSelection(in: menu)
        // Zoom Image / Zoom Table first, under the highlight items.
        let zoomItems = charIndex.map { zoomMenuItems(at: $0) } ?? []
        for (index, item) in (zoomItems + (zoomItems.isEmpty ? [] : [.separator()])).enumerated() {
            menu.insertItem(item, at: index)
        }
        guard let content, let annotator = content.annotator else { return menu }
        // The whole selection, on this page and any other.
        let hit = annotator.selection != nil
            ? annotator.highlightAtSelection
            : charIndex.flatMap { index in content.highlights.first { NSLocationInRange(index, $0.range) } }
                .flatMap { annotator.highlight($0.id) }
        var items: [NSMenuItem] = []
        if let highlight = hit {
            let id = highlight.id
            items.append(EPUBMenuItem(highlight.isNote ? "Edit Note" : "Add Note") { annotator.edit(id) })
            items.append(colorMenu("Change Color", presets: highlight.presets(asNote: highlight.isNote),
                                   current: highlight.color) {
                annotator.setColor($0, of: id)
            })
            let underline = EPUBMenuItem("Underline") {
                annotator.setStyle(highlight.style == .underline ? .tint : .underline, of: id)
            }
            underline.state = highlight.style == .underline ? .on : .off
            items.append(underline)
            items.append(EPUBMenuItem(highlight.style.removalTitle) { annotator.remove(id) })
        } else if let selection = annotator.selection, annotator.canAnnotateSelection {
            // The menu acts on the selection it opened with.
            items.append(colorMenu("Highlight", presets: EPUBHighlightStyle.tint.presets, current: annotator.color,
                                   shortcut: "highlight") { color in
                annotator.select(selection)
                annotator.color = color
                annotator.highlightSelection()
            })
            let underline = EPUBMenuItem("Underline") {
                annotator.select(selection)
                annotator.highlightSelection(style: .underline)
            }
            let underlineKey = ShortcutModel.current(for: "underline")
            underline.keyEquivalent = underlineKey.nsKeyEquivalent
            underline.keyEquivalentModifierMask = underlineKey.nsModifierFlags
            items.append(underline)
            let note = EPUBMenuItem("Add Note") {
                annotator.select(selection)
                annotator.addNoteToSelection()
            }
            let shortcut = ShortcutModel.current(for: "comment")
            note.keyEquivalent = shortcut.nsKeyEquivalent
            note.keyEquivalentModifierMask = shortcut.nsModifierFlags
            items.append(note)
        }
        if !items.isEmpty { items.append(.separator()) }
        if let speech = readAloudItem(clickedAt: charIndex) { items += [speech, .separator()] }
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
        if let book = content.document { appendPageCommands(of: book, to: menu) }
        return menu
    }

    /// A PDF page's commands, in the order PDFKit and `StablePDFView` give
    /// them: sizing, layouts, page turns, then the bookmark.
    private func appendPageCommands(of book: EPUBContent, to menu: NSMenu) {
        func command(_ title: String, shortcut: String? = nil, isOn: Bool = false, isEnabled: Bool = true,
                     action: @escaping () -> Void) {
            let item = EPUBMenuItem(title, handler: action)
            item.isAvailable = isEnabled
            item.state = isOn ? .on : .off
            if let shortcut {
                let key = ShortcutModel.current(for: shortcut)
                item.keyEquivalent = key.nsKeyEquivalent
                item.keyEquivalentModifierMask = key.nsModifierFlags
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        command("Zoom to Fit", shortcut: "zoomToFit", isOn: book.zoom == .fit, action: book.zoomToFit)
        command("Zoom In", shortcut: "zoomIn", isEnabled: book.canZoomIn, action: book.zoomIn)
        command("Zoom Out", shortcut: "zoomOut", isEnabled: book.canZoomOut, action: book.zoomOut)
        command("Reflow to Fit", shortcut: "actualSize", isOn: book.zoom == .reflow, action: book.reflowToFit)
        menu.addItem(.separator())
        for layout in [EPUBPageLayout.singlePage, .singlePageContinuous, .twoUp, .twoUpContinuous] {
            command(layout.title, isOn: book.layout == layout) { book.setLayout(layout) }
        }
        menu.addItem(.separator())
        command("Next Page", shortcut: "nextPage", isEnabled: book.canTurn(forward: true)) { book.turnPage(forward: true) }
        command("Previous Page", shortcut: "previousPage", isEnabled: book.canTurn(forward: false)) {
            book.turnPage(forward: false)
        }
        menu.addItem(.separator())
        command("Bookmark Page", shortcut: "bookmark", isOn: book.isCurrentLocationBookmarked,
                action: book.toggleBookmarkAtCurrentLocation)
    }

    /// Read Aloud from the selection or the clicked word, or Stop. A book
    /// with its own narration says so.
    private func readAloudItem(clickedAt index: Int?) -> NSMenuItem? {
        guard let content, let reader = content.readAloud else { return nil }
        if reader.isActive { return EPUBMenuItem(reader.stopTitle) { reader.stop() } }
        if let selection = content.annotator?.selection {
            let title = reader.usesNarration ? "Play Narration of Selection" : "Read Selection Aloud"
            return EPUBMenuItem(title) { reader.start(at: selection.start, until: selection.end) }
        }
        // From the start of the clicked word.
        guard let index else { return nil }
        let word = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        guard let start = content.position(atLocal: word.location) else { return nil }
        return EPUBMenuItem(reader.usesNarration ? "Play Narration from Here" : "Read Aloud from Here") { reader.start(at: start) }
    }

    /// A submenu of colour presets, the current one checked and, for
    /// Highlight, showing the Highlight shortcut.
    private func colorMenu(_ title: String, presets: [SettingsManager.ColorPreset], current: String, shortcut: String? = nil,
                           choose: @escaping (String) -> Void) -> NSMenuItem {
        let submenu = NSMenu()
        for preset in presets {
            let item = EPUBMenuItem(preset.name) { choose(preset.hex) }
            item.image = Self.swatch(preset.color)
            if SettingsManager.ColorPreset.colorsMatch(preset.hex, current) {
                item.state = .on
                if let shortcut {
                    let key = ShortcutModel.current(for: shortcut)
                    item.keyEquivalent = key.nsKeyEquivalent
                    item.keyEquivalentModifierMask = key.nsModifierFlags
                }
            }
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        let size = DesignTokens.epubNoteMarkerSize + 5
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

}

/// Presents the system's translation panel once, then goes.
private struct EPUBTranslationAnchor: View {
    let text: String
    let onClose: () -> Void
    @State private var isPresented = false

    var body: some View {
        Color.clear
            .translationPresentation(isPresented: $isPresented, text: text)
            .onAppear { isPresented = true }
            .onChange(of: isPresented) { if !isPresented { onClose() } }
    }
}

/// A context-menu item that runs a closure.
final class EPUBMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    /// False shows the command greyed, as a menu's autoenabling would.
    var isAvailable = true

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isAvailable }
}
