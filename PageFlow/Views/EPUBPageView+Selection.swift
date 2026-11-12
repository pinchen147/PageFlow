//
//  EPUBPageView+Selection.swift
//  PageFlow
//
//  Selecting a book's text with the mouse and keyboard, across every page on
//  screen: a drag runs from one page into the next (scrolling the stack when
//  it reaches the window's edge), a double or triple click takes a word or
//  line, as in a PDF, Shift-click extends. The selection lives in the book's
//  `EPUBHighlights` in chapter offsets; each page paints its part.
//

import AppKit
import Carbon.HIToolbox

/// What a click takes, and a drag from it extends by.
enum EPUBSelectionGranularity {
    case character, word, line

    /// One click places the caret, two take a word, three a line.
    init(clickCount: Int) {
        switch clickCount {
        case ...1: self = .character
        case 2: self = .word
        default: self = .line
        }
    }
}

extension EPUBPageView {

    /// The pages showing the same book in `container` (a spread's pages, the
    /// stack's tiled rows).
    static func bookPages(in container: NSView?, annotator: EPUBHighlights) -> [EPUBPageView] {
        (container?.subviews ?? []).compactMap { $0 as? EPUBPageView }
            .filter { !$0.isHidden && $0.content?.annotator === annotator }
    }

    /// The selection colour, as the system draws it on this page's paper.
    static func selectionColor(on palette: EPUBPagePalette) -> NSColor {
        var color = NSColor.selectedTextBackgroundColor
        NSAppearance(named: palette == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }

    // MARK: - Mouse

    /// The unit of text (a caret place, word or line) at a window point,
    /// in the book's offsets. A point above or below the text takes the
    /// page's start or end, so a drag past a page's edge selects to it.
    func unit(at windowPoint: NSPoint, granularity: EPUBSelectionGranularity)
        -> (start: EPUBTextPosition, end: EPUBTextPosition)? {
        guard let content else { return nil }
        let point = textView.convert(windowPoint, from: nil)
        let length = textView.string.utf16.count
        let index: Int
        let isVertical = textView.layoutOrientation == .vertical
        // In a vertical page the view is turned: x runs down the screen.
        if point.y < 0 || (isVertical && point.x < 0) {
            index = 0
        } else if point.y > textView.bounds.maxY || (isVertical && point.x > textView.bounds.maxX) {
            index = length
        } else {
            let inside = NSPoint(x: min(max(point.x, 0), textView.bounds.maxX), y: point.y)
            index = textView.characterIndexForInsertion(at: inside)
        }
        guard granularity != .character, length > 0 else {
            return content.position(atLocal: index).map { ($0, $0) }
        }
        // A word or line is the one under the pointer, not the one after the caret place.
        let under = textView.characterIndex(at: point) ?? min(index, length - 1)
        let range = granularity == .line ? words(ofLineAt: under)
            : textView.selectionRange(forProposedRange: NSRange(location: under, length: 0), granularity: .selectByWord)
        guard let start = content.position(atLocal: range.location),
              let end = content.position(atLocal: NSMaxRange(range)) else { return nil }
        return (start, end)
    }

    /// The characters of the line holding a character, on this page.
    func lineCharacters(at index: Int) -> NSRange? {
        if let fixed = textView.fixedLayer { return fixed.lineRange(at: index) }
        guard let layout = textView.layoutManager else { return nil }
        var glyphs = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: index), effectiveRange: &glyphs)
        return layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    }

    /// The line holding a character, without the spaces and break that end it.
    private func words(ofLineAt index: Int) -> NSRange {
        let line = lineCharacters(at: index) ?? NSRange(location: index, length: 1)
        let string = textView.string as NSString
        var end = NSMaxRange(line)
        while end > line.location + 1, let scalar = Unicode.Scalar(string.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// The unit at a window point on whichever of `pages` is under it, or
    /// the nearest one when the point is between or beside them.
    static func unit(at windowPoint: NSPoint, among pages: [EPUBPageView], granularity: EPUBSelectionGranularity)
        -> (start: EPUBTextPosition, end: EPUBTextPosition)? {
        func distance(_ page: EPUBPageView) -> CGFloat {
            let frame = page.convert(page.bounds, to: nil)
            let dx = max(frame.minX - windowPoint.x, 0, windowPoint.x - frame.maxX)
            let dy = max(frame.minY - windowPoint.y, 0, windowPoint.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return pages.min { distance($0) < distance($1) }?.unit(at: windowPoint, granularity: granularity)
    }

    /// Selects with the mouse until the button comes up. Returns false when
    /// the page shows no book text, leaving the text view its own tracking.
    func trackSelection(from event: NSEvent) -> Bool {
        guard let content, let annotator = content.annotator, content.chapter != nil, let window,
              let container = superview else { return false }
        window.makeFirstResponder(textView)
        // A double-click on a figure opens it large; this tracking replaces
        // the text view's own, which would have told its delegate.
        if event.clickCount == 2, let index = textView.characterIndex(at: textView.convert(event.locationInWindow, from: nil)),
           zoomImage(at: index) { return true }
        // A press on selected text may be the start of dragging it out, if it
        // is small enough to read here; a press anywhere else starts anew.
        if event.clickCount == 1, !event.modifierFlags.contains(.shift), isOverSelection(event.locationInWindow),
           annotator.selectedText != nil {
            trackTextDrag(from: event, in: window)
            return true
        }
        let granularity = EPUBSelectionGranularity(clickCount: event.clickCount)
        guard let clicked = unit(at: event.locationInWindow, granularity: granularity) else { return true }
        // Shift-click extends from where the selection began, or the caret.
        let start = event.modifierFlags.contains(.shift) ? annotator.selection?.anchor ?? annotator.caret : nil
        let extends = start != nil
        let anchor = start.map { ($0, $0) } ?? clicked
        annotator.select(.extending(anchor, to: clicked))

        var dragged = false
        var last = event
        // Periodic events keep a drag held past the window's edge scrolling.
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        tracking: while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                                    until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            switch next.type {
            case .leftMouseUp:
                break tracking
            case .periodic:
                guard dragged else { continue }
            default:
                let moved = hypot(next.locationInWindow.x - event.locationInWindow.x,
                                  next.locationInWindow.y - event.locationInWindow.y)
                dragged = dragged || moved > 2
                last = next
            }
            guard dragged else { continue }
            container.autoscroll(with: last)
            // Scrolling may have brought new pages in: look again each time.
            let pages = Self.bookPages(in: container, annotator: annotator)
            if let unit = Self.unit(at: last.locationInWindow, among: pages, granularity: granularity) {
                annotator.select(.extending(anchor, to: unit))
            }
        }
        guard !dragged, !extends, event.clickCount == 1 else { return true }
        finishPlainClick(event, annotator: annotator)
        return true
    }

    /// A plain click: a link opens, a noted highlight selects its note.
    private func finishPlainClick(_ event: NSEvent, annotator: EPUBHighlights) {
        annotator.select(nil)
        let point = textView.convert(event.locationInWindow, from: nil)
        if let index = textView.characterIndex(at: point) {
            if let link = textView.textStorage?.attribute(.link, at: index, effectiveRange: nil) {
                textView.clicked(onLink: link, at: index)
            } else {
                _ = textView.clickHandler?(index)
            }
        }
    }

    func isOverSelection(_ windowPoint: NSPoint) -> Bool {
        guard let content, let selected = content.localRange(of: content.annotator?.selection),
              let index = textView.characterIndex(at: textView.convert(windowPoint, from: nil)) else { return false }
        return NSLocationInRange(index, selected)
    }

    /// How far a press on the selection moves before it is a drag of it.
    static let clearDragDistance: CGFloat = 8

    /// Waits to see what a press on the selection is: moved clearly, it
    /// drags the selected text out; let go, it's a plain click.
    private func trackTextDrag(from event: NSEvent, in window: NSWindow) {
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if let annotator = content?.annotator { finishPlainClick(event, annotator: annotator) }
                return
            }
            guard hypot(next.locationInWindow.x - event.locationInWindow.x,
                        next.locationInWindow.y - event.locationInWindow.y) > Self.clearDragDistance else { continue }
            beginTextDrag(with: event)
            return
        }
    }

    private func beginTextDrag(with event: NSEvent) {
        guard let item = textDragItem(at: event.locationInWindow) else { return }
        textView.beginDraggingSession(with: [item], event: event, source: textView)
    }

    /// The selection on its way out of the window, as Copy would give it, its
    /// first words under the pointer.
    func textDragItem(at windowPoint: NSPoint) -> NSDraggingItem? {
        guard let text = content?.annotator?.textForPasting else { return nil }
        let preview = NSAttributedString(string: String(text.string.prefix(48)),
                                         attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                      .foregroundColor: NSColor.labelColor])
        let size = preview.size()
        let image = NSImage(size: size, flipped: false) { _ in
            preview.draw(at: .zero)
            return true
        }
        let item = NSDraggingItem(pasteboardWriter: text)
        let pointer = textView.convert(windowPoint, from: nil)
        item.setDraggingFrame(NSRect(x: pointer.x - size.width / 2, y: pointer.y - size.height / 2,
                                     width: size.width, height: size.height), contents: image)
        return item
    }

    /// What a context click selects, as in Markdown's text view: inside the
    /// selection it stays for the menu to act on, on a word it moves to that
    /// word. Over no text (blank paper, a space, a figure) nothing stays
    /// selected, so a menu's Highlight or Copy can't reach text left elsewhere.
    func selectForContextClick(at windowPoint: NSPoint) {
        guard let content, let annotator = content.annotator else { return }
        let index = textView.characterIndex(at: textView.convert(windowPoint, from: nil))
        if let index, let selected = content.localRange(of: annotator.selection), NSLocationInRange(index, selected) { return }
        let word = index.flatMap { attachment(at: $0) == nil
            ? textView.selectionRange(forProposedRange: NSRange(location: $0, length: 0), granularity: .selectByWord) : nil }
        if let word, !(textView.string as NSString).substring(with: word).allSatisfy(\.isWhitespace) {
            annotator.select(content.chapterSelection(word))
        } else {
            annotator.placeCaret(at: unit(at: windowPoint, granularity: .character)?.start)
        }
    }

    /// The line fragment holding a character on this page, in the page's
    /// coordinates. A vertical line runs the page's height, so it gives only
    /// the character's own part of it, for a stack scrolling to follow it.
    func lineRect(atLocal index: Int) -> NSRect? {
        if let line = textView.fixedLineRect(at: index) {
            return line.offsetBy(dx: textView.frame.minX, dy: textView.frame.minY)
        }
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              index < textView.string.utf16.count else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: index)
        var line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        if textView.layoutOrientation == .vertical {
            let character = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            line.origin.x = character.minX
            line.size.width = character.width
        }
        let origin = textView.textContainerOrigin
        return textView.convert(line.offsetBy(dx: origin.x, dy: origin.y), to: self)
    }

    // MARK: - Reading place

    /// The text nearest a height on this page (in its coordinates), and the
    /// top of its line there: what a view's top edge is reading. On a page
    /// with no text yet, the page's own top.
    func readingAnchor(atY y: CGFloat) -> (position: EPUBTextPosition, lineTop: CGFloat)? {
        guard let content, let chapter = content.chapter, let range = content.range else { return nil }
        placeTextView()
        let length = textView.string.utf16.count
        guard length > 0 else { return (EPUBTextPosition(chapter: chapter, offset: range.location), 0) }
        let point = textView.convert(NSPoint(x: textView.bounds.midX, y: 0), to: self)
        let inText = textView.convert(NSPoint(x: point.x, y: y), from: self)
        let index = min(textView.characterIndexForInsertion(at: inText), length - 1)
        return (EPUBTextPosition(chapter: chapter, offset: range.location + index), lineRect(atLocal: index)?.minY ?? 0)
    }

    /// The top of the line holding a place on this page, in its coordinates;
    /// the page's top if the place has no line here.
    func lineTop(of place: EPUBReadingPlace) -> CGFloat {
        guard let range = content?.range, content?.chapter == place.chapter,
              NSLocationInRange(place.offset, range) else { return 0 }
        placeTextView()
        return lineRect(atLocal: place.offset - range.location)?.minY ?? 0
    }

    // MARK: - Keyboard and commands

    /// Copy takes the whole selection, from every page.
    func copySelection() -> Bool {
        content?.annotator?.copySelection() ?? false
    }

    /// Services validate on the responder chain; only the subsequent write reads the book.
    func servicesRequestor(sending type: NSPasteboard.PasteboardType?,
                          receiving returnType: NSPasteboard.PasteboardType?) -> EPUBPageTextView? {
        guard let type, EPUBPageTextView.serviceTextTypes.contains(type),
              returnType == nil, content?.annotator?.selection != nil else { return nil }
        return textView
    }

    /// Select All takes the whole book, from any of its pages.
    func selectAllText() -> Bool {
        guard let annotator = content?.annotator, let chapter = content?.chapter else { return false }
        annotator.selectAll(from: chapter)
        return true
    }

    /// A turn or jump that leaves none of the selection on `pages` drops it,
    /// and the caret with it; one still on screen (a scroll, the next row)
    /// keeps it.
    static func dropSelection(ifNotOn pages: [EPUBPageView]) {
        guard let annotator = pages.lazy.compactMap({ $0.content?.annotator }).first else { return }
        if let selection = annotator.selection, pages.contains(where: { $0.content?.localRange(of: selection) != nil }) { return }
        if let caret = annotator.movingEnd, pages.contains(where: { $0.content?.shows(caret) == true }) { return }
        annotator.placeCaret(at: nil)
    }
}

/// Copy and Select All for a reader surface holding the keyboard (after a
/// click between pages): they act on the book's selection as on a page.
enum EPUBReaderTextCommands {
    static func copy(_ pages: [EPUBPageView]) {
        _ = pages.first?.copySelection()
    }

    static func selectAll(_ pages: [EPUBPageView]) {
        _ = pages.first?.selectAllText()
    }

    static func validate(_ item: NSMenuItem, pages: [EPUBPageView]) -> Bool? {
        switch item.action {
        case #selector(NSText.copy(_:)): pages.first?.content?.annotator?.selection != nil
        case #selector(NSText.selectAll(_:)): pages.first?.content?.chapter != nil
        default: nil
        }
    }
}
