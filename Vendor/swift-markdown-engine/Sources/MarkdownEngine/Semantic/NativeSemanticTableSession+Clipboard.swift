import AppKit

extension NativeSemanticTableSession {
    func handleRangeKey(_ event: NSEvent) -> Bool {
        guard let selection = cellSelection else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return copySelection(to: .general)
            case "x":
                guard isEditable, copySelection(to: .general) else { return false }
                var next = snapshot()
                for cell in selection.cells { next.identifiedRows[cell.row].cells[cell.column].text = .init(text: "") }
                return replaceTopology(next, name: "Cut Cells")
            case "v":
                guard isEditable, !hasActiveComposition else { return false }
                guard let text = NSPasteboard.general.string(forType: .string) else { return true }
                pasteCells(text, into: selection)
                return true
            default: return false
            }
        }
        if isEditable && (event.keyCode == 51 || event.keyCode == 117) {
            var next = snapshot()
            for cell in selection.cells { next.identifiedRows[cell.row].cells[cell.column].text = .init(text: "") }
            _ = replaceTopology(next, name: "Clear Cells")
            return true
        }
        return false
    }

    func pasteCells(_ text: String, into selection: TableCellSelection) {
        guard isEditable, !hasActiveComposition else { return }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        var next = snapshot()
        for (rowOffset, cells) in rows.enumerated() {
            let row = selection.rows.lowerBound + rowOffset
            guard next.identifiedRows.indices.contains(row) else { break }
            for (columnOffset, value) in cells.enumerated() {
                let column = selection.columns.lowerBound + columnOffset
                guard next.identifiedRows[row].cells.indices.contains(column) else { break }
                next.identifiedRows[row].cells[column].text = .init(text: value)
            }
        }
        _ = replaceTopology(next, name: "Paste Cells")
    }
}

extension NativeSemanticTableSession {
    func copySelection(to pasteboard: NSPasteboard, asMarkdown: Bool = false) -> Bool {
        do {
            if let selection = cellSelection {
                let table = snapshot()
                let rows = selection.rows.map { row in selection.columns.map { table.identifiedRows[row].cells[$0].text } }
                let text: String
                if asMarkdown {
                    let selectedTable = SemanticMarkdownTable(rows: rows, alignments: selection.columns.map { table.alignments[$0] })
                    let block = SemanticMarkdownBlock(content: .table(selectedTable), lineEnding: "\n")
                    let empty = try SemanticMarkdownImport.decode("")
                    let document = SemanticMarkdownDocument(blocks: [block], sourceOrigin: empty.sourceOrigin, sourceMap: empty.sourceMap)
                    text = try SemanticMarkdownImport.encode(document)
                } else { text = rows.map { $0.map(\.text).joined(separator: "\t") }.joined(separator: "\n") }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                if !asMarkdown { pasteboard.setString(text, forType: .tabularText) }
                return true
            }
            guard let activeCellID, let view = editor(for: activeCellID), let storage = view.textStorage else { return false }
            let range = view.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return false }
            let attributed = storage.attributedSubstring(from: range)
            let value = NativeSemanticAttributes.inlineText(attributed)
            let text = try asMarkdown ? SemanticInlineCodec.encode(value) : value.text
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if !asMarkdown, let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) { pasteboard.setData(rtf, forType: .rtf) }
            return true
        } catch { return false }
    }

    func pasteText(_ incoming: String, asMarkdown: Bool = false) -> Bool {
        let text = incoming.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard isEditable, !hasActiveComposition else { return false }
        do {
            if let selection = cellSelection {
                if !asMarkdown { pasteCells(text, into: selection); return true }
                let document = try SemanticMarkdownImport.decode(text)
                let substantive = document.blocks.filter { if case .blank = $0.content { return false }; return true }
                if substantive.count == 1, case .table(let pasted) = substantive[0].content {
                    var next = snapshot()
                    for (rowOffset, row) in pasted.rows.enumerated() {
                        let targetRow = selection.rows.lowerBound + rowOffset
                        guard next.identifiedRows.indices.contains(targetRow) else { break }
                        for (columnOffset, value) in row.enumerated() {
                            let column = selection.columns.lowerBound + columnOffset
                            guard next.identifiedRows[targetRow].cells.indices.contains(column) else { break }
                            next.identifiedRows[targetRow].cells[column].text = value
                        }
                    }
                    return replaceTopology(next, name: "Paste Cells")
                }
                var next = snapshot()
                next.identifiedRows[selection.rows.lowerBound].cells[selection.columns.lowerBound].text = try SemanticInlineCodec.decode(text)
                return replaceTopology(next, name: "Paste Markdown")
            }
            guard let activeCellID, let view = editor(for: activeCellID), !view.hasMarkedText() else { return false }
            if asMarkdown {
                let value = try SemanticInlineCodec.decode(text)
                let attributed = NativeSemanticAttributes.attributedText(value, font: view.font ?? .systemFont(ofSize: 14))
                view.insertText(attributed, replacementRange: view.selectedRange())
            } else if let cell = view as? NativeSemanticCellTextView { cell.insertLiteral(text) }
            else { return false }
            return true
        } catch { return false }
    }
}
