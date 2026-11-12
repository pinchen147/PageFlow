import AppKit

extension MarkdownTableEditingSession {
    /// A native selection intent belongs to one unchanged cell and exact source selection.
    struct RichCellSelectionIntent {
        let source: String
        let table: Int
        let row: Int
        let column: Int
        let anchor: Int
        let active: Int
        let selection: NSRange
    }

    func extendRichCellSelection(_ selector: Selector, index: MarkdownRichBoundaryIndex, original: NSRange) -> Bool {
        guard let table else { return false }
        let navigator = cellWordNavigator
        navigator.string = index.visible as String
        navigator.baseWritingDirection = editor.baseWritingDirection
        let visible = index.visibleRange(original)
        let anchor: Int
        let active: Int
        if let intent = richCellSelectionIntent, intent.table == table.range.location,
           intent.row == row, intent.column == column, intent.selection == original,
           intent.source.utf16.elementsEqual(index.source.utf16) {
            anchor = intent.anchor
            active = intent.active
        } else if original.length == 0 {
            anchor = original.location
            active = original.location
        } else {
            // For an externally selected range, AppKit identifies the active edge.
            navigator.setSelectedRange(visible, affinity: editor.selectionAffinity, stillSelecting: false)
            navigator.doCommand(by: selector)
            let proposed = navigator.selectedRange()
            if proposed.location == visible.location, NSMaxRange(proposed) != NSMaxRange(visible) {
                anchor = original.location
                active = NSMaxRange(original)
            } else if NSMaxRange(proposed) == NSMaxRange(visible), proposed.location != visible.location {
                anchor = NSMaxRange(original)
                active = original.location
            } else {
                richCellSelectionIntent = nil
                return proposed == visible
            }
        }
        navigator.setSelectedRange(NSRange(location: index.visibleOffset(active), length: 0),
            affinity: editor.selectionAffinity, stillSelecting: false)
        let move = NSStringFromSelector(selector).replacingOccurrences(of: "AndModifySelection", with: "")
        navigator.doCommand(by: NSSelectorFromString(move))
        let next = navigator.selectedRange().location
        let upstream = index.sourceOffset(next, downstream: false)
        let downstream = index.sourceOffset(next, downstream: true)
        // At a concealed boundary, retain the source edge nearest the previous active caret.
        let destination = abs(upstream - active) <= abs(downstream - active) ? upstream : downstream
        let selected = NSRange(location: min(anchor, destination), length: abs(destination - anchor))
        refreshing = true
        navigatingCellEmphasis = true
        editor.setSelectedRange(selected, affinity: navigator.selectionAffinity, stillSelecting: false)
        navigatingCellEmphasis = false
        refreshing = false
        richCellSelectionIntent = RichCellSelectionIntent(source: index.source, table: table.range.location,
            row: row, column: column, anchor: anchor, active: destination, selection: selected)
        emphasisTypingState.adopt()
        endTypingRun()
        updateEmphasisTypingAttributes()
        return true
    }
}
