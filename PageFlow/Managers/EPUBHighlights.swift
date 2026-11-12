//
//  EPUBHighlights.swift
//  PageFlow
//
//  A book's highlights and notes, and the reader's text selection they are
//  made from. Pages report their selection here and draw what it holds;
//  menus, the toolbar and the sidebar act on it. `EPUBContent` owns one and
//  saves it in the book's annotations (`EPUBAnnotationStore`).
//

import AppKit
import Observation

@Observable
@MainActor
final class EPUBHighlights {
    /// In reading order.
    private(set) var items: [EPUBHighlight]
    /// Bumps whenever what pages draw changes, so they repaint.
    private(set) var revision = 0
    /// The colour new highlights take: the toolbar's choice, else the first preset.
    var color: String {
        get { chosenColor ?? Self.defaultColor }
        set { chosenColor = newValue }
    }
    /// The colour new underlines take, from the underline presets likewise.
    var underlineColor: String {
        get { chosenUnderlineColor ?? Self.defaultUnderlineColor }
        set { chosenUnderlineColor = newValue }
    }
    /// The reader's choices; until then Settings' first colours, live, as PDF's.
    private var chosenColor: String?
    private var chosenUnderlineColor: String?
    private(set) var selection: EPUBTextSelection?
    /// Where a plain click or the last selection's moving end left the caret,
    /// which no page draws: the keyboard extends a selection from it.
    @ObservationIgnored private(set) var caret: EPUBTextPosition?
    /// The notes panel beside the pages, like PDF's comments panel.
    private(set) var isPanelShown = false
    /// The note the panel has selected, as PDF's has a comment.
    private(set) var selectedNoteID: UUID?
    /// The highlight whose note the panel is editing.
    private(set) var editingID: UUID?
    /// What it was before the editor opened on it.
    private enum EditingOrigin { case note, plainHighlight, newHighlight, firstWord }
    @ObservationIgnored private var editingOrigin = EditingOrigin.note
    /// Bumps whenever the note being edited is another one, or the same one
    /// rewritten by a merge, so the panel's editor shows it afresh.
    private(set) var editingRevision = 0

    /// The chapter text a range covers, for excerpts.
    @ObservationIgnored var excerpt: (_ chapter: Int, _ range: NSRange) -> String = { _, _ in "" }
    /// A chapter's styled text, if at hand: Copy and a selection over a
    /// chapter break need it.
    @ObservationIgnored var chapterText: (_ chapter: Int) -> NSAttributedString? = { _ in nil }
    /// A chapter's length if known without styling it.
    @ObservationIgnored var chapterLength: ((_ chapter: Int) -> Int?)?
    /// Whether a chapter's styled text is in memory, so reading it is quick.
    @ObservationIgnored var isChapterAtHand: (_ chapter: Int) -> Bool = { _ in true }
    /// A large selection as plain text, read off the main thread.
    @ObservationIgnored var plainText: ((EPUBTextSelection) async -> String?)?
    /// Where Copy writes.
    @ObservationIgnored var pasteboard = NSPasteboard.general
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    /// The chapters in the reading flow, first to last: what Select All takes.
    @ObservationIgnored var flowChapters: () -> ClosedRange<Int>? = { nil }
    /// The page showing a place in the book.
    @ObservationIgnored var pageIndex: (EPUBTextPosition) -> Int? = { _ in nil }
    /// Called after every change worth saving.
    @ObservationIgnored var onChange: () -> Void = {}
    /// The tab's Undo stack: every change to the highlights is one step.
    @ObservationIgnored var undoManager: UndoManager?
    // Undo names are PDF's: AnnotationManager's, with its comments' words for notes.

    /// The note whose typing already has its Undo step: a note written in
    /// one go undoes in one step, not a keystroke at a time.
    @ObservationIgnored private var typingNoteID: UUID?

    init(_ items: [EPUBHighlight] = []) {
        self.items = items.sorted(by: EPUBHighlight.inReadingOrder)
    }

    /// About 25 pages (UTF-16 units). The most Copy and a drag read on the main
    /// thread, and a highlight or note takes.
    static let smallSelectionLength = 50_000

    static var defaultColor: String {
        SettingsManager.shared.highlightPresets.first?.hex ?? "#FFFF00"
    }

    static var defaultUnderlineColor: String {
        SettingsManager.shared.underlinePresets.first?.hex ?? "#000000"
    }

    /// A new note's colour, as a new PDF comment's.
    static var defaultNoteColor: String {
        SettingsManager.shared.commentPresets.first?.hex ?? defaultColor
    }

    func highlight(_ id: UUID) -> EPUBHighlight? { items.first { $0.id == id } }

    /// The book's saved highlights, once it has opened; nothing to save or undo.
    func loadSaved(_ saved: [EPUBHighlight]) {
        items = saved.sorted(by: EPUBHighlight.inReadingOrder)
        revision &+= 1
    }

    // MARK: - Selection

    /// Sets the reader's selection (an empty one clears it). Pages showing
    /// the book repaint their part at once.
    func select(_ selection: EPUBTextSelection?) {
        let new = selection?.isEmpty == false ? selection : nil
        // A whole-book selection's end is no place to leave a caret.
        let wholeBook = selection?.isWholeBook == true || (selection == nil && self.selection?.isWholeBook == true)
        caret = wholeBook ? nil : selection?.focus ?? self.selection?.focus ?? caret
        guard new != self.selection else { return }
        self.selection = new
        NotificationCenter.default.post(name: .epubPageMarksDidChange, object: self)
    }

    /// Clears the selection and leaves the caret at `position`.
    func placeCaret(at position: EPUBTextPosition?) {
        select(nil)
        caret = position
    }

    /// ⌘A: the whole book's reading flow, as it takes a whole PDF or note,
    /// painted on every page. Styles nothing: its end is the last chapter's,
    /// however long that turns out. `chapter` is the page's, for a book with
    /// no flow known (a page shown alone).
    func selectAll(from chapter: Int) {
        let flow = flowChapters() ?? chapter...chapter
        select(.wholeBook(first: flow.lowerBound, last: flow.upperBound))
        caret = nil
    }

    /// How long the selection is, from chapters' known lengths; nil if one
    /// isn't known. Styles nothing, so it costs nothing however large the selection.
    var selectionLength: Int? {
        guard let selection else { return 0 }
        let (start, end) = (selection.start, selection.end)
        if start.chapter == end.chapter, !selection.isWholeBook { return end.offset - start.offset }
        var total = 0
        for chapter in start.chapter...end.chapter {
            guard let length = chapterLength.map({ $0(chapter) }) ?? chapterText(chapter)?.length else { return nil }
            let lower = chapter == start.chapter ? start.offset : 0
            let upper = chapter == end.chapter ? min(end.offset, length) : length
            total += max(0, upper - lower)
        }
        return total
    }

    /// Whether the selection can take a highlight or note. A whole book's or
    /// one past the size can't: the mark would merge every mark it crosses.
    var canAnnotateSelection: Bool {
        guard let selection, !selection.isWholeBook else { return false }
        return isSmallSelection
    }

    private var isSmallSelection: Bool {
        selectionLength.map { $0 <= Self.smallSelectionLength } ?? false
    }

    /// Whether the selection can be read here, in rich text: small, and in
    /// memory. Otherwise Copy runs off the main thread, in plain text.
    private var isSelectionAtHand: Bool {
        guard isSmallSelection, let selection else { return false }
        return (selection.start.chapter...selection.end.chapter).allSatisfy(isChapterAtHand)
    }

    /// The selection's moving end, or the caret with nothing selected.
    var movingEnd: EPUBTextPosition? {
        guard var focus = selection?.focus ?? caret else { return nil }
        if focus.offset == .max { focus.offset = chapterText(focus.chapter)?.length ?? 0 }
        return focus
    }

    /// Moves the selection's moving end; where it began stays.
    func extendSelection(to focus: EPUBTextPosition) {
        guard let anchor = selection?.anchor ?? caret else { return }
        select(EPUBTextSelection(anchor: anchor, focus: focus))
    }

    /// Shift-←/→: the selection's moving end steps one character, staying
    /// in its chapter.
    func extendSelection(forward: Bool) {
        guard let focus = movingEnd, let text = chapterText(focus.chapter)?.string as NSString? else { return }
        var moved = focus
        if forward, focus.offset < text.length {
            moved.offset = NSMaxRange(text.rangeOfComposedCharacterSequence(at: focus.offset))
        } else if !forward, focus.offset > 0 {
            moved.offset = text.rangeOfComposedCharacterSequence(at: focus.offset - 1).location
        }
        extendSelection(to: moved)
    }

    /// ⌥⇧←/→: to the end of the next word, or the start of the one before.
    func extendSelectionAWord(forward: Bool) {
        guard let focus = movingEnd, let text = chapterText(focus.chapter),
              forward ? focus.offset < text.length : focus.offset > 0 else { return }
        var moved = focus
        moved.offset = text.nextWord(from: focus.offset, forward: forward)
        extendSelection(to: moved)
    }

    /// ⌥⇧↑/↓: to the near end of the paragraph, or, already there, the same
    /// end of the next one along.
    func extendSelectionAParagraph(forward: Bool) {
        guard let focus = movingEnd, let text = chapterText(focus.chapter)?.string as NSString? else { return }
        func paragraph(at offset: Int) -> (start: Int, contentsEnd: Int, end: Int) {
            var start = 0, end = 0, contentsEnd = 0
            text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            return (start, contentsEnd, end)
        }
        var moved = focus
        let here = paragraph(at: focus.offset)
        if forward {
            moved.offset = here.contentsEnd == focus.offset && here.end < text.length ? paragraph(at: here.end).contentsEnd : here.contentsEnd
        } else {
            moved.offset = here.start == focus.offset && focus.offset > 0 ? paragraph(at: focus.offset - 1).start : here.start
        }
        extendSelection(to: moved)
    }

    /// ⌘⇧↑/↓, ⇧Home/End: to the chapter's start or end.
    func extendSelectionToChapterEnd(forward: Bool) {
        guard let focus = movingEnd, let length = chapterText(focus.chapter)?.length else { return }
        extendSelection(to: EPUBTextPosition(chapter: focus.chapter, offset: forward ? length : 0))
    }

    /// The selected text, in reading order, when it is small enough to read
    /// here: a page's own part serves anything larger, as Copy does off the
    /// main thread.
    var selectedText: NSAttributedString? {
        guard let selection, isSelectionAtHand else { return nil }
        let text = selection.text(chapterText: chapterText)
        return text.length > 0 ? text : nil
    }

    /// Copy: all of the selection, as plain text and as rich text without
    /// the page theme's colours (so it pastes readably anywhere). A large one
    /// reads off the main thread and arrives as plain text: the pasteboard is
    /// emptied at once, so nothing older pastes, unless something else has
    /// taken the pasteboard by the time it is ready.
    @discardableResult
    func copySelection(to target: NSPasteboard? = nil) -> Bool {
        let pasteboard = target ?? self.pasteboard
        guard let selection else { return false }
        guard isSelectionAtHand || plainText == nil else {
            pasteboard.clearContents()
            let change = pasteboard.changeCount
            copyTask?.cancel()
            copyTask = Task { [plainText] in
                guard let text = await plainText?(selection), !Task.isCancelled,
                      pasteboard.changeCount == change else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            return true
        }
        guard let rich = textForPasting else { return false }
        pasteboard.clearContents()
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(rich.string, forType: .string)
        return true
    }

    /// The selected text as Copy and a drag give it: without the page theme's
    /// colours, so it reads anywhere.
    var textForPasting: NSAttributedString? {
        guard let text = selectedText else { return nil }
        let rich = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: rich.length)
        for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .link, .attachment] {
            rich.removeAttribute(key, range: whole)
        }
        return rich
    }

    /// The highlight the selection lies in, if it lies wholly in one.
    var highlightAtSelection: EPUBHighlight? {
        guard selection?.isWholeBook == false, let chapter = selection?.chapter, let range = selection?.range else { return nil }
        return items.first {
            $0.chapterIndex == chapter && NSLocationInRange(range.location, $0.range)
                && NSMaxRange(range) <= NSMaxRange($0.range)
        }
    }

    // MARK: - Highlighting

    /// Highlights the selection in `color` (or the current colour) and
    /// `style`, and clears it. A selection over a chapter break is one highlight
    /// per chapter, made and undone together; the first one's id is returned.
    @discardableResult
    func highlightSelection(color: String? = nil, style: EPUBHighlightStyle = .tint) -> UUID? {
        guard let selection, canAnnotateSelection else { return nil }
        let id = add(ranges(of: selection), color: color ?? (style == .underline ? underlineColor : self.color), style: style)
        select(nil)
        return id
    }

    private func ranges(of selection: EPUBTextSelection) -> [(chapter: Int, range: NSRange)] {
        selection.chapterRanges { [chapterText] chapter in
            // The ends' own chapters need no length: the selection bounds them.
            chapter == selection.end.chapter ? selection.end.offset
                : chapterLength.map { $0(chapter) } ?? chapterText(chapter)?.length
        }
    }

    /// Highlights a range; overlapping highlights merge into it.
    @discardableResult
    func add(chapter: Int, range: NSRange, color: String, style: EPUBHighlightStyle = .tint) -> UUID? {
        add([(chapter, range)], color: color, style: style)
    }

    /// Highlights ranges in one Undo step; returns the first one's id.
    @discardableResult
    func add(_ parts: [(chapter: Int, range: NSRange)], color: String, style: EPUBHighlightStyle = .tint,
             undoName: String? = nil) -> UUID? {
        let excerpt = excerpt
        let editing = editingID.flatMap(highlight)
        let before = items
        var first: UUID?
        for part in parts {
            let id = items.addHighlight(chapter: part.chapter, range: part.range, color: color, style: style,
                                        excerpt: { excerpt(part.chapter, $0) })
            first = first ?? id
        }
        guard let id = first else { return nil }
        // Undo brings back the highlights a merge joined, as they were.
        recordUndo(undoName ?? (style == .underline ? "Add Underline" : "Add Highlight"), restoring: before)
        // The note being edited merged into the new highlight: edit that one,
        // whose note now holds what was typed so far.
        if let editing, highlight(editing.id) != editing {
            let merged = items.first {
                $0.chapterIndex == editing.chapterIndex && NSIntersectionRange($0.range, editing.range).length > 0
            }
            setEditing(merged?.id ?? id)
        }
        changed()
        return id
    }

    /// Add Note: on the highlight the selection lies in, or on a new highlight
    /// of the selection, opened in the Notes panel.
    @discardableResult
    func addNoteToSelection() -> UUID? {
        addNoteToSelection(madeForIt: .newHighlight)
    }

    /// Add Note with nothing selected: on `word`. Left empty, it leaves no mark.
    @discardableResult
    func addNote(onWord word: EPUBTextSelection) -> UUID? {
        select(word)
        return addNoteToSelection(madeForIt: .firstWord)
    }

    private func addNoteToSelection(madeForIt origin: EditingOrigin) -> UUID? {
        guard let selection, canAnnotateSelection else { return nil }
        if let existing = highlightAtSelection {
            select(nil)
            edit(existing.id)
            return existing.id
        }
        // A selection running past a highlight merges with it and keeps its look.
        let parts = ranges(of: selection)
        let touched = items.first { item in
            parts.contains { $0.chapter == item.chapterIndex && NSIntersectionRange(item.range, $0.range).length > 0 }
        }
        guard let id = add(parts, color: touched?.color ?? Self.defaultNoteColor, style: touched?.style ?? .tint,
                           undoName: "Add Note") else { return nil }
        select(nil)
        // Merged into an earlier mark, it is that mark's note.
        edit(id, opened: touched == nil ? origin : highlight(id)?.isNote == true ? .note : .plainHighlight)
        return id
    }

    func setColor(_ color: String, of id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              !SettingsManager.ColorPreset.colorsMatch(items[index].color, color) else { return }
        recordUndo(items[index].isNote ? "Change Note Color" : "Change Annotation Color", restoring: items)
        items[index].color = color
        // A note's colour is a comment colour: the next highlight doesn't take it.
        if items[index].style == .underline {
            underlineColor = color
        } else if !items[index].isNote, editingID != id {
            self.color = color
        }
        changed()
    }

    /// A tint or an underline: the same highlight, marked another way.
    func setStyle(_ style: EPUBHighlightStyle, of id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].style != style else { return }
        recordUndo("Change Annotation Style", restoring: items)
        items[index].style = style
        changed()
    }

    /// A blank note removes it; the highlight stays. Called as the note is
    /// typed: each keystroke is saved, and pages repaint only when the
    /// highlight gains or loses its note marker. The typing in one editing
    /// session is one Undo step.
    func setNote(_ note: String, of id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blanked, a note stays a note with nothing in it; never typed in, it isn't one yet.
        let new: String? = trimmed.isEmpty ? (items[index].isNote || !note.isEmpty ? "" : nil) : note
        guard items[index].note != new else { return }
        let hadNote = items[index].isNote
        if typingNoteID != id {
            recordUndo("Edit Note", restoring: items)
            typingNoteID = id
        }
        items[index].note = new
        changed(repaint: items[index].isNote != hadNote)
    }

    func remove(_ id: UUID) {
        guard let removed = highlight(id) else { return }
        recordUndo(removed.isNote ? "Delete Note" : "Remove Annotation", restoring: items)
        items.removeAll { $0.id == id }
        if editingID == id { setEditing(nil) }
        if selectedNoteID == id { selectedNoteID = nil }
        changed()
    }

    // MARK: - Notes panel

    /// Opens the panel on a highlight's note, to read: what a click on a note
    /// does, as on a PDF comment.
    func selectNote(_ id: UUID) {
        guard highlight(id) != nil else { return }
        isPanelShown = true
        selectedNoteID = id
        setEditing(nil)
    }

    /// Opens the panel on a highlight's note, to write in.
    func edit(_ id: UUID) {
        guard let highlight = highlight(id) else { return }
        edit(id, opened: highlight.isNote ? .note : .plainHighlight)
    }

    private func edit(_ id: UUID, opened: EditingOrigin) {
        isPanelShown = true
        selectedNoteID = id
        setEditing(id)
        editingOrigin = opened
    }

    func endEditing() { setEditing(nil) }

    func togglePanel() {
        if isPanelShown { closePanel() } else { isPanelShown = true }
    }

    func closePanel() {
        isPanelShown = false
        selectedNoteID = nil
        setEditing(nil)
    }

    private func setEditing(_ id: UUID?) {
        guard id != nil || editingID != nil else { return }
        let (left, origin) = (editingID, editingOrigin)
        editingID = id
        editingRevision &+= 1
        typingNoteID = nil
        if let left, left != id { finishEditing(left, opened: origin) }
    }

    /// What a note left with nothing in it becomes, by what it was opened on.
    private func finishEditing(_ id: UUID, opened: EditingOrigin) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].hasNote else { return }
        switch opened {
        case .note, .newHighlight:
            // PDF keeps an empty comment's bubble.
            items[index].note = ""
            changed()
        case .plainHighlight:
            guard items[index].isNote else { return }
            items[index].note = nil
            changed()
        case .firstWord:
            // Asked for with nothing selected and given nothing to say: no stray mark.
            while highlight(id) != nil, undoManager?.canUndo == true { undoManager?.undo() }
            if highlight(id) != nil {
                items.removeAll { $0.id == id }
                changed()
            }
            if selectedNoteID == id { selectedNoteID = nil }
        }
    }

    // MARK: - Undo

    /// Registers one Undo step that puts the highlights back as `before`.
    /// Any step ends the note typing step, so typing after it is a new one.
    private func recordUndo(_ name: String, restoring before: [EPUBHighlight]) {
        typingNoteID = nil
        guard let undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.restore(before, actionName: name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    /// Undo and Redo: the highlights as they were, the opposite step
    /// registered, and the note being edited shown afresh (or closed, if
    /// its highlight is gone).
    private func restore(_ snapshot: [EPUBHighlight], actionName name: String) {
        recordUndo(name, restoring: items)
        items = snapshot
        if let editingID {
            if highlight(editingID) == nil { setEditing(nil) } else { editingRevision &+= 1 }
        }
        if let selectedNoteID, highlight(selectedNoteID) == nil { self.selectedNoteID = nil }
        changed()
    }

    private func changed(repaint: Bool = true) {
        if repaint { revision &+= 1 }
        onChange()
    }
}
