import AppKit

extension NativeSemanticCommentHost {
    func cellEditor(_ id: UUID) -> NSTextView? {
        guard let owner else { return nil }
        for block in owner.snapshot().blocks {
            guard case .table(let table) = block.content,
                  table.identifiedRows.contains(where: { $0.cells.contains(where: { $0.id == id }) }) else { continue }
            return owner.documentStorage.tableSession(for: block.id)?.editor(for: id)
        }
        return nil
    }

    func attachCellThread(_ thread: MarkdownCommentThread, cellID: UUID, range: NSRange) {
        guard let editor = cellEditor(cellID), NSMaxRange(range) <= editor.string.utf16.count else { return }
        let tracker: MarkdownCommentStore
        if let existing = cellStores[cellID] { tracker = existing }
        else {
            tracker = MarkdownCommentStore()
            tracker.observeUndoBoundaries(of: owner?.documentUndoManager)
            tracker.onDisplayChange = { [weak self] in self?.store.onDisplayChange?() }
            cellStores[cellID] = tracker
            cellObservers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.willProcessEditingNotification, object: editor.textStorage, queue: nil
            ) { [weak tracker, weak storage = editor.textStorage] note in
                guard let (edit, text) = MarkdownCommentsController.characterEdit(in: note, of: storage) else { return }
                MainActor.assumeIsolated { tracker?.textDidChange(edit, text: text) }
            })
        }
        var visibleThread = thread
        visibleThread.anchor = MarkdownCommentAnchoring.selector(for: range, in: editor.string as NSString)
        tracker.add(visibleThread, range: range)
        if !(cellThreads[thread.id] ?? []).contains(cellID) { cellThreads[thread.id, default: []].append(cellID) }
    }

    func selectedCellTarget() -> NSRange? {
        guard let owner, let storage = owner.textView.textStorage else { return nil }
        var candidates: [(id: UUID, range: NSRange)] = []
        var target: NSRange?
        storage.enumerateAttribute(NativeSemanticAttributes.tableSession, in: NSRange(location: 0, length: storage.length)) { value, bodyRange, stop in
            guard let session = value as? NativeSemanticTableSession else { return }
            if let selection = session.cellSelection, session.grid?.window?.firstResponder === session.grid {
                for row in selection.rows {
                    guard session.topology.identifiedRows.indices.contains(row) else { continue }
                    for column in selection.columns {
                        guard session.topology.identifiedRows[row].cells.indices.contains(column) else { continue }
                        let cell = session.topology.identifiedRows[row].cells[column]
                        candidates.append((cell.id, NSRange(location: 0, length: cell.text.text.utf16.count)))
                    }
                }
            } else if let id = session.activeCellID, let editor = session.editor(for: id),
                      editor.window?.firstResponder === editor, editor.selectedRange().length > 0 {
                candidates = [(id, editor.selectedRange())]
            }
            guard !candidates.isEmpty else { return }
            target = bodyRange
            stop.pointee = true
        }
        if target != nil { pendingCells = candidates }
        return target
    }

    func posted(_ thread: MarkdownCommentThread) {
        for cell in pendingCells { attachCellThread(thread, cellID: cell.id, range: cell.range) }
        pendingCells = []
    }

    func cellRects(for id: String) -> [NSRect]? {
        guard let owner, let cellIDs = cellThreads[id] else { return nil }
        var result: [NSRect] = []
        for cellID in cellIDs {
            guard let range = cellStores[cellID]?.ranges[id] else { continue }
            if let editor = cellEditor(cellID), editor.window != nil, editor.superview != nil,
               let manager = editor.textLayoutManager, let content = manager.textContentManager,
               let start = content.location(content.documentRange.location, offsetBy: range.location),
               let end = content.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) {
                manager.enumerateTextSegments(in: textRange, type: .highlight, options: [.rangeNotRequired]) { _, frame, _, _ in
                    result.append(owner.textView.convert(frame.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y), from: editor))
                    return true
                }
            } else {
                for block in owner.snapshot().blocks {
                    guard case .table(let table) = block.content,
                          let session = owner.documentStorage.tableSession(for: block.id), let grid = session.grid else { continue }
                    for (row, cells) in table.identifiedRows.enumerated() {
                        guard let column = cells.cells.firstIndex(where: { $0.id == cellID }),
                              let rect = session.geometry().rect(of: CellCoord(row: row, column: column)) else { continue }
                        result.append(owner.textView.convert(rect, from: grid))
                    }
                }
            }
        }
        return result
    }
}
