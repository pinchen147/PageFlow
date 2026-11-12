import AppKit

extension MarkdownTableEditingSession {
    private var cellRichBoundaryIndex: MarkdownRichBoundaryIndex {
        if let cached = cachedRichBoundaryIndex, cached.source.utf16.elementsEqual(editor.string.utf16) { return cached }
        let source = editor.string
        let tokens = InlineASTAdapter.tokens(from: InlineParser.parse(source, allowsEmphasisAcrossLineBreaks: true))
        let value = MarkdownRichBoundaryIndex(source: source, tokens: tokens, aliases: false, cell: true)
        cachedRichBoundaryIndex = value
        return value
    }

    var richCellNavigationCoordinates: (selection: NSRange, length: Int)? {
        let index = cellRichBoundaryIndex
        guard index.hasRichSyntax else { return nil }
        return (index.visibleRange(editor.selectedRange()), index.visible.length)
    }

    func normalizeCellRichBoundarySelection() {
        guard !refreshing, !isComposing, !isRangeMode else { return }
        let index = cellRichBoundaryIndex, selected = editor.selectedRange()
        guard index.owns(selected) else { return }
        let normalized = index.normalized(selected)
        guard selected != normalized else { return }
        refreshing = true
        editor.setSelectedRange(normalized)
        refreshing = false
    }

    private func applyCellRichBoundaryEdit(_ edit: MarkdownSourceEdit, action: String) {
        let before = editor.selectedRange()
        pendingEditRange = before
        refreshing = true
        editor.replaceCharacters(in: edit.range, with: edit.replacement)
        editor.setSelectedRange(edit.selection)
        refreshing = false
        _ = commitInput(actionName: action, coalescing: false, selectionBefore: before)
    }

    func applyCellRichBoundaryInput(_ text: String, range: NSRange) -> Bool {
        guard !refreshing, !isComposing, !isRangeMode, editor.undoManager?.isUndoing != true,
              editor.undoManager?.isRedoing != true else { return false }
        let index = cellRichBoundaryIndex
        guard index.owns(range) else { return false }
        if !emphasisTypingState.enabled.isEmpty || !emphasisTypingState.disabled.isEmpty { return false }
        if range.length == 0 && !inheritedCellEmphasisTraits.isEmpty { return false }
        let anchor = range.length == 0 ? index.normalized(range).location : nil
        guard let edit = index.replacement(index.visibleRange(range), with: text, sourceAnchor: anchor) else { return true }
        if edit.range == range,
           edit.selection == NSRange(location: range.location + text.utf16.count, length: 0),
           edit.replacement.utf16.elementsEqual(text.utf16) {
            return false
        }
        applyCellRichBoundaryEdit(edit, action: "Typing")
        return true
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange,
                  toCharacterRange newRange: NSRange) -> NSRange {
        if !refreshing && !navigatingCellEmphasis { richCellSelectionIntent = nil }
        return richBoundarySelectionProposal?(oldRange, newRange) ?? newRange
    }

    func handleCellRichBoundaryCommand(_ selector: Selector) -> Bool {
        guard !refreshing, !navigatingCellEmphasis else { return false }
        guard !isComposing, !isRangeMode else { richCellSelectionIntent = nil; return false }
        let index = cellRichBoundaryIndex, original = editor.selectedRange()
        let command = NSStringFromSelector(selector)
        if !command.contains("AndModifySelection") { richCellSelectionIntent = nil }
        // A rich cell uses one visible coordinate system for every horizontal/word
        // step, including ordinary content adjoining concealed source syntax.
        // Editing still requires ownership of the actual source envelope.
        guard index.owns(original) || (command.hasPrefix("move") && index.hasRichSyntax) else { return false }
        let selection = index.visibleRange(original)
        if ["deleteBackward:", "deleteForward:", "deleteWordBackward:", "deleteWordForward:"].contains(command) {
            var range = selection
            if range.length == 0 {
                let backward = command.contains("Backward")
                let next: Int
                if command.contains("Word") {
                    cellWordNavigator.string = index.visible as String
                    cellWordNavigator.baseWritingDirection = editor.baseWritingDirection
                    cellWordNavigator.setSelectedRange(selection)
                    cellWordNavigator.doCommand(by: NSSelectorFromString(backward ? "moveWordBackward:" : "moveWordForward:"))
                    next = cellWordNavigator.selectedRange().location
                } else { next = index.nextVisibleOffset(range.location, backward: backward) }
                range = NSRange(location: min(range.location, next), length: abs(next - range.location))
            }
            guard range.length > 0 else { return true }
            if let edit = index.replacement(range, with: "") { applyCellRichBoundaryEdit(edit, action: "Delete") }
            return true
        }
        guard command.hasPrefix("move"), command.contains("Left") || command.contains("Right")
            || command.contains("Backward") || command.contains("Forward") else {
            richCellSelectionIntent = nil
            return false
        }
        // Existing cell-edge navigation still owns crossing to another cell.
        if selector == #selector(NSResponder.moveRight(_:)),
           selection == NSRange(location: 0, length: index.visible.length), index.visible.length > 0 { return false }
        if selection.length == 0 && (command.contains("Left") || command.contains("Backward")) && selection.location == 0 { return false }
        if selection.length == 0 && (command.contains("Right") || command.contains("Forward")) && selection.location == index.visible.length { return false }
        if command.contains("AndModifySelection") {
            return extendRichCellSelection(selector, index: index, original: original)
        }
        refreshing = true
        navigatingCellEmphasis = true
        if command.contains("Word") {
            cellWordNavigator.string = index.visible as String
            cellWordNavigator.baseWritingDirection = editor.baseWritingDirection
            cellWordNavigator.setSelectedRange(selection, affinity: editor.selectionAffinity, stillSelecting: false)
            cellWordNavigator.doCommand(by: selector)
            let moved = cellWordNavigator.selectedRange()
            let start = index.sourceOffset(moved.location, downstream: true)
            let end = moved.length == 0 ? start : index.sourceOffset(NSMaxRange(moved), downstream: false)
            editor.setSelectedRange(NSRange(location: start, length: max(0, end - start)),
                                    affinity: cellWordNavigator.selectionAffinity, stillSelecting: false)
        } else {
            cellWordNavigator.string = index.visible as String
            cellWordNavigator.baseWritingDirection = editor.baseWritingDirection
            cellWordNavigator.setSelectedRange(selection, affinity: editor.selectionAffinity, stillSelecting: false)
            cellWordNavigator.doCommand(by: selector)
            let expected = cellWordNavigator.selectedRange()
            richBoundarySelectionProposal = { before, proposed in
                return index.nativeMovementProposal(from: before, to: proposed,
                    initialVisible: selection, expectedVisible: expected)
            }
            defer { richBoundarySelectionProposal = nil }
            for _ in 0..<index.movementLimit {
                let before = editor.selectedRange()
                editor.doCommand(by: selector)
                let after = editor.selectedRange()
                if after == before || index.visibleRange(after) != selection { break }
            }
        }
        let normalized = index.normalized(editor.selectedRange())
        if normalized != editor.selectedRange() { editor.setSelectedRange(normalized) }
        navigatingCellEmphasis = false
        refreshing = false
        emphasisTypingState.adopt()
        endTypingRun()
        updateEmphasisTypingAttributes()
        return true
    }
}
