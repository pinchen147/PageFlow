//
//  EPUBSelectionKeys.swift
//  PageFlow
//
//  The keyboard's way of extending a book's selection: the keys
//  `NSTextView`'s bindings give Markdown, each moving only the selection's
//  moving end, from where a drag or a click left it. Pages paint the book's
//  selection in chapter offsets, so the text view's own selection never takes
//  part: moves that depend on layout read it from the page holding that end.
//

import AppKit
import Carbon.HIToolbox
import CoreText

/// Where a Shift-key sends the selection's moving end.
enum EPUBSelectionMove: Equatable {
    case character(forward: Bool)
    case word(forward: Bool)
    case line(forward: Bool)
    case lineEnd(forward: Bool)
    case paragraph(forward: Bool)
    case page(forward: Bool)
    case chapterEnd(forward: Bool)

    /// `vertical`: the moving end's page runs its characters down and its
    /// lines to the left. `rightToLeft`: the text at the moving end has its
    /// next character to the left. Only a selection key asks either.
    init?(_ event: NSEvent, vertical: @autoclosure () -> Bool, rightToLeft: @autoclosure () -> Bool) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), modifiers) {
        case (kVK_PageDown, .shift): self = .page(forward: true); return
        case (kVK_PageUp, .shift): self = .page(forward: false); return
        case (kVK_End, .shift): self = .chapterEnd(forward: true); return
        case (kVK_Home, .shift): self = .chapterEnd(forward: false); return
        default: break
        }
        guard [.shift, [.shift, .option], [.shift, .command]].contains(modifiers) else { return nil }
        let alongText: Bool, forward: Bool
        switch Int(event.keyCode) {
        case kVK_LeftArrow: (alongText, forward) = vertical() ? (false, true) : (true, rightToLeft())
        case kVK_RightArrow: (alongText, forward) = vertical() ? (false, false) : (true, !rightToLeft())
        case kVK_UpArrow: (alongText, forward) = (vertical(), false)
        case kVK_DownArrow: (alongText, forward) = (vertical(), true)
        default: return nil
        }
        switch modifiers {
        case .shift: self = alongText ? .character(forward: forward) : .line(forward: forward)
        case [.shift, .option]: self = alongText ? .word(forward: forward) : .paragraph(forward: forward)
        case [.shift, .command]: self = alongText ? .lineEnd(forward: forward) : .chapterEnd(forward: forward)
        default: return nil
        }
    }
}

extension EPUBPageView {
    /// Extends the book's selection for a selection key; returns whether the
    /// event was one. Such a key never reaches the text view, whose own caret
    /// is stale. `pages` are the pages on screen, `pageContent` what any page
    /// shows.
    static func extendSelection(with event: NSEvent, among pages: [EPUBPageView],
                                pageContent: @escaping (Int) -> EPUBPageContent? = { _ in nil }) -> Bool {
        guard let annotator = pages.lazy.compactMap({ $0.content?.annotator }).first else { return false }
        let layouts = EPUBPageLayouts(annotator: annotator, pages: pages, pageContent: pageContent)
        let upstream = annotator.selection.map { $0.focus > $0.anchor } ?? false
        func movingEndIsVertical() -> Bool {
            annotator.movingEnd.flatMap { layouts.content(holding: $0, upstream: upstream) }?.isVertical ?? false
        }
        func movingEndRunsRightToLeft() -> Bool {
            guard let focus = annotator.movingEnd else { return false }
            return annotator.chapterText(focus.chapter)?.runsRightToLeft(at: focus.offset) ?? false
        }
        guard let move = EPUBSelectionMove(event, vertical: movingEndIsVertical(), rightToLeft: movingEndRunsRightToLeft()) else {
            return false
        }
        switch move {
        case .character(let forward): annotator.extendSelection(forward: forward)
        case .word(let forward): annotator.extendSelectionAWord(forward: forward)
        case .paragraph(let forward): annotator.extendSelectionAParagraph(forward: forward)
        case .chapterEnd(let forward): annotator.extendSelectionToChapterEnd(forward: forward)
        case .line, .lineEnd, .page:
            guard let focus = annotator.movingEnd else { break }
            if let moved = layouts.target(of: move, from: focus, upstream: upstream) {
                annotator.extendSelection(to: moved)
            }
        }
        return true
    }

    /// The line holding a caret place in the text view's coordinates, and how
    /// far along it the place is.
    fileprivate func caretPlace(atLocal local: Int) -> (x: CGFloat, line: NSRect)? {
        let length = textView.string.utf16.count
        guard length > 0 else { return nil }
        let index = min(local, length - 1)
        // Blocks sit anywhere on a fixed page: only its lines are known.
        if let line = textView.fixedLineRect(at: index) { return (line.minX, line) }
        guard let layout = textView.layoutManager else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: index)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        return (line.minX + layout.location(forGlyphAt: glyph).x + origin.x, line.offsetBy(dx: origin.x, dy: origin.y))
    }

    /// The caret place on the line above or below, or nil past the page's
    /// first or last line.
    fileprivate func caretPlace(aLineFrom local: Int, forward: Bool) -> Int? {
        guard let place = caretPlace(atLocal: local) else { return nil }
        let y = forward ? place.line.maxY + 1 : place.line.minY - 1
        if textView.fixedLayer != nil {
            // The nearest text above or below, if any is nearer than this line.
            let target = textView.characterIndexForInsertion(at: NSPoint(x: place.x, y: y))
            return (forward ? target > local : target < local) ? target : nil
        }
        guard let lines = textLines, y >= lines.minY, y <= lines.maxY else { return nil }
        return textView.characterIndexForInsertion(at: NSPoint(x: place.x, y: y))
    }

    /// From the top of a flowing page's first line to the foot of its last,
    /// in the text view's coordinates; the empty line a final line break
    /// leaves in the layout holds no text to go to.
    private var textLines: NSRect? {
        guard let layout = textView.layoutManager, layout.numberOfGlyphs > 0 else { return nil }
        let first = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let last = layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        return first.union(last).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The caret place at a distance along the page's first or last line.
    fileprivate func caretPlace(atX x: CGFloat, onFirstLine first: Bool) -> Int? {
        guard !textView.string.isEmpty else { return nil }
        if textView.fixedLayer != nil {
            return textView.characterIndexForInsertion(at: NSPoint(x: x, y: first ? 0 : textView.bounds.maxY))
        }
        guard let lines = textLines else { return nil }
        return textView.characterIndexForInsertion(at: NSPoint(x: x, y: first ? lines.minY + 1 : lines.maxY - 1))
    }

    /// The end of the line holding a caret place, before the spaces that end
    /// it. `upstream`: a place between two lines is on the first.
    fileprivate func lineEnd(fromLocal local: Int, forward: Bool, upstream: Bool) -> Int? {
        let length = textView.string.utf16.count
        guard length > 0 else { return nil }
        let index = min(upstream && local > 0 ? local - 1 : local, length - 1)
        guard let line = lineCharacters(at: index) else { return nil }
        guard forward else { return min(line.location, local) }
        let string = textView.string as NSString
        var end = NSMaxRange(line)
        while end > line.location, let scalar = Unicode.Scalar(string.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
        return max(end, local)
    }
}

private extension NSAttributedString {
    /// Whether the character at a place reads right to left, as its paragraph
    /// resolves it: a Latin word in Hebrew doesn't, nor does a Japanese book's
    /// horizontal chapter however its pages run.
    func runsRightToLeft(at offset: Int) -> Bool {
        guard length > 0 else { return false }
        let index = min(max(offset, 0), length - 1)
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
        let line = CTLineCreateWithAttributedString(attributedSubstring(from: paragraph))
        let local = index - paragraph.location
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let run = runs.first { CTRunGetStringRange($0).location <= local && local < CTRunGetStringRange($0).location + CTRunGetStringRange($0).length }
        return run.map { CTRunGetStatus($0).contains(.rightToLeft) } ?? false
    }
}

extension NSScrollView {
    /// Scrolls the least that shows a line, given in the document's
    /// coordinates, below `topInset`. A line wider than the window stays where
    /// it is sideways.
    func scrollToShow(_ line: NSRect, topInset: CGFloat = 0) {
        let visible = contentView.bounds
        var origin = visible.origin
        if line.maxY > visible.maxY { origin.y = line.maxY - visible.height }
        if line.minY < visible.minY + topInset { origin.y = line.minY - topInset }
        if line.width < visible.width {
            if line.maxX > visible.maxX { origin.x = line.maxX - visible.width }
            if line.minX < visible.minX { origin.x = line.minX }
        }
        guard origin != visible.origin else { return }
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

/// The layout of a book's pages, for the moves that depend on it: pages on
/// screen, or laid out off screen for the moment it takes to read them.
@MainActor
private struct EPUBPageLayouts {
    let annotator: EPUBHighlights
    let pages: [EPUBPageView]
    let pageContent: (Int) -> EPUBPageContent?

    func target(of move: EPUBSelectionMove, from focus: EPUBTextPosition, upstream: Bool) -> EPUBTextPosition? {
        guard let page = page(holding: focus, upstream: upstream), let content = page.content,
              let range = content.range else { return nil }
        let local = focus.offset - range.location
        let length = page.textView.string.utf16.count
        switch move {
        case .line(let forward):
            if let target = page.caretPlace(aLineFrom: local, forward: forward) { return content.position(atLocal: target) }
            guard let place = page.caretPlace(atLocal: local), let next = neighbor(of: content, forward: forward),
                  let target = next.caretPlace(atX: place.x, onFirstLine: forward) else {
                return content.position(atLocal: forward ? length : 0)
            }
            // At least a character over a page break, so the new page shows it.
            return next.content?.position(atLocal: forward ? max(target, 1) : target)
        case .lineEnd(let forward):
            return page.lineEnd(fromLocal: local, forward: forward, upstream: upstream).flatMap(content.position(atLocal:))
        case .page(let forward):
            guard let place = page.caretPlace(atLocal: local) else { return nil }
            guard let next = neighbor(of: content, forward: forward), let nextContent = next.content else {
                return content.position(atLocal: forward ? length : 0)
            }
            return nextContent.position(atLocal: next.textView.characterIndexForInsertion(at: NSPoint(x: place.x, y: place.line.midY)))
        default:
            return nil
        }
    }

    /// What's on the page a moving end is on. `upstream`: one at a page break
    /// is the end of the page before, where a selection coming to it is painted.
    func content(holding focus: EPUBTextPosition, upstream: Bool) -> EPUBPageContent? {
        func isIn(_ content: EPUBPageContent) -> Bool {
            guard content.shows(focus), let range = content.range else { return false }
            return upstream ? focus.offset > range.location : focus.offset < NSMaxRange(range)
        }
        let shown = pages.compactMap(\.content)
        if let content = shown.first(where: isIn) ?? shown.first(where: { $0.shows(focus) }) { return content }
        guard let index = annotator.pageIndex(focus) else { return nil }
        if upstream, let before = pageContent(index - 1), before.shows(focus) { return before }
        return pageContent(index)
    }

    private func page(holding focus: EPUBTextPosition, upstream: Bool) -> EPUBPageView? {
        content(holding: focus, upstream: upstream).flatMap(view(of:))
    }

    /// The page before or after one, in the book's order; nil past its ends
    /// or while that page's chapter is still being laid out.
    private func neighbor(of content: EPUBPageContent, forward: Bool) -> EPUBPageView? {
        pageContent(content.page + (forward ? 1 : -1)).flatMap(view(of:))
    }

    private func view(of content: EPUBPageContent) -> EPUBPageView? {
        guard content.range != nil else { return nil }
        return pages.first { $0.content?.page == content.page } ?? EPUBPageView.detached(showing: content)
    }
}
