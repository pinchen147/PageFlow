import AppKit

/// Search coordinates span prose, retained cells, and dedicated source editors.
@MainActor
struct NativeSemanticSearchIndex {
    struct Segment {
        let search: NSRange
        let local: NSRange
        let table: NativeSemanticTableSession?
        let cellID: UUID?
        var sourceBlock: NativeSemanticSourceBlockSession? = nil
    }
    let text: String
    let segments: [Segment]

    init(owner: NativeSemanticDocumentCoordinator) {
        var text = ""
        var segments: [Segment] = []
        if let storage = owner.textView.textStorage {
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                if let block = attributes[NativeSemanticSourceBlockSession.attribute] as? NativeSemanticSourceBlockSession {
                    let source = block.committedSource()
                    segments.append(Segment(search: NSRange(location: text.utf16.count, length: source.utf16.count),
                        local: NSRange(location: 0, length: source.utf16.count), table: nil, cellID: nil, sourceBlock: block))
                    text += source
                } else if let table = attributes[NativeSemanticAttributes.tableSession] as? NativeSemanticTableSession {
                    for (rowIndex, row) in table.snapshot().identifiedRows.enumerated() {
                        if rowIndex > 0 { text += "\n" }
                        for (column, cell) in row.cells.enumerated() {
                            if column > 0 { text += "\t" }
                            let string = cell.text.text
                            segments.append(Segment(search: NSRange(location: text.utf16.count, length: string.utf16.count),
                                local: NSRange(location: 0, length: string.utf16.count), table: table, cellID: cell.id))
                            text += string
                        }
                    }
                    // Preserve the paragraph ending after the single table object.
                    if range.length > 1 {
                        let tail = NSRange(location: range.location + 1, length: range.length - 1)
                        let string = (storage.string as NSString).substring(with: tail)
                        segments.append(Segment(search: NSRange(location: text.utf16.count, length: tail.length), local: tail, table: nil, cellID: nil))
                        text += string
                    }
                } else {
                    if let last = segments.last, last.table == nil, last.sourceBlock == nil,
                       NSMaxRange(last.local) == range.location {
                        segments[segments.count - 1] = Segment(
                            search: NSRange(location: last.search.location, length: last.search.length + range.length),
                            local: NSRange(location: last.local.location, length: last.local.length + range.length), table: nil, cellID: nil)
                    } else {
                        segments.append(Segment(search: NSRange(location: text.utf16.count, length: range.length), local: range, table: nil, cellID: nil))
                    }
                    text += (storage.string as NSString).substring(with: range)
                }
            }
        }
        self.text = text
        self.segments = segments
    }

    func target(for range: NSRange) -> (Segment, NSRange)? {
        guard let segment = segments.first(where: { range.location >= $0.search.location && NSMaxRange(range) <= NSMaxRange($0.search) }) else { return nil }
        return (segment, NSRange(location: segment.local.location + range.location - segment.search.location, length: range.length))
    }
}

extension NativeSemanticDocumentCoordinator {
    func replaceSearchRanges(_ ranges: [NSRange], with replacement: String, expectedText: String, actionName: String) -> NSRange? {
        guard textView.isEditable, !hasActiveComposition, !isWritingToolsActive, !ranges.isEmpty else { return nil }
        let index = NativeSemanticSearchIndex(owner: self)
        guard index.text.utf16.elementsEqual(expectedText.utf16) else { return nil }
        var body: [NSRange] = []
        var sourceEdits: [(NativeSemanticSourceBlockSession, NSRange)] = []
        var tables: [ObjectIdentifier: (NativeSemanticTableSession, SemanticMarkdownTable)] = [:]
        var previousStart = index.text.utf16.count
        do {
            for range in ranges.sorted(by: { $0.location > $1.location }) {
                guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= previousStart,
                      let (segment, local) = index.target(for: range) else { return nil }
                previousStart = range.location
                if let block = segment.sourceBlock {
                    guard !block.protectedInput, block.textView.isEditable else { return nil }
                    sourceEdits.append((block, local))
                } else if let table = segment.table, let cellID = segment.cellID {
                    guard table.editor(for: cellID)?.hasMarkedText() != true else { return nil }
                    let key = ObjectIdentifier(table)
                    var value = tables[key]?.1 ?? table.snapshot()
                    for row in value.identifiedRows.indices {
                        guard let column = value.identifiedRows[row].cells.firstIndex(where: { $0.id == cellID }) else { continue }
                        let cell = value.identifiedRows[row].cells[column].text
                        let inherited = try cell.slice(in: local).runs.first?.marks ?? []
                        value.identifiedRows[row].cells[column].text = try cell.replacing(local, with: .init(text: replacement, marks: inherited))
                    }
                    tables[key] = (table, value)
                } else { body.append(local) }
            }
            documentUndoManager.beginUndoGrouping()
            defer { documentUndoManager.endUndoGrouping() }
            if !body.isEmpty, replaceVisibleRanges(ranges: body, with: replacement, expectedText: textView.string, actionName: actionName) == nil { return nil }
            for (block, range) in sourceEdits {
                block.textView.insertText(replacement, replacementRange: range)
                block.textView.breakUndoCoalescing()
            }
            for (_, (table, value)) in tables { _ = table.replaceTopology(value, name: actionName) }
            documentUndoManager.setActionName(actionName)
            return NSRange(location: ranges.map(\.location).min() ?? 0, length: replacement.utf16.count)
        } catch { onExportFailure?(error); return nil }
    }
}
