import AppKit

extension NativeTextViewCoordinator {
    /// One source transaction for host commands such as Replace All. The host's
    /// expected snapshot prevents stale ranges from editing a different source.
    /// A replacement that adds or removes no line breaks may skip the paragraph
    /// chain reflow (`reflowsParagraphChain: false`). The edit selects what it
    /// inserted unless `selectionAfter` says otherwise (Redo restores the same).
    func replaceSourceRanges(
        _ ranges: [NSRange], with replacement: String, expectedSource: String, actionName: String,
        reflowsParagraphChain: Bool = true, insertedAttributes: [NSAttributedString.Key: Any]? = nil,
        registersUndo: Bool = true, selectionAfter: NSRange? = nil, preflighted: Bool = false, preservesBlockStructure: Bool = false,
        commentMove: MarkdownCommentMove? = nil, folding: MarkdownFoldTransfer? = nil
    ) -> Bool {
        let phaseStart = CFAbsoluteTimeGetCurrent()
        defer { PerfTrace.add("replace.total", since: phaseStart) }
        guard let tv = textView, preflighted || tv.isEditable,
              preflighted || (!isComposing(in: tv) && !isWritingToolsActive), !ranges.isEmpty,
              let storage = tv.textStorage,
              utf16(copiedUTF16(of: expectedSource as NSString), equals: storage.mutableString) else { return false }
        if #available(macOS 15.0, *), !preflighted, tv.isWritingToolsActive { return false }
        let source = storage.mutableString
        var previousEnd = 0
        var previousStart = -1
        func validBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < source.length else { return true }
            return !(0xD800...0xDBFF).contains(source.character(at: offset - 1))
                || !(0xDC00...0xDFFF).contains(source.character(at: offset))
        }
        for range in ranges {
            guard range.location >= 0, range.length >= 0, range.location <= source.length,
                  range.length <= source.length - range.location,
                  range.location >= previousEnd, range.location > previousStart,
                  validBoundary(range.location), validBoundary(range.location + range.length) else { return false }
            previousStart = range.location
            previousEnd = range.location + range.length
        }

        var admitted = true
        if !preflighted || folding == nil {
            for range in ranges where !admitFoldedEdit(range, in: tv) { admitted = false }
        }
        guard admitted else { return false }

        let start = ranges[0].location
        let span = NSRange(location: start, length: previousEnd - start)
        let replacementLength = (replacement as NSString).length
        var rebuilt = ""
        var cursor = start
        var delta = 0
        var inverseRanges: [NSRange] = []
        for range in ranges {
            rebuilt += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            rebuilt += replacement
            inverseRanges.append(NSRange(location: range.location + delta, length: replacementLength))
            delta += replacementLength - range.length
            cursor = range.location + range.length
        }
        let selection = selectionAfter ?? NSRange(location: start, length: replacementLength)
        // An identical replacement still acknowledges the command without
        // creating a dirty document or a redundant history entry.
        if (source.substring(with: span) as NSString).isEqual(to: rebuilt) {
            tv.setSelectedRange(selection)
            return true
        }
        let edit = SpanEdit(
            range: span, replacement: rebuilt, selectionAfter: selection, actionName: actionName,
            mapLocation: Self.replacementMap(ranges: ranges, lengths: ranges.map { _ in replacementLength }),
            inverseMapLocation: Self.replacementMap(ranges: inverseRanges, lengths: ranges.map(\.length)),
            inverseSelection: tv.selectedRange(), reflowsParagraphChain: reflowsParagraphChain,
            insertedAttributes: insertedAttributes, registersUndo: registersUndo, preflighted: preflighted, preservesBlockStructure: preservesBlockStructure,
            commentMove: commentMove, folding: folding
        )
        let undo = tv.undoManager
        let ownsGroup = registersUndo && undo?.groupingLevel == 0 && undo?.isUndoing == false && undo?.isRedoing == false
        if ownsGroup { undo?.beginUndoGrouping() }
        defer { if ownsGroup { undo?.endUndoGrouping() } }
        return performSpanEdit(edit, in: tv)
    }

    /// Follow source offsets through real edits, including arbitrary newline
    /// changes. Binary lookup keeps viewport pin mapping cheap for many matches.
    private static func replacementMap(ranges: [NSRange], lengths: [Int]) -> (Int) -> Int {
        var shift = 0
        let mappedStarts = ranges.indices.map { index in
            let start = ranges[index].location + shift
            shift += lengths[index] - ranges[index].length
            return start
        }
        return { location in
            var low = 0, high = ranges.count
            while low < high {
                let mid = (low + high) / 2
                if ranges[mid].location <= location { low = mid + 1 } else { high = mid }
            }
            guard low > 0 else { return location }
            let index = low - 1
            let range = ranges[index]
            let relative = location - range.location
            if relative < range.length { return mappedStarts[index] + min(relative, lengths[index]) }
            return location + mappedStarts[index] + lengths[index] - range.location - range.length
        }
    }
}
