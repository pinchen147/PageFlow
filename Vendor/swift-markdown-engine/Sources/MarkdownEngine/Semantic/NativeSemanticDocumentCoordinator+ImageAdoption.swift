import AppKit

extension NativeSemanticDocumentCoordinator {
    /// Resource adoption changes object descriptors, never source offsets in native storage.
    func adoptImageLinks(ranges: [NSRange], replacements: [String], expectedSource: String) throws -> Bool {
        guard ranges.count == replacements.count, !textView.hasMarkedText(),
              try exportResult().source.utf16.elementsEqual(expectedSource.utf16),
              textView.isEditable else { return false }
        let source = expectedSource as NSString
        var substitutions: [(SemanticInlineObject, SemanticInlineObject)] = []
        for (range, replacement) in zip(ranges, replacements) {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length else { return false }
            let before = try SemanticInlineCodec.decode(source.substring(with: range))
            let after = try SemanticInlineCodec.decode(replacement)
            guard before.runs.count == 1, after.runs.count == 1,
                  case .object(let old) = before.runs[0].payload,
                  case .image = old,
                  case .object(let new) = after.runs[0].payload,
                  case .image = new else { return false }
            substitutions.append((old, new))
        }
        var changed = false
        func update(_ inline: SemanticInlineText) -> SemanticInlineText {
            SemanticInlineText(runs: inline.runs.map { run in
                guard case .object(let descriptor) = run.payload,
                      let replacement = substitutions.first(where: { $0.0 == descriptor })?.1 else { return run }
                changed = true
                return SemanticInlineRun(object: replacement, marks: run.marks, link: run.link)
            })
        }
        var document = snapshot()
        for index in document.blocks.indices {
            switch document.blocks[index].content {
            case .paragraph(let text): document.blocks[index].content = .paragraph(update(text))
            case .heading(let level, let text): document.blocks[index].content = .heading(level: level, text: update(text))
            case .list(var items):
                for index in items.indices { items[index].text = update(items[index].text) }
                document.blocks[index].content = .list(items)
            case .quote(var lines):
                for index in lines.indices { lines[index].text = update(lines[index].text) }
                document.blocks[index].content = .quote(lines)
            case .table(var table):
                for row in table.identifiedRows.indices {
                    for column in table.identifiedRows[row].cells.indices {
                        table.identifiedRows[row].cells[column].text = update(table.identifiedRows[row].cells[column].text)
                    }
                }
                document.blocks[index].content = .table(table)
            default: break
            }
        }
        guard changed else { return false }
        _ = try SemanticMarkdownImport.export(document)
        install(document, selection: textView.selectedRange(), actionName: "Move Pasted Images")
        return true
    }
}
