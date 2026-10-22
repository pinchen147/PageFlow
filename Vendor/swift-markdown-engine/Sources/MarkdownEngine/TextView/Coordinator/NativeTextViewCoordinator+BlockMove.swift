import AppKit

extension NativeTextViewCoordinator {
    func blockMovePayload(range: NSRange, kind: BlockMovePasteboard.Kind) -> BlockMovePasteboard? {
        let phaseStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("blockMove.payload", since: phaseStart) }
        guard let text = textView?.textStorage?.mutableString, range.location >= 0, range.length > 0,
              range.location <= text.length, range.length <= text.length - range.location else { return nil }
        let section = kind == .heading ? foldSession.collapsedSection(at: range.location, in: text) : nil
        let range = section ?? range
        let lines = text.lineRange(for: range)
        let end = Self.contentEnd(of: lines, in: text)
        let prefix = NSRange(location: lines.location, length: range.location - lines.location)
        let suffixStart = min(end, NSMaxRange(range))
        let suffix = NSRange(location: suffixStart, length: end - suffixStart)
        guard text.substring(with: prefix).trimmingCharacters(in: .whitespaces).isEmpty,
              text.substring(with: suffix).trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let sourceRange = NSRange(location: lines.location, length: end - lines.location)
        return BlockMovePasteboard(source: text.substring(with: sourceRange), range: sourceRange, kind: kind,
                                   document: documentId, editor: blockEditorID,
                                   baseFolder: configuration.services.images.baseFolderURL,
                                   collapsedHeadingIndices: section.map { foldSession.transfer(in: $0).headingIndices })
    }

    /// The block's full lines and one adjacent separator; the Markdown itself retains its exact bytes.
    static func blockRemovalRange(_ range: NSRange, in text: NSString) -> NSRange {
        let end = contentEnd(of: range, in: text)
        var removed = text.lineRange(for: NSRange(location: range.location, length: max(0, end - range.location)))
        let after = NSMaxRange(removed)
        if after < text.length {
            let line = text.lineRange(for: NSRange(location: after, length: 0))
            if text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { removed.length += line.length }
        } else if removed.location > 0 {
            let before = text.lineRange(for: NSRange(location: removed.location - 1, length: 0))
            if text.substring(with: before).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                removed = NSUnionRange(before, removed)
            }
        }
        return removed
    }

    func blockMoveSlots(around window: NSRange, excluding payload: BlockMovePasteboard? = nil) -> [Int] {
        guard let main = textView as? NativeTextView else { return [] }
        let text = main.string as NSString
        let blocks = blockMover.currentBlocks(in: text)
            ?? BlockDropSlots.blocks(around: window, in: text, opaqueRanges: main.dropOpaqueRanges() ?? [])
        let slots = BlockDropSlots.slots(in: text, blocks: blocks, window: window).filter { foldLayout.hiddenRange(containing: $0) == nil }
        guard let payload, payload.isLocal(document: documentId, editor: blockEditorID), payload.matches(text) else { return slots }
        let removed = Self.blockRemovalRange(payload.range, in: text)
        return slots.filter { $0 < removed.location || $0 > NSMaxRange(removed) }
    }

    @discardableResult
    func moveBlock(_ payload: BlockMovePasteboard, to target: Int, copying: Bool = false) -> Bool {
        let phaseStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("blockMove.total", since: phaseStart) }
        guard let main = textView as? NativeTextView, main.isEditable, !isComposing(in: main), !isWritingToolsActive else { return false }
        var source = ""
        PerfTrace.time("blockMove.snapshot") { source = main.string }
        let text = source as NSString
        guard target >= 0, target <= text.length else { return false }
        let local = payload.isLocal(document: documentId, editor: blockEditorID)
        // Even Option-copy from this editor must refuse changed bytes.
        guard !local || payload.matches(text) else { return false }
        let copy = copying || !local
        let window = NSRange(location: target, length: 0)
        var targetSlots: [Int] = []
        PerfTrace.time("blockMove.targetSlots") { targetSlots = blockMoveSlots(around: window, excluding: copy ? nil : payload) }
        guard targetSlots.contains(target) else { return false }
        let removed = local ? Self.blockRemovalRange(payload.range, in: text) : NSRange(location: 0, length: 0)
        let markdown = (copy ? payload.rebasedSource(to: configuration.services.images.baseFolderURL) : payload.markdown.source)
            .trimmingCharacters(in: .newlines)
        let folding = payload.markdown.collapsedHeadingIndices.map {
            MarkdownFoldTransfer(source: markdown as NSString, headingIndices: $0)
        }
        let foldedRemoval = local && !copy && payload.identity.kind == .heading
            && foldSession.collapsedSection(at: payload.range.location, in: text) == payload.range ? removed : nil
        var boundedRestyle = false
        PerfTrace.time("blockMove.sourceProof") {
            boundedRestyle = Self.isClosedMovableBlock(markdown, kind: payload.identity.kind)
                && (!local || blockMoveSlots(around: payload.range).contains(payload.range.location))
        }
        let insertAt = !copy && target > removed.location ? target - removed.length : target
        let afterRemoval = NSMutableString(string: source)
        if !copy { afterRemoval.deleteCharacters(in: removed) }
        let insertionPlan = BlockDropSlots.insertion(of: markdown, at: insertAt, in: afterRemoval)
        var insertion = insertionPlan.text
        // Moves preserve the existing convention of an unterminated final block.
        if !copy && target == text.length && !source.hasSuffix("\n") && insertion.hasSuffix("\n") { insertion.removeLast() }
        let prefixLength = (insertion as NSString).range(of: markdown).location
        let movedStart = insertAt + (prefixLength == NSNotFound ? 0 : prefixLength)
        let action = "\(copy ? "Duplicate" : "Move") \(payload.identity.kind.title)"
        let commentMove = copy ? nil : MarkdownCommentMove(source: markdown)
        // Admit both locations against the unmodified document. No deletion or undo entry occurs
        // if a destination policy refuses insertion. The resulting edits and inverses share that admission.
        let admissions: [(NSRange, String)] = (copy ? [] : [(removed, "")])
            + [(NSRange(location: target, length: 0), insertion)]
        var admitted = false
        PerfTrace.time("blockMove.admission") { admitted = admitBlockEdits(admissions, in: main, foldedRemoval: foldedRemoval) }
        guard admitted else { return false }
        var unchanged = false
        PerfTrace.time("blockMove.sourceValidation") {
            if let storage = main.textStorage {
                unchanged = utf16(copiedUTF16(of: text), equals: storage.mutableString)
            }
        }
        guard unchanged else { return false }
        let undo = main.undoManager
        let ownsGroup = undo.map { $0.groupingLevel == 0 && !$0.isUndoing && !$0.isRedoing } ?? false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        PerfTrace.time("blockMove.retire") { tableEditingSession.retire() }
        var succeeded = false
        let mapPin: (Int) -> Int = { offset in
            var mapped = offset
            if !copy {
                if mapped >= NSMaxRange(removed) { mapped -= removed.length }
                else if mapped >= removed.location { mapped = removed.location }
            }
            if mapped >= insertAt { mapped += insertion.utf16.count }
            return mapped
        }
        // Both local edits inherit the drop line's anchor without changing the user's selection.
        PerfTrace.time("blockMove.viewport") {
        restylePreservingViewport(main, mapPin: mapPin, anchoringVisibleSource: true, anchorLocation: target,
                                  excludingSource: copy ? nil : removed, tag: "blockMove") {
            if !copy, !replaceSourceRanges([removed], with: "", expectedSource: source, actionName: action,
                                           reflowsParagraphChain: false, preflighted: true, preservesBlockStructure: boundedRestyle,
                                           commentMove: commentMove, folding: folding.map { _ in .empty }) { return }
            let selection: NSRange
            if folding?.collapsed.contains(0) == true {
                let heading = (markdown as NSString).lineRange(for: NSRange(location: 0, length: 0))
                selection = NSRange(location: movedStart + Self.contentEnd(of: heading, in: markdown as NSString), length: 0)
            } else { selection = payload.identity.kind == .image
                ? NSRange(location: movedStart, length: markdown.utf16.count)
                : NSRange(location: min(insertAt + insertionPlan.caret, afterRemoval.length + insertion.utf16.count), length: 0) }
            succeeded = replaceSourceRanges([NSRange(location: insertAt, length: 0)], with: insertion,
                                             expectedSource: afterRemoval as String, actionName: action,
                                             reflowsParagraphChain: false, selectionAfter: selection, preflighted: true, preservesBlockStructure: boundedRestyle,
                                             commentMove: commentMove,
                                             folding: folding?.shifted(by: movedStart - insertAt))
        }
        }
        guard succeeded else { return false }
        if payload.identity.kind == .table {
            selectMovedTable(at: movedStart, length: markdown.utf16.count)
        } else if payload.identity.kind == .image, let storage = main.textStorage,
                  let image = Self.renderedImage(around: NSRange(location: movedStart, length: markdown.utf16.count), in: storage) {
            selectImage(image, in: main)
        }
        return true
    }

    /// Validate delimiter balance locally before suppressing conservative whole-note
    /// invalidation. An arbitrary replacement or an unclosed fence never gets this scope.
    private static func isClosedMovableBlock(_ source: String, kind: BlockMovePasteboard.Kind) -> Bool {
        let text = source as NSString
        let blocks = BlockParser.parse(source, memoizing: false).filter { $0.kind != .blank }
        guard blocks.count == 1 else { return false }
        switch kind {
        case .code, .diagram:
            guard blocks[0].kind == .fencedCode,
                  let fence = FencedCode.scan(in: text, range: NSRange(location: 0, length: text.length)),
                  fence.isClosed else { return false }
            return true
        case .equation:
            return blocks[0].kind == .blockLatex
        case .table:
            return blocks[0].kind == .table
        case .paragraph: return blocks[0].kind == .paragraph
        case .heading: return blocks[0].kind == .heading
        case .quote: return blocks[0].kind == .blockquote
        case .list: return blocks[0].kind == .list
        case .divider: return blocks[0].kind == .thematicBreak
        case .image:
            guard blocks[0].kind == .paragraph else { return false }
            let tokens = MarkdownTokenizer.parseTokensViaAST(in: source, memoizing: false)
            guard let image = tokens.first(where: { $0.kind == .imageLink || $0.kind == .imageEmbed }) else { return false }
            let remainder = text.replacingCharacters(in: image.range, with: "")
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func admitBlockEdits(_ edits: [(NSRange, String)], in main: NativeTextView, foldedRemoval: NSRange?) -> Bool {
        let previousFoldedRange = foldedBlockMoveRange
        foldedBlockMoveRange = foldedRemoval
        defer { foldedBlockMoveRange = previousFoldedRange }
        let undo = main.undoManager
        let oldSpan = isApplyingSpanEdit, oldLiteral = isLiteralInsertion, oldProgrammatic = isProgrammaticEdit
        undo?.disableUndoRegistration()
        isApplyingSpanEdit = true
        isLiteralInsertion = true
        isProgrammaticEdit = true
        defer {
            isApplyingSpanEdit = oldSpan
            isLiteralInsertion = oldLiteral
            isProgrammaticEdit = oldProgrammatic
            undo?.enableUndoRegistration()
        }
        return edits.allSatisfy { main.shouldChangeText(in: $0.0, replacementString: $0.1) }
    }

    private func selectMovedTable(at start: Int, length: Int) {
        let range = NSRange(location: start, length: length)
        guard let main = textView, let table = MarkdownTableSource(source: main.string, range: range),
              tableEditingSession.begin(range: range, row: 0, column: 0, selecting: .start, validatedSource: table) else { return }
        tableEditingSession.setCellSelection(TableCellSelection(anchor: CellCoord(row: 0, column: 0),
                                                                head: CellCoord(row: table.rowCount - 1, column: table.columnCount - 1)))
    }

    func pasteMarkdownBlock(from pasteboard: NSPasteboard) -> Bool {
        guard let payload = BlockMovePasteboard.read(from: pasteboard), let main = textView else { return false }
        let replacement = payload.rebasedSource(to: configuration.services.images.baseFolderURL)
        return replaceSourceRanges([main.selectedRange()], with: replacement, expectedSource: main.string, actionName: "Paste")
    }
}
