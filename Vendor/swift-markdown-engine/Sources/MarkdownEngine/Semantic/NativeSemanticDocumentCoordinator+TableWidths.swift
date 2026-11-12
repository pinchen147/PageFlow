import AppKit

extension NativeSemanticDocumentCoordinator {
    func refreshTableWidths() {
        guard let controller = tableWidthsController else { return }
        do {
            let document = snapshot()
            let receipt = try exportResult()
            let tables = document.blocks.compactMap { block -> (UUID, NSRange)? in
                guard case .table = block.content, let range = receipt.blockRanges[block.id] else { return nil }
                return (block.id, range)
            }
            let keys = NativeTextViewCoordinator.tableKeys(for: tables.map(\.1), in: receipt.source as NSString)
            tableWidthBindingRevision = revision
            var widths = controller.tableWidthsStore.widths
            for (id, range) in tables {
                guard let session = documentStorage.tableSession(for: id), let key = keys[range.location] else { continue }
                if let previous = session.widthKey, previous != key, let stored = widths.removeValue(forKey: previous) {
                    widths[key] = stored
                }
                session.widthKey = key
                session.columnWidths = widths[key] ?? []
                session.onColumnWidthsChange = { [weak self, weak session] value in
                    guard let self, let session, let controller = self.tableWidthsController, let key = session.widthKey else { return }
                    var updated = controller.tableWidthsStore.widths
                    if value.allSatisfy({ $0 == nil }) { updated.removeValue(forKey: key) }
                    else { updated[key] = value }
                    controller.tableColumnWidths = updated
                }
                session.refreshPresentation()
                documentStorage.refreshTableAttachment(id)
            }
            if widths != controller.tableWidthsStore.widths {
                controller.tableWidthsStore.widths = widths
                controller.onTableColumnWidthsChange?(widths)
            }
            tableWidthBindingRevision = revision
        } catch { onExportFailure?(error) }
    }
}
