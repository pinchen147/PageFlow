import AppKit

extension NativeTextViewCoordinator {
    func normalizedListSelection(_ selection: NSRange, in view: NSTextView) -> NSRange {
        guard selection.length == 0, listEditor.navigation == nil, !isApplyingSpanEdit,
              !isProgrammaticEdit, !isUpdatingSourceOrStyle, pendingEditedRange == nil,
              !isComposing(in: view), !isWritingToolsActive,
              let prefix = unorderedListPrefix(at: selection.location, in: view),
              selection.location < prefix.contentStart else {
            return normalizedEmphasisSelection(selection, in: view)
        }
        return normalizedEmphasisSelection(NSRange(location: prefix.contentStart, length: 0), in: view)
    }

    func normalizeCommittedListCaret(in view: NSTextView) {
        guard !listEditor.settling, listEditor.navigation == nil, !isApplyingSpanEdit,
              !isProgrammaticEdit, !isUpdatingSourceOrStyle, pendingEditedRange == nil,
              !isComposing(in: view), !isWritingToolsActive, view.selectedRange().length == 0,
              let prefix = unorderedListPrefix(at: view.selectedRange().location, in: view),
              view.selectedRange().location < prefix.contentStart else { return }
        let selection = normalizedListSelection(view.selectedRange(), in: view)
        guard selection != view.selectedRange() else { return }
        listEditor.settling = true
        defer { listEditor.settling = false }
        setCommittedCaret(selection, in: view)
    }

    func handleListCommand(_ selector: Selector, in view: NSTextView) -> Bool? {
        guard listEditor.navigation == nil, !isApplyingSpanEdit, !isProgrammaticEdit,
              !isComposing(in: view), !isWritingToolsActive, view.selectedRange().length == 0,
              let prefix = unorderedListPrefix(at: view.selectedRange().location, in: view) else { return nil }
        let command = NSStringFromSelector(selector)
        if command == "deleteBackward:" || command == "deleteWordBackward:" {
            let body = normalizedEmphasisSelection(NSRange(location: prefix.contentStart, length: 0), in: view)
            guard view.isEditable, view.selectedRange() == body else { return nil }
            let selection = view.selectedRange()
            applySourceFormat(prefix.marker > prefix.line.location ? "Outdent" : "Unlist", inverseSelection: selection) { text, _ in
                if prefix.marker > prefix.line.location {
                    return MarkdownSourceFormatting.indentListItems(outdent: true, in: text, selection: selection)
                }
                let range = NSRange(location: prefix.line.location, length: prefix.contentStart - prefix.line.location)
                return MarkdownSourceEdit(range: range, replacement: "",
                    selection: NSRange(location: selection.location - range.length, length: 0))
            }
            return true
        }
        let crossing = ["moveLeft:", "moveRight:", "moveBackward:", "moveForward:",
                        "moveWordLeft:", "moveWordRight:", "moveWordBackward:", "moveWordForward:"]
        let landing = ["moveUp:", "moveDown:", "moveToBeginningOfLine:", "moveToLeftEndOfLine:",
                       "moveToRightEndOfLine:", "moveToBeginningOfParagraph:", "moveToEndOfParagraph:",
                       "moveToBeginningOfDocument:", "moveToEndOfDocument:", "moveToEndOfLine:"]
        guard crossing.contains(command) || landing.contains(command) else { return nil }
        // Within a formatted body its existing owner still skips delimiters.
        // At the list boundary the structural owner must see native proposals.
        let body = normalizedEmphasisSelection(NSRange(location: prefix.contentStart, length: 0), in: view)
        if crossing.contains(command), view.selectedRange().location > body.location,
           let context = emphasisContext(in: view), !context.projection.hiddenDelimiterRanges.isEmpty { return nil }
        let previousNavigation = listEditor.navigation
        let originalLocation = view.selectedRange().location
        listEditor.navigation = selector
        defer { listEditor.navigation = previousNavigation }
        var remaining = body.location - prefix.line.location + 2
        var crossedLine = prefix.line.location
        repeat {
            let before = view.selectedRange()
            if !moveCaretRememberingTableEntry(selector, in: view, fromLocation: originalLocation) {
                view.perform(selector, with: nil)
            }
            if tableEditingSession.isActive { break }
            let after = view.selectedRange()
            guard crossing.contains(command), after != before, after.length == 0,
                  let destination = unorderedListPrefix(at: after.location, in: view) else { break }
            listEditor.navigation = previousNavigation
            let destinationBody = normalizedEmphasisSelection(NSRange(location: destination.contentStart, length: 0), in: view)
            listEditor.navigation = selector
            guard after.location < destinationBody.location else { break }
            if crossedLine != destination.line.location {
                remaining = destinationBody.location - destination.line.location + 2
                crossedLine = destination.line.location
            }
            remaining -= 1
        } while remaining > 0
        listEditor.navigation = previousNavigation
        if tableEditingSession.isActive { return true }
        emphasisSelectionDidChange(in: view)
        normalizeCommittedListCaret(in: view)
        normalizeCommittedEmphasisCaret(in: view)
        textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
        return true
    }
}
