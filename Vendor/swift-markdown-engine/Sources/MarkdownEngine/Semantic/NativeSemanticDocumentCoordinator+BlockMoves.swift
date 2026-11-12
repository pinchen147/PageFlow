import AppKit

extension NativeSemanticDocumentCoordinator {
    func moveSemanticBlock(kind: String, sourceRange: NSRange, to slot: Int, copying: Bool) -> Bool {
        guard textView.isEditable, !textView.hasMarkedText(), !isWritingToolsActive else { return false }
        do {
            let receipt = try exportResult()
            var document = snapshot()
            guard let from = document.blocks.firstIndex(where: { receipt.blockRanges[$0.id] == sourceRange }),
                  slot >= 0, slot <= receipt.source.utf16.count else { return false }
            let block = document.blocks[from]
            let matches: Bool
            switch (kind, block.content) {
            case ("table", .table), ("equation", .math), ("code", .code): matches = true
            case ("diagram", .code(let language, _, _)): matches = language == "mermaid"
            case ("image", .paragraph(let inline)):
                matches = inline.runs.count == 1 && {
                    if case .object(.image) = inline.runs[0].payload { return true }
                    return false
                }()
            default: matches = false
            }
            guard matches else { return false }
            let destination = document.blocks.firstIndex { receipt.blockRanges[$0.id]?.location == slot }
                ?? (slot == receipt.source.utf16.count ? document.blocks.count : -1)
            guard destination >= 0, destination != from, destination != from + 1 else { return false }
            if copying {
                var copy = SemanticMarkdownBlock(id: UUID(), content: block.content, origin: block.origin, lineEnding: block.lineEnding)
                copy.alignment = block.alignment
                if case .table(var table) = copy.content {
                    table.identifiedRows = table.identifiedRows.map { row in
                        .init(cells: row.cells.map { .init(text: $0.text) })
                    }
                    copy.content = .table(table)
                }
                document.blocks.insert(copy, at: destination)
            } else {
                document.blocks.remove(at: from)
                document.blocks.insert(block, at: destination > from ? destination - 1 : destination)
            }
            _ = try SemanticMarkdownImport.export(document)
            install(document, selection: textView.selectedRange(), actionName: copying ? "Copy Block" : "Move Block")
            return true
        } catch { onExportFailure?(error); return false }
    }

    func importSemanticImages(_ drop: MarkdownImageDrop, at sourceOffset: Int) {
        guard textView.isEditable, !textView.hasMarkedText(), !isWritingToolsActive,
              let importer = onImportImages else { return }
        do {
            let receipt = try exportResult()
            guard let visible = receipt.sourceMap.visibleOffset(for: .init(rawValue: sourceOffset), affinity: .leading) else { return }
            let expected = revision
            importer(drop) { [weak self] sources in
                guard let self, self.revision == expected, self.textView.isEditable,
                      !self.textView.hasMarkedText(), !self.isWritingToolsActive, !sources.isEmpty else { return }
                self.textView.setSelectedRange(NSRange(location: visible.rawValue, length: 0))
                _ = self.pasteText(sources.joined(separator: "\n"), asMarkdown: true)
            }
        } catch { onExportFailure?(error) }
    }
}
