import AppKit

/// Keeps persisted source selectors separate from live native visible ranges.
@MainActor
final class NativeSemanticCommentHost {
    weak var owner: NativeSemanticDocumentCoordinator?
    let store: MarkdownCommentStore
    private var observer: NSObjectProtocol?
    var cellStores: [UUID: MarkdownCommentStore] = [:]
    var cellThreads: [String: [UUID]] = [:]
    var cellObservers: [NSObjectProtocol] = []
    var pendingCells: [(id: UUID, range: NSRange)] = []
    private var tableAnchors: [String: (anchor: MarkdownCommentAnchor, blockID: UUID, source: String)] = [:]

    init(owner: NativeSemanticDocumentCoordinator, store: MarkdownCommentStore) {
        self.owner = owner
        self.store = store
        store.observeUndoBoundaries(of: owner.documentUndoManager)
        observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.willProcessEditingNotification,
            object: owner.textView.textStorage, queue: nil
        ) { [weak self, weak storage = owner.textView.textStorage] note in
            guard let (edit, text) = MarkdownCommentsController.characterEdit(in: note, of: storage) else { return }
            MainActor.assumeIsolated { self?.store.textDidChange(edit, text: text) }
        }
    }

    func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        cellObservers.forEach(NotificationCenter.default.removeObserver)
        cellObservers.removeAll()
    }

    func load(_ threads: [MarkdownCommentThread]) throws {
        guard let owner else { return }
        let receipt = try owner.exportResult()
        store.load(threads, text: receipt.source as NSString)
        let count = owner.textView.string.utf16.count
        var mapped: [String: NSRange] = [:]
        tableAnchors.removeAll()
        cellStores.removeAll()
        cellThreads.removeAll()
        cellObservers.forEach(NotificationCenter.default.removeObserver)
        cellObservers.removeAll()
        let tableIDs = owner.snapshot().blocks.compactMap { block -> UUID? in
            if case .table = block.content { return block.id }
            return nil
        }
        for (id, range) in store.ranges {
            if let thread = store.thread(id), !thread.table {
                for (cellID, cellRange) in receipt.cellRanges {
                    let overlap = NSIntersectionRange(range, cellRange)
                    guard overlap.length > 0 else { continue }
                    let cellSource = (receipt.source as NSString).substring(with: cellRange)
                    let decoded = try SemanticTableCellCodec.decodeWithSourceMap(cellSource)
                    if let start = decoded.map.visibleOffset(for: .init(rawValue: overlap.location - cellRange.location), affinity: .trailing),
                       let end = decoded.map.visibleOffset(for: .init(rawValue: NSMaxRange(overlap) - cellRange.location), affinity: .leading), start.rawValue <= end.rawValue {
                        attachCellThread(thread, cellID: cellID, range: NSRange(location: start.rawValue, length: end.rawValue - start.rawValue))
                    }
                }
            }
            if let blockID = tableIDs.first(where: { id in
                guard let blockRange = receipt.blockRanges[id] else { return false }
                return NSIntersectionRange(blockRange, range).length > 0
            }), let blockRange = receipt.blockRanges[blockID], let thread = store.thread(id) {
                tableAnchors[id] = (thread.anchor, blockID, (receipt.source as NSString).substring(with: blockRange))
            }
            guard let start = receipt.sourceMap.visibleOffset(for: .init(rawValue: range.location), affinity: .trailing),
                  let end = receipt.sourceMap.visibleOffset(for: .init(rawValue: NSMaxRange(range)), affinity: .leading),
                  start.rawValue <= end.rawValue, end.rawValue <= count else { continue }
            mapped[id] = NSRange(location: start.rawValue, length: end.rawValue - start.rawValue)
        }
        store.installSemanticRanges(mapped, text: owner.textView.string as NSString)
    }

    func threadsForSaving() throws -> [MarkdownCommentThread] {
        guard let owner else { return store.threads }
        let receipt = try owner.exportResult()
        return store.threads.map { original in
            var thread = original
            if let cellIDs = cellThreads[thread.id] {
                var sourceRanges: [NSRange] = []
                for cellID in cellIDs {
                    guard let range = cellStores[cellID]?.ranges[thread.id], let sourceRange = receipt.cellRanges[cellID],
                          let decoded = try? SemanticTableCellCodec.decodeWithSourceMap((receipt.source as NSString).substring(with: sourceRange)),
                          let start = decoded.map.sourceOffset(for: .init(rawValue: range.location), affinity: .trailing),
                          let end = decoded.map.sourceOffset(for: .init(rawValue: NSMaxRange(range)), affinity: .leading), start.rawValue <= end.rawValue else { continue }
                    sourceRanges.append(NSRange(location: sourceRange.location + start.rawValue, length: end.rawValue - start.rawValue))
                }
                guard let first = sourceRanges.first, sourceRanges.count == cellIDs.count else {
                    thread.detached = true
                    return thread
                }
                let sourceRange = sourceRanges.dropFirst().reduce(first, NSUnionRange)
                thread.anchor = MarkdownCommentAnchoring.selector(for: sourceRange, in: receipt.source as NSString)
                return thread
            }
            if let table = tableAnchors[thread.id] {
                thread.anchor = table.anchor
                if thread.table, let range = receipt.blockRanges[table.blockID] {
                    thread.anchor = MarkdownCommentAnchoring.selector(for: range, in: receipt.source as NSString)
                    return thread
                }
                guard let range = receipt.blockRanges[table.blockID],
                      (receipt.source as NSString).substring(with: range).utf16.elementsEqual(table.source.utf16) else {
                    thread.detached = true
                    return thread
                }
                return thread
            }
            guard let range = store.ranges[thread.id],
                  let start = receipt.sourceMap.sourceOffset(for: .init(rawValue: range.location), affinity: .trailing),
                  let end = receipt.sourceMap.sourceOffset(for: .init(rawValue: NSMaxRange(range)), affinity: .leading),
                  start.rawValue <= end.rawValue else {
                thread.detached = true
                return thread
            }
            thread.anchor = MarkdownCommentAnchoring.selector(
                for: NSRange(location: start.rawValue, length: end.rawValue - start.rawValue),
                in: receipt.source as NSString)
            return thread
        }
    }

}
