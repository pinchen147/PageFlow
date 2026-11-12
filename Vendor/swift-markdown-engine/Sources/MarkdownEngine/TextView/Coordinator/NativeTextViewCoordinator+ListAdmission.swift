import AppKit

struct NativeListEditingState {
    struct Continuity {
        let snapshotSource: Int
        let document: Int
        var source: Int
        var insertions: [NSRange] = []
    }
    var continuity: Continuity?
    var pendingInsertion: (source: Int, document: Int)?
    var navigation: Selector?
    var settling = false
}

extension NativeTextViewCoordinator {
    struct ListPrefix {
        let line: NSRange
        let marker: Int
        let contentStart: Int
    }

    /// Admission comes from the document parser; only the candidate physical
    /// line is decoded. Ordinary body insertions can rebase that proof without
    /// keeping a second source copy or depending on the inline token ledger.
    func unorderedListPrefix(at location: Int, in view: NSTextView) -> ListPrefix? {
        guard configuration.lists.helpersEnabled, let item = listItem(at: location, in: view),
              !item.ordered, item.checkbox == nil else { return nil }
        return ListPrefix(line: item.range, marker: item.marker.location, contentStart: item.contentRange.location)
    }

    private func listItem(at location: Int, in view: NSTextView) -> ListItem? {
        guard let storage = view.textStorage,
              let block = currentListAdmissionBlock(at: location, in: view), block.kind == .list else { return nil }
        let line = NSIntersectionRange(storage.mutableString.lineRange(for: NSRange(location: location, length: 0)), block.range)
        guard line.length > 0,
              case .list(_, let items) = DocumentAST.node(for: Block(kind: .list, range: line),
                                                          ns: storage.mutableString, scopedRanges: []),
              items.count == 1 else { return nil }
        return items.first
    }

    private func currentListAdmissionBlock(at location: Int, in view: NSTextView) -> Block? {
        guard let storage = view.textStorage,
              location >= 0, location <= storage.length,
              let snapshot = cachedBlockParse, let revision = cachedBlockParseRevision,
              revision.document == documentGeneration else { return nil }
        let insertions: [NSRange]
        if revision.source == nativeSourceGeneration {
            insertions = []
        } else if let proof = listEditor.continuity,
                  proof.snapshotSource == revision.source, proof.source == nativeSourceGeneration,
                  proof.document == documentGeneration {
            insertions = proof.insertions
        } else { return nil }
        guard snapshot.characters.count + insertions.reduce(0, { $0 + $1.length }) == storage.length else { return nil }
        var original = location
        for insertion in insertions.reversed() where original > insertion.location {
            original -= min(original - insertion.location, insertion.length)
        }
        var low = 0, high = snapshot.blocks.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(snapshot.blocks[middle].range) <= original { low = middle + 1 }
            else { high = middle }
        }
        // A final item without a newline also owns its end-of-document caret.
        if low == snapshot.blocks.count, original == snapshot.characters.count { low -= 1 }
        guard low >= 0, low < snapshot.blocks.count else { return nil }
        var block = snapshot.blocks[low].range
        for insertion in insertions {
            if insertion.location < block.location { block.location += insertion.length }
            else if insertion.location <= NSMaxRange(block) { block.length += insertion.length }
        }
        return Block(kind: snapshot.blocks[low].kind, range: block)
    }

    func captureListInsertion(in view: NSTextView, change: TextChange) {
        listEditor.pendingInsertion = nil
        guard !isComposing(in: view), !isWritingToolsActive,
              !pendingEditMayChangeBlockStructure, !pendingEditRequiresFullDocumentRestyle,
              let text = view.textStorage?.mutableString, isFastPlainInsertion(change, in: text) else { return }
        if let item = listItem(at: change.oldRange.location, in: view) {
            // Other list kinds retain their native editing policy, but ordinary
            // body typing still shifts the proof for later unordered items.
            guard change.oldRange.location >= item.contentRange.location else { return }
        } else {
            // The accepted classifier excludes newlines and block delimiters,
            // including leading bullets/fences. Plain prose may grow at its
            // start without changing any existing unordered item's admission.
            guard let block = currentListAdmissionBlock(at: change.oldRange.location, in: view) else { return }
            switch block.kind {
            case .paragraph: break
            case .heading:
                guard case .heading(_, _, let markers, _) = DocumentAST.node(for: block, ns: text, scopedRanges: []),
                      let contentStart = markers.map({ NSMaxRange($0) }).max(),
                      change.oldRange.location >= contentStart else { return }
            default: return
            }
        }
        listEditor.pendingInsertion = (nativeSourceGeneration, documentGeneration)
    }

    /// Called only after the existing ordinary-insertion fast path accepts.
    func retainListInsertion(_ change: TextChange) {
        guard let pending = listEditor.pendingInsertion, pending.source == nativeSourceGeneration - 1,
              pending.document == documentGeneration, let revision = cachedBlockParseRevision else { return }
        if listEditor.continuity?.source != pending.source {
            guard revision.source == pending.source, revision.document == pending.document else { return }
            listEditor.continuity = .init(snapshotSource: revision.source, document: pending.document, source: pending.source)
        }
        let insertion = NSRange(location: change.oldRange.location, length: change.replacementLength)
        if let last = listEditor.continuity?.insertions.last, NSMaxRange(last) == insertion.location {
            let index = listEditor.continuity!.insertions.count - 1
            listEditor.continuity?.insertions[index].length += insertion.length
        } else { listEditor.continuity?.insertions.append(insertion) }
        listEditor.continuity?.source = nativeSourceGeneration
    }
}
