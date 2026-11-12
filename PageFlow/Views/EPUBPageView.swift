//
//  EPUBPageView.swift
//  PageFlow
//
//  One EPUB page drawn as a PDF-style sheet: paper, a running header with the
//  chapter title, a page number footer, and selectable TextKit 1 text with the
//  reader's highlights and Find's matches painted under it. Every layout
//  (continuous stack, single page, spread) and the rail thumbnails use it, at
//  the book's page size (`EPUBPageGeometry`).
//

import AppKit
import EPUBKit

/// What one page shows. `text`/`range` are nil while its chapter is still
/// being styled or paginated; the page then draws as blank paper.
struct EPUBPageContent {
    var text: NSAttributedString?
    var range: NSRange?
    var header: String
    var footer: String
    /// The colours the page is drawn in.
    var palette: EPUBPagePalette
    /// The current Find match on this page, in the page's own character offsets.
    var findMatch: NSRange?
    /// Every other Find match on this page.
    var matches: [NSRange] = []
    /// The Find jump the match came from: each is shown once, so a page
    /// redrawn later doesn't take the reader's own selection back.
    var findGeneration = 0
    /// The page size the text was paginated for.
    var geometry = EPUBPageGeometry.standard
    /// The reader's font family; the header and footer follow it.
    var family = EPUBFontFamily.system
    /// The page's index in the book, and the chapter its text comes from.
    var page = 0
    var chapter: Int?
    /// The reader's highlights on this page, in the page's own offsets.
    var highlights: [EPUBPageHighlight] = []
    /// The book's selection and highlights, which the page paints and edits;
    /// nil for pages drawn only as pictures (thumbnails).
    weak var annotator: EPUBHighlights?
    /// The book's Read Aloud, whose spoken words the page paints.
    weak var readAloud: EPUBReadAloud?
    /// A fixed-layout chapter's placed page, drawn in place of flowing text.
    var fixedPage: EPUBFixedPage?
    /// The book, for the page menu's zoom, layout and page commands; nil for
    /// pages drawn only as pictures.
    weak var document: EPUBContent?

    /// Whether a page showing `other` already draws all of this. Selections and
    /// spoken words repaint on their own notification.
    func drawsTheSame(as other: EPUBPageContent?) -> Bool {
        guard let other else { return false }
        return text === other.text && range == other.range && header == other.header && footer == other.footer
            && palette == other.palette && findMatch == other.findMatch && matches == other.matches
            && findGeneration == other.findGeneration && geometry == other.geometry && family == other.family
            && page == other.page && chapter == other.chapter && highlights == other.highlights
            && (fixedPage == nil) == (other.fixedPage == nil)
    }

    /// The running header, left off a chapter's first page, where the
    /// chapter's own heading already sits.
    var displayedHeader: String {
        range?.location == 0 ? "" : header
    }

    /// Laid out in vertical columns.
    var isVertical: Bool { text.map(EPUBWriting.isVertical) ?? false }

    /// A selection on this page in its chapter's offsets.
    func chapterSelection(_ local: NSRange) -> EPUBTextSelection? {
        guard let chapter, let range, local.length > 0, local.location < range.length else { return nil }
        let length = min(local.length, range.length - local.location)
        return EPUBTextSelection(chapter: chapter,
                                 range: NSRange(location: range.location + local.location, length: length))
    }

    /// The part of a chapter range this page shows, in the page's offsets.
    static func localRange(of chapterRange: NSRange, onPageShowing pageRange: NSRange) -> NSRange? {
        guard let shown = chapterRange.intersection(pageRange), shown.length > 0 else { return nil }
        return NSRange(location: shown.location - pageRange.location, length: shown.length)
    }
}

/// A highlight as one page draws it.
struct EPUBPageHighlight: Equatable {
    let id: UUID
    /// In the page's own offsets: the part of the highlight on this page.
    let range: NSRange
    let color: NSColor
    var style: EPUBHighlightStyle = .tint
    let hasNote: Bool
    /// Whether the highlight starts on this page: its note marker sits there.
    let startsHere: Bool

    /// The highlights of `chapter` that `pageRange` shows.
    static func onPage(_ highlights: [EPUBHighlight], chapter: Int, pageRange: NSRange) -> [EPUBPageHighlight] {
        highlights.compactMap { highlight in
            guard highlight.chapterIndex == chapter,
                  let local = EPUBPageContent.localRange(of: highlight.range, onPageShowing: pageRange) else { return nil }
            return EPUBPageHighlight(id: highlight.id, range: local, color: highlight.nsColor,
                                     style: highlight.style, hasNote: highlight.isNote,
                                     startsHere: NSLocationInRange(highlight.range.location, pageRange))
        }
    }
}

final class EPUBPageView: NSView, NSTextViewDelegate {
    let textView = EPUBPageTextView.makeTextKit1()
    private var shownText: ObjectIdentifier?
    private var shownRange: NSRange?
    private(set) var content: EPUBPageContent?
    private var shownFindMatch: (generation: Int, range: NSRange)?
    private var geometry = EPUBPageGeometry.standard
    var linkHandler: EPUBLinkHandler?
    /// The footnote shown from a link on this page.
    private var footnotePopover: NSPopover?
    /// The surface's reading keys; returns whether it used the key.
    var keyHandler: ((NSEvent) -> Bool)? {
        get { textView.keyHandler }
        set { textView.keyHandler = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: EPUBPageGeometry.standard.pageSize))
        textView.delegate = self
        textView.clickHandler = { [weak self] index in self?.clicked(characterAt: index) ?? false }
        addSubview(textView)
        NotificationCenter.default.addObserver(self, selector: #selector(marksChanged(_:)),
                                               name: .epubPageMarksDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// A note's margin dot opens its note.
    override func mouseDown(with event: NSEvent) {
        if openNoteMarker(atWindowPoint: event.locationInWindow) { return }
        super.mouseDown(with: event)
    }

    /// Opens the note whose margin dot is at a window point, if one is.
    func openNoteMarker(atWindowPoint windowPoint: NSPoint) -> Bool {
        let point = convert(windowPoint, from: nil)
        guard let content, content.annotator != nil,
              let marker = noteMarkers(content).first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(point) }) else {
            return false
        }
        content.annotator?.selectNote(marker.id)
        return true
    }

    #if DEBUG
    /// Times a page was given something new to draw (CountBudgetTests).
    static var debugRedraws = 0
    #endif

    func configure(_ content: EPUBPageContent) {
        // Native overlays and attachment fallbacks share the stored text's
        // committed palette, even while the surrounding chrome changes.
        appearance = NSAppearance(named: content.palette == .dark ? .darkAqua : .aqua)
        // A chapter landing elsewhere in the book reloads the pages in view.
        if content.drawsTheSame(as: self.content) {
            self.content = content
            return
        }
        #if DEBUG
        Self.debugRedraws += 1
        #endif
        let textID = content.text.map(ObjectIdentifier.init)
        let textChanges = textID != shownText || content.range != shownRange
        // The book's selection is kept in chapter offsets and painted; only
        // a native one (a page drawn without a book) goes with its text.
        if textChanges {
            clearSelection()
        }
        self.content = content
        // VoiceOver hears the running header and number drawn on the paper.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(content.header.isEmpty ? "Page \(content.footer)" : "Page \(content.footer), \(content.header)")
        let turned = textView.setVertical(content.isVertical)
        if turned || content.geometry != geometry {
            geometry = content.geometry
            textView.textContainer?.size = geometry.lineSize(vertical: content.isVertical)
        }
        if turned { placeTextView() }
        if textChanges {
            if let text = content.text, let range = content.range, NSMaxRange(range) <= text.length {
                textView.textStorage?.setAttributedString(text.attributedSubstring(from: range))
                markFigures()
            } else {
                textView.textStorage?.setAttributedString(NSAttributedString())
            }
            shownText = textID
            shownRange = content.range
            shownFindMatch = nil
            closeFootnote()
            textView.fixedLayer = content.fixedPage.map(EPUBFixedTextLayer.init)
        }
        paint(content)
        setAccessibilityValue(highlightsDescription)
        showFindMatch(content.findMatch.map { (content.findGeneration, $0) })
        needsDisplay = true
        needsLayout = true
    }

    /// A figure isn't text to place a caret in: the pointer over it is an
    /// arrow, unless it is a link. A formula selects as words, so it isn't one.
    private func markFigures() {
        guard let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, storage.attribute(.link, at: range.location, effectiveRange: nil) == nil,
                  storage.attribute(EPUBMath.textAttribute, at: range.location, effectiveRange: nil) == nil else { return }
            storage.addAttribute(.cursor, value: NSCursor.arrow, range: range)
        }
    }

    /// Highlights, Find matches, Read Aloud's words and the book's selection
    /// are painted, so a selection can run over several pages. Each paints
    /// over the one before; Find's colours are every document type's.
    func paint(_ content: EPUBPageContent) {
        guard let layout = textView.layoutManager else { return }
        let length = textView.string.utf16.count
        for key in Self.highlightPaintKeys {
            layout.removeTemporaryAttribute(key, forCharacterRange: NSRange(location: 0, length: length))
        }
        let string = textView.string as NSString
        for highlight in content.highlights where NSMaxRange(highlight.range) <= length {
            let attributes = Self.paintAttributes(highlight, on: content.palette)
            for run in Self.runsWithoutLineBreaks(highlight.range, in: string) {
                layout.addTemporaryAttributes(attributes, forCharacterRange: run)
            }
        }
        for match in content.matches where NSMaxRange(match) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.searchOtherResults, forCharacterRange: match)
        }
        if let current = content.findMatch, NSMaxRange(current) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.searchCurrentResult,
                                         forCharacterRange: current)
        }
        // The voice paints last, so a selection being read shows it.
        // The current match, selected as a PDF's is, keeps Find's colour.
        if let selected = content.localRange(of: content.annotator?.selection), selected != content.findMatch,
           NSMaxRange(selected) <= length {
            layout.addTemporaryAttribute(.backgroundColor, value: Self.selectionColor(on: content.palette),
                                         forCharacterRange: selected)
        }
        if let reader = content.readAloud, let spoken = reader.spoken, spoken.chapter == content.chapter,
           let range = content.range {
            // The sentence faintly, the word being said strongly.
            if let sentence = EPUBPageContent.localRange(of: spoken.sentence, onPageShowing: range),
               NSMaxRange(sentence) <= length {
                for run in Self.runsWithoutLineBreaks(sentence, in: string) {
                    layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.epubSpokenSentence,
                                                 forCharacterRange: run)
                }
            }
            if let word = spoken.word.flatMap({ EPUBPageContent.localRange(of: $0, onPageShowing: range) }),
               NSMaxRange(word) <= length {
                layout.addTemporaryAttribute(.backgroundColor, value: DesignTokens.epubSpokenWord,
                                             forCharacterRange: word)
            }
        }
        if let fixed = textView.fixedLayer {
            fixed.copyPaint(from: layout, keys: Self.highlightPaintKeys)
            textView.needsDisplay = true
        }
    }

    /// The book's selection or spoken words changed: repaint, if this page
    /// shows that book.
    @objc private func marksChanged(_ notification: Notification) {
        guard let content, let source = notification.object as AnyObject?,
              source === content.annotator || source === content.readAloud else { return }
        paint(content)
        if source === content.annotator, content.localRange(of: content.annotator?.selection) != nil {
            Self.announceSelectionChange(on: textView)
        }
    }

    /// The newest one waiting: a drag moves the selection every step, on every
    /// page showing it, and VoiceOver hears once it pauses.
    private(set) static var pendingSelectionAnnouncement: DispatchWorkItem?

    private static func announceSelectionChange(on textView: NSTextView) {
        pendingSelectionAnnouncement?.cancel()
        let announcement = DispatchWorkItem { [weak textView] in
            guard let textView, NSWorkspace.shared.isVoiceOverEnabled else { return }
            NSAccessibility.post(element: textView, notification: .selectedTextChanged)
        }
        pendingSelectionAnnouncement = announcement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: announcement)
    }

    /// A range split around its paragraph breaks, each part without the
    /// spaces and tabs at its ends: a painted break would fill the rest of
    /// its line out to the page's edge, and painted indent or trailing space
    /// would run the paint past the words.
    static func runsWithoutLineBreaks(_ range: NSRange, in string: NSString) -> [NSRange] {
        let blank = CharacterSet.whitespaces
        func isBlank(_ index: Int) -> Bool { Unicode.Scalar(string.character(at: index)).map(blank.contains) ?? false }
        var runs: [NSRange] = []
        func add(_ start: Int, _ end: Int) {
            var (start, end) = (start, end)
            while start < end, isBlank(start) { start += 1 }
            while end > start, isBlank(end - 1) { end -= 1 }
            if end > start { runs.append(NSRange(location: start, length: end - start)) }
        }
        var start = range.location
        for index in range.location..<NSMaxRange(range) {
            let character = string.character(at: index)
            guard character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x2028 else { continue }
            add(start, index)
            start = index + 1
        }
        add(start, NSMaxRange(range))
        return runs
    }

    /// The find bounce plays once per Find jump, not on every redraw.
    private func showFindMatch(_ wanted: (generation: Int, range: NSRange)?) {
        guard wanted?.generation != shownFindMatch?.generation || wanted?.range != shownFindMatch?.range else { return }
        shownFindMatch = wanted
        guard let range = wanted?.range, NSMaxRange(range) <= textView.string.utf16.count else { return }
        textView.showFindIndicator(for: range)
    }

    /// Removes the page, first handing the keyboard to `surface` if the
    /// page's text had it, so reading keys keep working after it scrolls away.
    func remove(handingFocusTo surface: NSView) {
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) {
            window.makeFirstResponder(surface)
        }
        closeFootnote()
        clearSelection()
        removeFromSuperview()
    }

    func clearSelection() {
        guard textView.selectedRange().length > 0 else { return }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func layout() {
        super.layout()
        placeTextView()
    }

    func placeTextView() {
        if let fixed = textView.fixedLayer {
            textView.frame = fixed.page.frame(in: geometry.pageSize)
            return
        }
        let insets = geometry.textInsets
        textView.frame = NSRect(origin: CGPoint(x: insets.left, y: insets.top), size: geometry.textSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        EPUBTextStyling.themeBackgroundColor(for: content.palette).setFill()
        bounds.fill()
        if let fixed = textView.fixedLayer?.page {
            let frame = fixed.frame(in: geometry.pageSize)
            fixed.draw(in: frame, pixelsPerPoint: convert(frame, to: nil).width * drawingPixelsPerPoint / fixed.size.width)
            drawNoteMarkers(content)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.chromeFont(for: content.family),
            .foregroundColor: EPUBTextStyling.themeTextColor(for: content.palette).withAlphaComponent(0.55)
        ]
        let margins = geometry.margins.insets
        let width = bounds.width - margins.left - margins.right
        drawCentered(content.displayedHeader, in: NSRect(x: margins.left, y: 28, width: width, height: 14), attributes)
        drawCentered(content.footer, in: NSRect(x: margins.left, y: bounds.height - 42, width: width, height: 14),
                     attributes)
        drawNoteMarkers(content)
    }

    /// Device pixels per view point for a fixed page's images: the screen's, or
    /// about 300 dpi on paper.
    private var drawingPixelsPerPoint: CGFloat {
        if let window { return window.backingScaleFactor }
        return NSGraphicsContext.current?.isDrawingToScreen == false ? 4 : 2
    }

    /// The header and footer face: small, in the reader's family.
    static func chromeFont(for family: EPUBFontFamily) -> NSFont {
        let system = NSFont.systemFont(ofSize: 10, weight: .medium)
        guard family == .serif, let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: serif, size: 10) ?? system
    }

    private func drawCentered(_ string: String, in rect: NSRect, _ attributes: [NSAttributedString.Key: Any]) {
        guard !string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        var attributes = attributes
        attributes[.paragraphStyle] = style
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let linkHandler else { return false }
        switch linkHandler(url) {
        case .unhandled:
            return false
        case .followed:
            return true
        case .footnote(let resolving):
            // In the page's coordinates: a vertical text view's are turned.
            let anchor = textView.convert(linkRect(at: charIndex), to: self)
            let shown = (shownText, shownRange)
            Task { [weak self] in
                // The page may have turned while the note's chapter was styled.
                guard let note = await resolving.value, let self, window != nil,
                      shownText == shown.0, shownRange == shown.1 else { return }
                closeFootnote()
                footnotePopover = EPUBFootnoteViewController.show(note, relativeTo: anchor, of: self,
                                                                  linkHandler: self.linkHandler)
            }
            return true
        }
    }

    private func closeFootnote() {
        footnotePopover?.close()
        footnotePopover = nil
    }

    /// The clicked link's rect in the text view: the whole link when it
    /// sits on one line, else the clicked character's line.
    private func linkRect(at index: Int) -> NSRect {
        if textView.fixedLayer != nil { return textView.fixedLineRect(at: index) ?? .zero }
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let storage = textView.textStorage, index < storage.length else { return .zero }
        var linkRange = NSRange()
        _ = storage.attribute(.link, at: index, effectiveRange: &linkRange)
        let clicked = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                             actualCharacterRange: nil),
            in: container)
        let whole = layout.boundingRect(
            forGlyphRange: layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil), in: container)
        let rect = whole.height < clicked.height * 1.5 ? whole : clicked
        return rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    /// A page off screen, laid out at its size: it shows what `content` does
    /// but edits nothing, for a picture of it or to read its layout.
    static func detached(showing content: EPUBPageContent) -> EPUBPageView {
        let page = EPUBPageView(frame: .zero)
        page.setFrameSize(content.geometry.pageSize)
        var content = content
        content.annotator = nil
        content.document = nil
        page.configure(content)
        page.layoutSubtreeIfNeeded()
        return page
    }

    /// A page for paper: printing leaves out a layout manager's temporary
    /// attributes, so its highlights go into its own copy of the text.
    static func forPrinting(showing content: EPUBPageContent) -> EPUBPageView {
        let page = detached(showing: content)
        page.textView.layoutManager?.bakeTemporaryAttributes()
        page.textView.fixedLayer?.bakePaint()
        return page
    }

    /// A small image of this page for the rail's preview grid.
    /// Rendered once at page size, then reduced to a small bitmap that is
    /// all the cache keeps (2× pixels for Retina).
    static func thumbnail(of content: EPUBPageContent, width: CGFloat) -> NSImage {
        let page = detached(showing: content)
        let pageSize = content.geometry.pageSize
        let size = NSSize(width: width, height: (pageSize.height * width / pageSize.width).rounded())
        guard let full = page.bitmapImageRepForCachingDisplay(in: page.bounds),
              let small = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        // Points before the context exists, so it draws at 2× pixels.
        small.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: small) else { return NSImage(size: size) }
        // Small image decodes: a thumbnail never evicts the reader's images.
        EPUBImageRendering.thumbnails { page.cacheDisplay(in: page.bounds, to: full) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        full.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(small)
        return image
    }
}

extension NSLayoutManager {
    /// Makes the temporary attributes painted on the text part of the text.
    func bakeTemporaryAttributes() {
        guard let storage = textStorage else { return }
        var index = 0
        while index < storage.length {
            var run = NSRange()
            let attributes = temporaryAttributes(atCharacterIndex: index, effectiveRange: &run)
            if !attributes.isEmpty { storage.addAttributes(attributes, range: run) }
            index = NSMaxRange(run)
        }
    }
}

/// A read-only page slice that hands reading keys (turning, scrolling) to its
/// surface while keeping native selection and Copy.
final class EPUBPageTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    /// A plain click on a character (no selection made); returns whether it was used.
    var clickHandler: ((Int) -> Bool)?
    /// A hand-built TextKit 1 stack is rooted in its storage; keep it alive.
    private var ownedStorage: NSTextStorage?
    /// A fixed-layout page's text, which replaces this view's own layout for
    /// drawing and hit testing. Its storage still holds the chapter's text.
    var fixedLayer: EPUBFixedTextLayer? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// View points per page unit on a fixed page.
    private var fixedScale: CGFloat {
        guard let size = fixedLayer?.page.size.width, size > 0 else { return 1 }
        return bounds.width / size
    }

    /// A line of a fixed page, in this view's coordinates.
    func fixedLineRect(at index: Int) -> NSRect? {
        guard let line = fixedLayer?.lineRect(at: index) else { return nil }
        let scale = fixedScale
        return NSRect(x: line.minX * scale, y: line.minY * scale, width: line.width * scale, height: line.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fixedLayer else { return super.draw(dirtyRect) }
        fixedLayer.draw(scale: fixedScale)
    }

    /// Read from this page's own layout, never `super`: AppKit's answer goes through
    /// the window, to whichever text view is under the point. For a page being torn
    /// down over a note that is the note's editor, and asking for its layout manager
    /// drops that editor to TextKit 1 for good.
    override func characterIndexForInsertion(at point: NSPoint) -> Int {
        if let fixedLayer {
            let scale = fixedScale
            return fixedLayer.insertionIndex(at: CGPoint(x: point.x / scale, y: point.y / scale))
        }
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return 0 }
        let origin = textContainerOrigin
        // Between insertion points, in the reading order of the run: a fraction through a
        // glyph runs the other way in right-to-left text.
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard fraction >= 0.5, index < storage.length else { return index }
        let string = storage.string as NSString
        // Past a line's last glyph the insertion point stays on that line, before its break.
        return string.character(at: index) == 0x0A ? index : NSMaxRange(string.rangeOfComposedCharacterSequence(at: index))
    }

    /// Over a fixed page, the text cursor shows only where there is text.
    override func resetCursorRects() {
        guard let fixedLayer else { return super.resetCursorRects() }
        let scale = fixedScale
        addCursorRect(bounds, cursor: .arrow)
        func scaled(_ rect: CGRect) -> NSRect {
            NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        for rect in fixedLayer.textRects { addCursorRect(scaled(rect), cursor: .iBeam) }
        for rect in fixedLayer.linkRects { addCursorRect(scaled(rect), cursor: .pointingHand) }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard fixedLayer == nil else { return }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard fixedLayer == nil else { return }
        super.mouseMoved(with: event)
    }

    /// Paint alone marks the match on a fixed page: the system's bounce reads
    /// this view's own layout, which isn't what's drawn.
    override func showFindIndicator(for charRange: NSRange) {
        guard fixedLayer == nil else { return }
        super.showFindIndicator(for: charRange)
    }

    // The book's selection dragged out: its text, a copy.
    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func rightMouseDown(with event: NSEvent) {
        // The system's would select a word from this view's own layout first.
        guard fixedLayer != nil, let menu = menu(for: event) else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let page = superview as? EPUBPageView else { return super.menu(for: event) }
        page.selectForContextClick(at: event.locationInWindow)
        holdMenuSelection(of: page)
        guard fixedLayer != nil else { return super.menu(for: event) }
        // The delegate's items take the character under the pointer as drawn,
        // which this view's own layout doesn't know: the page adds them itself.
        let delegate = delegate
        self.delegate = nil
        defer { self.delegate = delegate }
        return page.fixedPageMenu(for: event, systemMenu: super.menu(for: event))
    }

    // MARK: The system's menu items and Services

    /// Whether this view holds the book's selection for a context menu.
    private(set) var isHoldingMenuSelection = false
    private var menuSelectionEnd: DispatchWorkItem?

    /// Look Up, Translate and Share read this view's own selection, which a book
    /// keeps collapsed: while the menu is open it holds this page's part of the
    /// book's. It draws nothing (`selectedTextAttributes`): the paint still shows.
    private func holdMenuSelection(of page: EPUBPageView) {
        menuSelectionEnd?.cancel()
        guard let content = page.content, let selected = content.localRange(of: content.annotator?.selection),
              NSMaxRange(selected) <= string.utf16.count else { return endMenuSelection() }
        isHoldingMenuSelection = true
        setSelectedRange(selected)
    }

    func endMenuSelection() {
        menuSelectionEnd?.cancel()
        guard isHoldingMenuSelection else { return }
        isHoldingMenuSelection = false
        setSelectedRange(NSRange(location: NSMaxRange(selectedRange()), length: 0))
    }

    /// AppKit closes the menu before sending the chosen item's action, which
    /// still has to find the selection.
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        let end = DispatchWorkItem { [weak self] in self?.endMenuSelection() }
        menuSelectionEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: end)
    }

    private var bookSelectedText: NSAttributedString? {
        (superview as? EPUBPageView)?.content?.annotator?.selectedText
    }

    // VoiceOver reads the book's selection, this view's own staying collapsed:
    // this page's part of it, a range and text in this view's value.

    private var accessibilitySelection: NSRange? {
        guard let content = (superview as? EPUBPageView)?.content, content.annotator != nil else { return nil }
        let selected = content.localRange(of: content.annotator?.selection)
        return selected.flatMap { NSMaxRange($0) <= string.utf16.count ? $0 : nil } ?? NSRange(location: selectedRange().location, length: 0)
    }

    override func accessibilitySelectedText() -> String? {
        guard let selected = accessibilitySelection else { return super.accessibilitySelectedText() }
        return (string as NSString).substring(with: selected)
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        accessibilitySelection ?? super.accessibilitySelectedTextRange()
    }

    // Apple's text Services use both the plain-text UTI and the legacy pasteboard name.
    static let serviceTextTypes: [NSPasteboard.PasteboardType] = [
        .string, .init("public.plain-text"), .init("NSStringPboardType")
    ]

    /// Services take the book's whole selection, from this menu and the app's.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        guard let page = superview as? EPUBPageView, page.content?.annotator != nil else {
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }
        return page.servicesRequestor(sending: sendType, receiving: returnType)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let supported = types.filter(Self.serviceTextTypes.contains)
        guard !supported.isEmpty, let text = bookSelectedText else {
            return super.writeSelection(to: pboard, types: types)
        }
        pboard.declareTypes(supported, owner: nil)
        var wroteText = false
        for type in supported {
            if pboard.setString(text.string, forType: type) { wroteText = true }
        }
        return wroteText
    }

    static func makeTextKit1() -> EPUBPageTextView {
        let storage = NSTextStorage()
        let layout = EPUBPageLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: EPUBPageGeometry.standard.textSize)
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = EPUBPageTextView(frame: NSRect(origin: .zero, size: EPUBPageGeometry.standard.textSize),
                                    textContainer: container)
        view.ownedStorage = storage
        return view
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        // Links keep the text's own themed colour and faint underline; only
        // the cursor marks them. NSTextView's default would paint them blue.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        // A book's selection is painted; the native one is only ever held for a menu.
        selectedTextAttributes = [.backgroundColor: NSColor.clear]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        endMenuSelection()
        // A fixed page's note dots sit over this view, not in a margin beside it.
        if fixedLayer != nil, let page = superview as? EPUBPageView,
           page.openNoteMarker(atWindowPoint: event.locationInWindow) { return }
        // A book's pages select together, across pages (EPUBPageView+Selection).
        if let page = superview as? EPUBPageView, page.trackSelection(from: event) { return }
        // Tracks the drag until the button comes up.
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0, let clickHandler,
              let index = characterIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        _ = clickHandler(index)
    }

    /// Turns the text for a vertical or horizontal page; returns whether it
    /// changed. A vertical text view's bounds are turned a quarter turn, so
    /// its coordinates, and every layout rect, stay along and across lines.
    func setVertical(_ vertical: Bool) -> Bool {
        let wanted: NSLayoutManager.TextLayoutOrientation = vertical ? .vertical : .horizontal
        guard layoutOrientation != wanted else { return false }
        setLayoutOrientation(wanted)
        return true
    }

    /// The character drawn under a point, if one is.
    func characterIndex(at point: NSPoint) -> Int? {
        if let fixedLayer {
            let scale = fixedScale
            let inPage = CGPoint(x: point.x / scale, y: point.y / scale)
            // Text first, then the image under it, topmost first.
            return fixedLayer.characterIndex(at: inPage)
                ?? fixedLayer.page.layers.last { $0.slot != nil && $0.frame.contains(inPage) }?.slot
        }
        guard let layout = layoutManager, let container = textContainer, !string.isEmpty else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(inContainer) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    override func keyDown(with event: NSEvent) {
        guard keyHandler?(event) != true else { return }
        super.keyDown(with: event)
    }

    // Edit ▸ Speech reads the book aloud, not just this page's slice.
    override func startSpeaking(_ sender: Any?) {
        guard let reader = (superview as? EPUBPageView)?.content?.readAloud else { return super.startSpeaking(sender) }
        reader.start()
    }

    override func stopSpeaking(_ sender: Any?) {
        guard let reader = (superview as? EPUBPageView)?.content?.readAloud else { return super.stopSpeaking(sender) }
        reader.stop()
    }

    // A book's selection runs over several pages: Copy and Select All act on it.
    override func copy(_ sender: Any?) {
        guard let page = superview as? EPUBPageView, page.copySelection() else { return super.copy(sender) }
    }

    override func selectAll(_ sender: Any?) {
        guard let page = superview as? EPUBPageView, page.selectAllText() else { return super.selectAll(sender) }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let page = superview as? EPUBPageView, page.content?.annotator != nil,
           let valid = EPUBReaderTextCommands.validate(item, pages: [page]) { return valid }
        return super.validateMenuItem(item)
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling and swipes belong to the surface, not the fixed slice.
        nextResponder?.scrollWheel(with: event)
    }
}
