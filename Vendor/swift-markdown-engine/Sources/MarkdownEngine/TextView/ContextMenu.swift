//
//  ContextMenu.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 20.06.25.
//
//  Right-click menu with toggleable Markdown formatting actions.
//

import Cocoa
import SwiftUI

extension NativeTextViewWrapper.Coordinator {
    public func textView(_ textView: NSTextView,
                  menu: NSMenu,
                  for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        selectionBar?.rightClickSuppressed = true
        // A right-click on a rendered table edits the cell under it and offers table commands.
        if let native = textView as? NativeTextView, native.routeMouseDownToTables(event) {
            let session = tableEditingSession
            return session.contextMenu(for: event) { session.editor.standardMenu(for: event) }
        }
        // A right-click on a rendered image selects it first (doc 26 §5.5); Cut and Copy act on it.
        if let native = textView as? NativeTextView, native.isEditable,
           let hit = native.renderedImage(at: native.convert(event.locationInWindow, from: nil)) {
            selectImage(hit.image, in: native)
        }
        if selectionBar != nil, showInsertBlockMenu(for: event, at: charIndex, in: textView) { return nil }
        let customMenu = menu.copy() as? NSMenu ?? NSMenu()

        if let fontIndex = customMenu.items.firstIndex(where: { $0.title == "Font" }) {
            customMenu.removeItem(at: fontIndex)
            let formatItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
            let formatSubmenu = NSMenu(title: "Format")
            let boldItem = NSMenuItem(title: "Bold", action: #selector(didMarkdownBold(_:)), keyEquivalent: "")
            boldItem.target = self
            formatSubmenu.addItem(boldItem)
            let italicItem = NSMenuItem(title: "Italic", action: #selector(didMarkdownItalic(_:)), keyEquivalent: "")
            italicItem.target = self
            formatSubmenu.addItem(italicItem)
            let underlineItem = NSMenuItem(title: "Underline", action: #selector(didMarkdownUnderline(_:)), keyEquivalent: "")
            underlineItem.target = self
            formatSubmenu.addItem(underlineItem)
            formatItem.submenu = formatSubmenu
            customMenu.insertItem(formatItem, at: fontIndex)

            let headingItem = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
            let headingSubmenu = NSMenu(title: "Heading")
            for level in 1...3 {
                let item = NSMenuItem(title: "H\(level)", action: #selector(didMarkdownHeading(_:)), keyEquivalent: "")
                item.target = self
                item.tag = level
                headingSubmenu.addItem(item)
            }
            headingItem.submenu = headingSubmenu
            customMenu.insertItem(headingItem, at: fontIndex + 1)

            let listItem = NSMenuItem(title: "Lists", action: nil, keyEquivalent: "")
            let listSubmenu = NSMenu(title: "Lists")
            let unorderedItem = NSMenuItem(title: "Bullet", action: #selector(didMarkdownUnorderedList(_:)), keyEquivalent: "")
            unorderedItem.target = self
            listSubmenu.addItem(unorderedItem)
            let orderedItem = NSMenuItem(title: "Numbered", action: #selector(didMarkdownOrderedList(_:)), keyEquivalent: "")
            orderedItem.target = self
            listSubmenu.addItem(orderedItem)
            listItem.submenu = listSubmenu
            customMenu.insertItem(listItem, at: fontIndex + 2)
            customMenu.insertItem(NSMenuItem.separator(), at: fontIndex + 3)
        }

        if objectSelection != nil {
            let copy = NSMenuItem(title: "Copy image", action: #selector(copyImageFromMenu(_:)), keyEquivalent: "")
            copy.target = self
            let delete = NSMenuItem(title: "Delete image", action: #selector(deleteImageFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            customMenu.insertItem(NSMenuItem.separator(), at: 0)
            customMenu.insertItem(delete, at: 0); customMenu.insertItem(copy, at: 0)
        }
        return customMenu
    }

    @objc private func copyImageFromMenu(_ sender: Any?) { copySelectedImage() }
    @objc private func deleteImageFromMenu(_ sender: Any?) {
        guard let objectSelection, let textView else { return }; deleteImage(objectSelection, in: textView)
    }

    /// the reference editor's Insert block menu (doc 24 §5.4.8): a right-click on a line
    /// with no text, with no text selected, offers blocks to start there.
    func showInsertBlockMenu(for event: NSEvent?, at charIndex: Int, in textView: NSTextView) -> Bool {
        let text = textView.string as NSString
        guard textView.isEditable, textView.selectedRange().length == 0, charIndex >= 0, charIndex <= text.length,
              let scroll = textView.enclosingScrollView else { return false }
        let line = text.lineRange(for: NSRange(location: min(charIndex, max(0, text.length - 1)), length: 0))
        let lineText = charIndex == text.length && text.length > 0 && text.character(at: text.length - 1) == 0x0A
            ? "" : text.substring(with: line)
        guard lineText.allSatisfy({ $0.isWhitespace }) else { return false }
        let caret = charIndex == text.length ? text.length : line.location
        // Quote only where the paragraph is not already in a list or quote.
        let previousLine = caret > 0 ? text.substring(with: text.lineRange(for: NSRange(location: caret - 1, length: 0))) : ""
        let trimmed = previousLine.trimmingCharacters(in: .whitespaces)
        let inListOrQuote = trimmed.hasPrefix(">") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
            || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil
        typealias Item = TableMenuView.Item
        func insert(_ format: MarkdownFormat) -> () -> Void {
            { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.setSelectedRange(NSRange(location: caret, length: 0))
                self.apply(format)
            }
        }
        var items: [Item] = [
            Item("Heading 1", symbol: "textformat.size.larger", action: insert(.heading(level: 1))),
            Item("Heading 2", symbol: "textformat.size", action: insert(.heading(level: 2))),
            Item("Heading 3", symbol: "textformat.size.smaller", action: insert(.heading(level: 3))),
            Item("Table", symbol: "tablecells", action: insert(.table)),
            .separator,
            Item("Bulleted list", symbol: "list.bullet", action: insert(.bulletedList)),
            Item("Checklist", symbol: "checklist", action: insert(.checklist)),
            Item("Code block", symbol: "chevron.left.forwardslash.chevron.right", action: insert(.codeBlock)),
            Item("Divider", symbol: "minus", action: insert(.divider)),
        ]
        // the reference editor lists Image only where an image picker exists: PageFlow's image hook.
        if let native = textView as? NativeTextView, native.onPasteImage != nil {
            items.append(Item("Image", symbol: "photo") { [weak native] in native?.insertImageFromPicker(at: caret) })
        }
        items += [
            Item("Numbered list", symbol: "list.number", action: insert(.numberedList)),
        ]
        if !inListOrQuote { items.append(Item("Quote", symbol: "text.quote", action: insert(.quote))) }
        let windowPoint = event?.locationInWindow ?? textView.convert(NSPoint(x: textView.textContainerOrigin.x, y: 0), to: nil)
        var point = scroll.convert(windowPoint, from: nil)
        if !scroll.isFlipped { point.y = scroll.bounds.height - point.y }
        selectionBar?.rightClickSuppressed = true
        let menu = TableMenuView.present(items, family: .float, label: "Insert block", placement: .at(point), in: scroll,
                                         fromKeyboard: event == nil, returningFocusTo: textView) { _ in }
        menu.closesOnScroll = false
        menu.closesOnTyping = true
        return true
    }

    /// Returns the smallest bold or boldItalic token that encloses the selection, or nil when the selection isn't enclosed by emphasis with a bold trait.
    func enclosingBoldToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        enclosingEmphasisToken(for: selection, in: text, style: .bold)
    }

    /// Returns the smallest italic or boldItalic token that encloses the selection, or nil when the selection isn't enclosed by emphasis with an italic trait.
    func enclosingItalicToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        enclosingEmphasisToken(for: selection, in: text, style: .italic)
    }

    /// Returns the smallest underline token that encloses the selection.
    func enclosingUnderlineToken(for selection: NSRange, in text: String) -> MarkdownToken? {
        enclosingEmphasisToken(for: selection, in: text, style: .underline)
    }

    /// The smallest emphasis token of `style` that encloses the selection, routed through
    /// the SAME `EnclosingTokenIndex` (containment predicate + comparator) the live ⌘B/I/U
    /// toggle uses — so the menu checkmark can no longer disagree with the toggle at token
    /// edges. The index's `init(tokens:style:)` performs the "matching kinds" filtering
    /// (bold+boldItalic / italic+boldItalic / underline), replacing the old private
    /// kind-set filter + `tokenEncloses` predicate.
    private func enclosingEmphasisToken(for selection: NSRange, in text: String, style: MarkdownInlineStyle) -> MarkdownToken? {
        EnclosingTokenIndex(tokens: parsedDocument(for: text).tokens, style: style)
            .smallestEnclosing(selection)
    }

    func isSelectionBold(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingBoldToken(for: range, in: nsText as String) != nil
    }

    func isSelectionItalic(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingItalicToken(for: range, in: nsText as String) != nil
    }

    func isSelectionUnderline(in nsText: NSString, range: NSRange) -> Bool {
        return enclosingUnderlineToken(for: range, in: nsText as String) != nil
    }

    func isSelectionHeading(level: Int, in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLine.hasPrefix(String(repeating: "#", count: level) + " ")
    }

    func isSelectionList(in nsText: NSString, range: NSRange) -> Bool {
        let lineRange = nsText.lineRange(for: range)
        let line = nsText.substring(with: lineRange)
        return line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
            || line.hasPrefix("\t• ") || line.hasPrefix("1. ")
    }

    func applyHeading(level: Int) {
        guard let tv = textView, tv.isEditable, !tv.hasMarkedText(), !isWritingToolsActive,
              !tableEditingSession.isActive else { return }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        let lineRange = nsText.lineRange(for: range)
        let originalLine = nsText.substring(with: lineRange)
        let (body, suffix) = lineContentAndTerminator(originalLine)
        var content = String(body.drop(while: { $0.isWhitespace }))
        while content.hasPrefix("#") { content.removeFirst() }
        content = String(content.drop(while: { $0.isWhitespace }))
        let prefix = String(repeating: "#", count: level) + " "
        let newLine = prefix + content + suffix
        if tv.shouldChangeText(in: lineRange, replacementString: newLine) {
            tv.replaceCharacters(in: lineRange, with: newLine)
            tv.didChangeText()
            let newSel = NSRange(location: lineRange.location + prefix.utf16.count, length: content.utf16.count)
            tv.setSelectedRange(newSel)
            commitTextSync(for: tv)
        }
    }

    @objc func didMarkdownHeading(_ sender: NSMenuItem) {
        applyHeading(level: sender.tag)
    }

    private func lineContentAndTerminator(_ line: String) -> (String, String) {
        let source = line as NSString
        guard source.length > 0 else { return ("", "") }
        var contentEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentEnd,
                            for: NSRange(location: 0, length: source.length))
        return (source.substring(to: contentEnd), source.substring(from: contentEnd))
    }

    @objc func didMarkdownUnorderedList(_ sender: Any?) {
        apply(.bulletedList)
    }

    @objc func didMarkdownOrderedList(_ sender: Any?) {
        apply(.numberedList)
    }

    @objc func didMarkdownBold(_ sender: Any?) {
        applyInlineStyle(.bold)
    }

    @objc func didMarkdownItalic(_ sender: Any?) {
        applyInlineStyle(.italic)
    }

    @objc func didMarkdownUnderline(_ sender: Any?) {
        applyInlineStyle(.underline)
    }

    func applyInlineStyle(_ style: MarkdownInlineStyle) {
        if objectSelection != nil { return }   // see `apply(_:)`
        if tableEditingSession.isActive {
            tableEditingSession.format(style)
            return
        }
        guard let tv = textView,
              tv.isEditable, !tv.hasMarkedText(), !isWritingToolsActive,
              let textStorage = tv.textStorage else { return }
        let nsText = textStorage.mutableString
        let targetRange = inlineFormattingTargetRange(in: tv, text: nsText)
        guard targetRange.location != NSNotFound,
              targetRange.location >= 0,
              NSMaxRange(targetRange) <= nsText.length else { return }

        // The formatting RUNS — one per block-content region the target touches, markers
        // excluded, inline code/LaTeX boundary-clipped (the block-aware geometry lives in
        // `MarkdownInlineFormattingRuns`).
        //
        // ONE scoped inline-token pass powers BOTH the protected-span clips and the
        // enclosing-token index. It must never fall back to a full-document tokenize:
        // the parse cache is invalidated on every keystroke, so the old full-doc
        // fallback made the first ⌘B/I/U after typing O(document) on the main thread
        // ("sometimes slow" field report) while a repeat press was instant.
        var blocks: [BlockNode] = []
        PerfTrace.time("apply.parse") { blocks = DocumentAST.parse(tv.string, scopedRanges: [targetRange]) }
        var scopedTokens: [MarkdownToken] = []
        PerfTrace.time("apply.tokens") { scopedTokens = scopedInlineTokens(in: nsText, targetRange: targetRange) }
        let clips = scopedTokens.compactMap { token -> NSRange? in
            guard token.kind == .inlineCode || token.kind == .inlineLatex else { return nil }
            return NSIntersectionRange(token.range, targetRange).length > 0 ? token.range : nil
        }
        let runs = MarkdownInlineFormattingRuns.formattingRuns(
            targetRange: targetRange, blocks: blocks, clips: clips, nsText: nsText
        )
        guard !runs.isEmpty else { return }

        // ONE enclosing-token index for the whole operation → O(log tokens) per run
        // (was O(tokens) per run — the O(runs × tokens) freeze on ⌘A).
        let emphasisKinds: Set<MarkdownTokenKind> = [.bold, .italic, .boldItalic, .underline]
        let index = EnclosingTokenIndex(
            tokens: scopedTokens.filter {
                emphasisKinds.contains($0.kind)
                    && NSIntersectionRange($0.range, targetRange).length > 0
            },
            style: style
        )
        let plans = MarkdownInlineFormatter.plans(text: nsText, targetRanges: runs, style: style, index: index)
        guard !plans.isEmpty else { return }

        // One run (a word, a line, a single-block selection — the common case) takes the
        // scoped single-edit fast path; multi-run (multi-line quote, ⌘A) batches into one
        // atomic edit + one undo step.
        if plans.count == 1 {
            _ = applyInlineFormattingPlan(plans[0], in: tv)
        } else {
            applyInlineFormattingPlans(plans, originalSelection: targetRange, in: tv)
        }
    }

    /// The inline tokens relevant to one formatting operation, computed from the
    /// CURRENT text without ever tokenizing the whole document: reuse the parse
    /// cache only when its literal UTF-16 source matches, else tokenize just the
    /// target's paragraph union (inline tokens cannot cross a block boundary,
    /// so the scoped set is complete for the target). Internal for the perf tripwire test.
    func scopedInlineTokens(in nsText: NSString, targetRange: NSRange) -> [MarkdownToken] {
        if let cachedParsedChars, let cached = cachedParsedDocument?.tokens,
           utf16(cachedParsedChars, equals: nsText) {
            return cached
        }
        let parseRange = MarkdownInlineFormattingRuns.parseRange(in: nsText, targetRange: targetRange)
        guard parseRange.location != NSNotFound, parseRange.length > 0 else { return [] }
        return MarkdownInlineFormattingRuns.inlineTokens(in: nsText, range: parseRange)
    }

    /// Apply many disjoint inline-format edits as ONE storage replacement → ONE
    /// undo step, ONE restyle. The span from the first plan to the last is
    /// rebuilt in a single pass (untouched text copied through) and replaced
    /// once: the storage shifts its tail one time instead of once per plan
    /// (3 000 plans on a 500 KB note cost 200 ms of memmove; one span, 30).
    private func applyInlineFormattingPlans(
        _ plans: [MarkdownInlineFormatPlan],
        originalSelection: NSRange,
        in tv: NSTextView
    ) {
        guard let textStorage = tv.textStorage, !plans.isEmpty else { return }
        let ascending = plans.sorted { $0.replacementRange.location < $1.replacementRange.location }
        let nsText = textStorage.mutableString
        let spanStart = ascending[0].replacementRange.location
        let spanEnd = NSMaxRange(ascending[ascending.count - 1].replacementRange)
        let span = NSRange(location: spanStart, length: spanEnd - spanStart)
        var rebuilt = ""
        rebuilt.reserveCapacity(span.length + ascending.count * 4)
        var cursor = spanStart
        for plan in ascending {
            rebuilt += nsText.substring(with: NSRange(location: cursor, length: plan.replacementRange.location - cursor))
            rebuilt += plan.replacement
            cursor = NSMaxRange(plan.replacementRange)
        }
        let delta = (rebuilt as NSString).length - span.length
        let edit = SpanEdit(
            range: span,
            replacement: rebuilt,
            selectionAfter: NSRange(location: originalSelection.location, length: max(0, originalSelection.length + delta)),
            actionName: ascending[0].actionName,
            mapLocation: Self.paragraphPreservingMap(from: nsText.substring(with: span), to: rebuilt, spanStart: spanStart)
        )
        performSpanEdit(edit, in: tv)
    }

    /// One replacement of a whole span of the document — a ⌘A format, or the
    /// undo or redo of one. `mapLocation` says where a character offset lands
    /// after the replacement (the viewport pin and the viewport-first split
    /// need it). Arbitrary replacements supply both directional maps; formatting
    /// can use paragraph-preserving mapping for its inverse.
    struct SpanEdit {
        let range: NSRange
        let replacement: String
        let selectionAfter: NSRange
        let actionName: String
        let mapLocation: (Int) -> Int
        var inverseMapLocation: ((Int) -> Int)? = nil
        var inverseSelection: NSRange? = nil
        var reflowsParagraphChain = false
        /// Attributes for the replacement until its next restyle; base body text when nil.
        var insertedAttributes: [NSAttributedString.Key: Any]? = nil
        /// False for a table cell keystroke inside a typing run, whose one Undo
        /// step the cell session registered before the run's first keystroke.
        var registersUndo = true
        /// Both locations of an atomic block move were admitted before its first mutation.
        var preflighted = false
        /// Only closed, complete blocks inserted/deleted at validated top-level boundaries.
        /// Their delimiters cannot change the interpretation of the rest of the note.
        var preservesBlockStructure = false
        var commentMove: MarkdownCommentMove? = nil
    }

    /// Applies `edit` through the same pinned, viewport-first path forwards
    /// and backwards, and registers its inverse with the undo manager. AppKit's
    /// own undo of a whole-document replacement was neither: it replaced the
    /// text unpinned (a 2 000 pt jump) and restyled the whole note in one turn
    /// (35 s on a 1.8 MB note).
    @discardableResult
    func performSpanEdit(_ edit: SpanEdit, in tv: NSTextView) -> Bool {
        if edit.reflowsParagraphChain, !tv.isHiddenOrHasHiddenAncestor {
            tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
        guard let textStorage = tv.textStorage,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= textStorage.length,
              edit.range.length <= textStorage.length - edit.range.location else { return false }
        // AppKit admission registers its own replacement inverse. This path
        // owns a pinned inverse below, so suppress that duplicate history entry.
        // A span edit is literal source: typing handlers (auto-wrap, pairing)
        // must not rewrite it, least of all while registration is off.
        let admissionUndo = tv.undoManager
        admissionUndo?.disableUndoRegistration()
        isApplyingSpanEdit = true
        defer { isApplyingSpanEdit = false }
        let wasLiteral = isLiteralInsertion
        isLiteralInsertion = true
        let admitted = edit.preflighted || tv.shouldChangeText(in: edit.range, replacementString: edit.replacement)
        isLiteralInsertion = wasLiteral
        admissionUndo?.enableUndoRegistration()
        guard admitted else { return false }
        if edit.preflighted {
            var captured = false
            PerfTrace.time("apply.capture") { captured = captureSourceEdit(in: tv, range: edit.range, replacement: edit.replacement) }
            guard captured else { return false }
        }
        if edit.preservesBlockStructure {
            var prepared = false
            PerfTrace.time("apply.blockTokens") {
                prepared = prepareStandaloneBlockTokens(in: textStorage.mutableString, range: edit.range, replacement: edit.replacement)
            }
            if prepared {
                pendingEditRequiresFullDocumentRestyle = false
                pendingPreEditActiveTokenIndices = []
            }
        }
        let previous = textStorage.mutableString.substring(with: edit.range)
        let newRange = NSRange(location: edit.range.location, length: (edit.replacement as NSString).length)
        let oldRange = edit.range
        let inverse = SpanEdit(
            range: newRange,
            replacement: previous,
            selectionAfter: edit.inverseSelection ?? NSRange(location: oldRange.location, length: oldRange.length),
            actionName: edit.actionName,
            mapLocation: edit.inverseMapLocation
                ?? Self.paragraphPreservingMap(from: edit.replacement, to: previous, spanStart: oldRange.location),
            inverseMapLocation: edit.mapLocation,
            inverseSelection: edit.selectionAfter,
            reflowsParagraphChain: edit.reflowsParagraphChain,
            preflighted: edit.preflighted, preservesBlockStructure: edit.preservesBlockStructure,
            commentMove: edit.commentMove
        )
        if edit.registersUndo, let undoManager = tv.undoManager {
            undoManager.registerUndo(withTarget: self) { coordinator in
                guard let textView = coordinator.textView else { return }
                coordinator.performSpanEdit(inverse, in: textView)
            }
            undoManager.setActionName(edit.actionName)
        }

        // A whole-document edit restyles viewport-first (+DeferredRestyle): hand
        // the restyle the viewport's range as it will be AFTER the text changes.
        if edit.range.length > Self.deferredRestyleThreshold, let viewport = viewportCharacterRange(in: tv) {
            let start = edit.mapLocation(viewport.location)
            let end = edit.mapLocation(NSMaxRange(viewport))
            pendingViewportFirstRange = NSRange(location: start, length: max(0, end - start))
        }

        let (baseFont, baseParagraph) = baseFontAndStyle()
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: configuration.theme.bodyText, .paragraphStyle: baseParagraph
        ]
        // Command-layer anchoring: the replacement itself reflows the document
        // (a ⌘A toggle changes wrap counts everywhere) BEFORE the anchored
        // restyle inside didChangeText runs — unpinned, that phase panned the
        // view (~100pt on marker-heavy docs). The pin follows its paragraph
        // through the replacement (`mapLocation`); measured at the old offset it
        // read a different paragraph and "corrected" by up to a screen. Pins nest
        // fine: the inner restyle pin compensates its own phase, this outer one
        // covers the mutation.
        PerfTrace.time("apply.pinned") {
        restylePreservingViewport(tv, mapPin: edit.mapLocation,
                                  anchoringVisibleSource: edit.reflowsParagraphChain
                                      || (textStorage.length > NativeTextView.estimatedLayoutChainThreshold
                                          && edit.range.length > Self.deferredRestyleThreshold)) {
            tv.breakUndoCoalescing()
            MainActor.assumeIsolated {
                comments?.store.prepareMoveEdit(receipt: edit.commentMove, range: edit.range,
                                                replacement: edit.replacement, in: textStorage.mutableString)
            }
            PerfTrace.time("apply.replace") {
                textStorage.beginEditing()
                textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
                // The replacement inherits the attributes of the span's first
                // character (a heading's font, a hidden marker's 1 pt font). Until
                // the restyle reaches a paragraph it must read as plain body text,
                // not as a page of headings or a collapsed sliver.
                textStorage.setAttributes(edit.insertedAttributes ?? baseAttributes, range: newRange)
                textStorage.endEditing()
                // Arbitrary replacements can change the paragraph chain. Retained
                // downstream fragments may still report their pre-edit origins.
                if edit.reflowsParagraphChain, let layout = tv.textLayoutManager,
                   let start = layout.textContentManager?.location(
                       layout.documentRange.location, offsetBy: edit.range.location
                   ), let tail = NSTextRange(location: start, end: layout.documentRange.endLocation) {
                    layout.invalidateLayout(for: tail)
                }
            }
            PerfTrace.time("apply.setSelection") { tv.setSelectedRange(edit.selectionAfter) }
            PerfTrace.time("apply.didChangeText") { tv.didChangeText() }
        }
        }
        tv.breakUndoCoalescing()
        tableEditingSession.sourceDidChange(map: edit.mapLocation)
        // Undo and Redo of a table edit leave the caret in the table's source;
        // no selection handler sees it (`pendingEditedRange` is set), so the
        // cell takes it here.
        if !tableEditingSession.isActive, tv.undoManager?.isUndoing == true || tv.undoManager?.isRedoing == true {
            enterTableCell(for: tv.selectedRange(), in: tv)
        }
        tableEditingSession.applyPendingRangeRestore()
        if deferredRestyleRanges.isEmpty { scheduleBulkViewportAnchorFinish() }
        return true
    }

    /// Where a character offset lands after the span starting at `spanStart`
    /// changed from `old` to `new`: unchanged before the span, shifted by the
    /// length change after it, and inside it the START of the same paragraph
    /// by index — a format toggle adds or removes markers on lines but never a
    /// line, so the reader's paragraph is the one with the same number. (The
    /// proportional map it replaces landed in a neighbouring paragraph and
    /// the pin then "corrected" by that paragraph's distance: the 30–50 pt
    /// wobble of a mid-document ⌘A format or its undo.)
    static func paragraphPreservingMap(from old: String, to new: String, spanStart: Int) -> (Int) -> Int {
        let oldNS = old as NSString
        let newNS = new as NSString
        return { location in
            if location <= spanStart { return location }
            let relative = location - spanStart
            if relative >= oldNS.length { return location + (newNS.length - oldNS.length) }
            var index = 0
            var cursor = 0
            while cursor < relative {
                let newline = oldNS.range(of: "\n", range: NSRange(location: cursor, length: relative - cursor))
                guard newline.location != NSNotFound else { break }
                index += 1
                cursor = NSMaxRange(newline)
            }
            var start = 0
            for _ in 0..<index {
                let newline = newNS.range(of: "\n", range: NSRange(location: start, length: newNS.length - start))
                guard newline.location != NSNotFound else { return spanStart + newNS.length }
                start = NSMaxRange(newline)
            }
            return spanStart + start
        }
    }

    private func applyInlineFormattingPlan(_ plan: MarkdownInlineFormatPlan, in tv: NSTextView) -> Bool {
        pendingInlineFormattingEdit = true
        if tv.shouldChangeText(in: plan.replacementRange, replacementString: plan.replacement) {
            // Same command-layer anchor as the batched path above, following
            // the pin's paragraph through the plan's own edit.
            let map = Self.paragraphPreservingMap(
                from: (tv.string as NSString).substring(with: plan.replacementRange),
                to: plan.replacement, spanStart: plan.replacementRange.location)
            restylePreservingViewport(tv, mapPin: map) {
                tv.breakUndoCoalescing()
                tv.replaceCharacters(in: plan.replacementRange, with: plan.replacement)
                tv.setSelectedRange(plan.selectionAfter)
                tv.didChangeText()
            }
            tv.undoManager?.setActionName(plan.actionName)
            tv.breakUndoCoalescing()
            return true
        } else {
            pendingInlineFormattingEdit = false
            return false
        }
    }

    func inlineFormattingTargetRange(in textView: NSTextView, text nsText: NSString) -> NSRange {
        let selected = textView.selectedRange()
        guard selected.length == 0, nsText.length > 0 else { return selected }
        var word = textView.selectionRange(forProposedRange: selected, granularity: .selectByWord)
        if selected.location > 0, word.location != NSNotFound, NSMaxRange(word) <= nsText.length,
           nsText.substring(with: word).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            word = textView.selectionRange(
                forProposedRange: NSRange(location: selected.location - 1, length: 1),
                granularity: .selectByWord
            )
        }
        guard word.location != NSNotFound, NSMaxRange(word) <= nsText.length,
              MarkdownInlineFormatter.trimmedRange(word, in: nsText).length > 0 else { return selected }
        return word
    }

}

// MARK: - Menu Item Validation
extension NativeTextViewWrapper.Coordinator: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tv = textView else { return true }
        let nsText = tv.string as NSString
        let range = tv.selectedRange()
        switch menuItem.action {
        case #selector(didMarkdownBold(_:)):
            menuItem.state = enclosingBoldToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownItalic(_:)):
            menuItem.state = enclosingItalicToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownUnderline(_:)):
            menuItem.state = enclosingUnderlineToken(for: range, in: tv.string) != nil ? .on : .off
            return true
        case #selector(didMarkdownHeading(_:)):
            return !isSelectionHeading(level: menuItem.tag, in: nsText, range: range)
        case #selector(didMarkdownUnorderedList(_:)),
             #selector(didMarkdownOrderedList(_:)):
            return !isSelectionList(in: nsText, range: range)
        default:
            return true
        }
    }
}
