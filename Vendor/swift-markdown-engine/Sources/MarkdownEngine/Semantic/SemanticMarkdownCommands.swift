import Foundation

enum SemanticMarkdownCommand {
    case replaceInline(block: UUID, range: NSRange, replacement: SemanticInlineText)
    case splitParagraph(block: UUID, at: Int)
    case joinParagraphs(first: UUID, second: UUID)
    case setHeading(block: UUID, level: Int?)
    case setList(block: UUID, orderedStart: Int?, checked: Bool?, indent: Int)
    case replaceCell(table: UUID, row: UUID, cell: UUID, text: SemanticInlineText)
    case insertRow(table: UUID, at: Int)
    case deleteRow(table: UUID, row: UUID)
    case moveRow(table: UUID, row: UUID, to: Int)
    case copyRow(table: UUID, row: UUID, to: Int)
    case insertColumn(table: UUID, at: Int)
    case deleteColumn(table: UUID, at: Int)
    case moveColumn(table: UUID, from: Int, to: Int)
    case copyColumn(table: UUID, from: Int, to: Int)
    case alignColumn(table: UUID, at: Int, alignment: MarkdownTableAlignment)
}

enum SemanticMarkdownCommands {
    enum Failure: Error { case missingOwner, invalidRange, protectedStructure, unsupportedBlock }

    /// Mutate a candidate value first: any rejected command leaves every native owner unchanged.
    static func apply(_ command: SemanticMarkdownCommand, to document: inout SemanticMarkdownDocument) throws {
        var blocks = document.blocks
        try apply(command, to: &blocks)
        document.blocks = blocks
    }

    private static func index(_ id: UUID, in blocks: [SemanticMarkdownBlock]) throws -> Int {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { throw Failure.missingOwner }
        return index
    }

    private static func inline(_ block: SemanticMarkdownBlock) throws -> SemanticInlineText {
        switch block.content {
        case .paragraph(let text), .heading(_, let text): return text
        case .list(let items) where items.count == 1: return items[0].text
        case .blank: return SemanticInlineText(text: "")
        default: throw Failure.unsupportedBlock
        }
    }

    private static func terminalEnding(_ block: SemanticMarkdownBlock) -> String {
        if case .list(let items) = block.content { return items.last?.lineEnding ?? block.lineEnding }
        return block.lineEnding
    }

    private static func apply(_ command: SemanticMarkdownCommand, to blocks: inout [SemanticMarkdownBlock]) throws {
        switch command {
        case .replaceInline(let id, let range, let replacement):
            let i = try index(id, in: blocks)
            let changed = try inline(blocks[i]).replacing(range, with: replacement)
            switch blocks[i].content {
            case .paragraph: blocks[i].content = .paragraph(changed)
            case .heading(let level, _): blocks[i].content = .heading(level: level, text: changed)
            default: throw Failure.unsupportedBlock
            }
        case .splitParagraph(let id, let offset):
            let i = try index(id, in: blocks)
            guard case .paragraph(let text) = blocks[i].content else { throw Failure.unsupportedBlock }
            _ = try SemanticInlineText.validatedBounds(NSRange(location: offset, length: 0), in: text.text)
            let left = try text.slice(in: NSRange(location: 0, length: offset))
            let right = try text.slice(in: NSRange(location: offset, length: text.utf16Count - offset))
            let ending = blocks[i].lineEnding
            let newline = ending.isEmpty ? "\n" : ending
            if left.text.isEmpty {
                blocks[i].content = .blank(newline)
                blocks[i].lineEnding = ""
                blocks.insert(.init(content: .paragraph(right), lineEnding: ending), at: i + 1)
            } else if right.text.isEmpty {
                blocks[i].content = .paragraph(left)
                blocks[i].lineEnding = newline
                blocks.insert(.init(content: .blank(newline)), at: i + 1)
            } else {
                blocks[i].content = .paragraph(left)
                blocks[i].lineEnding = newline
                blocks.insert(contentsOf: [.init(content: .blank(newline)),
                    .init(content: .paragraph(right), lineEnding: ending)], at: i + 1)
            }
        case .joinParagraphs(let first, let second):
            let a = try index(first, in: blocks), b = try index(second, in: blocks)
            guard a < b else { throw Failure.invalidRange }
            for block in blocks[(a + 1)..<b] {
                guard case .blank = block.content else { throw Failure.protectedStructure }
            }
            func paragraph(_ block: SemanticMarkdownBlock) throws -> SemanticInlineText {
                switch block.content {
                case .paragraph(let text): return text
                case .blank: return .init(text: "")
                default: throw Failure.unsupportedBlock
                }
            }
            let merged = SemanticInlineText(runs: try paragraph(blocks[a]).runs + paragraph(blocks[b]).runs)
            blocks[a].content = .paragraph(merged)
            blocks[a].lineEnding = blocks[b].lineEnding
            blocks.removeSubrange((a + 1)...b)
        case .setHeading(let id, let level):
            if let level, !(1...6).contains(level) { throw Failure.invalidRange }
            let i = try index(id, in: blocks)
            let text = try inline(blocks[i])
            let ending = terminalEnding(blocks[i])
            blocks[i].content = level.map { .heading(level: $0, text: text) } ?? .paragraph(text)
            blocks[i].lineEnding = ending
        case .setList(let id, let orderedStart, let checked, let indent):
            guard indent >= 0, orderedStart.map({ (0...999_999_999).contains($0) }) ?? true else {
                throw Failure.invalidRange
            }
            let i = try index(id, in: blocks)
            let text = try inline(blocks[i])
            let ending = terminalEnding(blocks[i])
            blocks[i].content = .list([.init(orderedStart: orderedStart, indent: indent, checked: checked,
                text: text, lineEnding: ending)])
            blocks[i].lineEnding = ""
        default:
            try applyTable(command, to: &blocks)
        }
    }

    private static func tableID(_ command: SemanticMarkdownCommand) throws -> UUID {
        switch command {
        case .replaceCell(let id, _, _, _), .insertRow(let id, _), .deleteRow(let id, _),
             .moveRow(let id, _, _), .copyRow(let id, _, _), .insertColumn(let id, _),
             .deleteColumn(let id, _), .moveColumn(let id, _, _), .copyColumn(let id, _, _),
             .alignColumn(let id, _, _): return id
        default: throw Failure.unsupportedBlock
        }
    }

    private static func applyTable(_ command: SemanticMarkdownCommand,
                                   to blocks: inout [SemanticMarkdownBlock]) throws {
        let blockIndex = try index(tableID(command), in: blocks)
        guard case .table(var table) = blocks[blockIndex].content,
              !table.identifiedRows.isEmpty, !table.alignments.isEmpty,
              table.identifiedRows[0].cells.count == table.alignments.count else { throw Failure.protectedStructure }
        let width = table.alignments.count
        func rowIndex(_ id: UUID) throws -> Int {
            guard let row = table.identifiedRows.firstIndex(where: { $0.id == id }) else { throw Failure.missingOwner }
            return row
        }
        func validColumn(_ index: Int, insertion: Bool = false) throws {
            guard index >= 0, index < width + (insertion ? 1 : 0) else { throw Failure.invalidRange }
        }
        func validRowDestination(_ index: Int, insertion: Bool) throws {
            guard index > 0, index < table.identifiedRows.count + (insertion ? 1 : 0) else {
                throw Failure.protectedStructure
            }
        }
        switch command {
        case .replaceCell(_, let rowID, let cellID, let text):
            let row = try rowIndex(rowID)
            guard let cell = table.identifiedRows[row].cells.firstIndex(where: { $0.id == cellID }) else {
                throw Failure.missingOwner
            }
            table.identifiedRows[row].cells[cell].text = text
        case .insertRow(_, let at):
            try validRowDestination(at, insertion: true)
            table.identifiedRows.insert(.init(cells: (0..<width).map { _ in .init(text: .init(text: "")) }), at: at)
        case .deleteRow(_, let id):
            let row = try rowIndex(id)
            guard row > 0 else { throw Failure.protectedStructure }
            table.identifiedRows.remove(at: row)
        case .moveRow(_, let id, let to):
            let from = try rowIndex(id)
            guard from > 0 else { throw Failure.protectedStructure }
            try validRowDestination(to, insertion: false)
            let row = table.identifiedRows.remove(at: from)
            table.identifiedRows.insert(row, at: to)
        case .copyRow(_, let id, let to):
            let from = try rowIndex(id)
            try validRowDestination(to, insertion: true)
            let copy = SemanticMarkdownTableRow(cells: table.identifiedRows[from].cells.map { .init(text: $0.text) })
            table.identifiedRows.insert(copy, at: to)
        case .insertColumn(_, let at):
            try validColumn(at, insertion: true)
            for row in table.identifiedRows.indices {
                while table.identifiedRows[row].cells.count < at {
                    table.identifiedRows[row].cells.append(.init(text: .init(text: "")))
                }
                table.identifiedRows[row].cells.insert(.init(text: .init(text: "")), at: at)
            }
            table.alignments.insert(.left, at: at)
        case .deleteColumn(_, let at):
            try validColumn(at)
            guard width > 1 else { throw Failure.protectedStructure }
            for row in table.identifiedRows.indices where table.identifiedRows[row].cells.indices.contains(at) {
                table.identifiedRows[row].cells.remove(at: at)
            }
            table.alignments.remove(at: at)
        case .moveColumn(_, let from, let to):
            try validColumn(from)
            try validColumn(to)
            for row in table.identifiedRows.indices {
                while table.identifiedRows[row].cells.count <= max(from, to) {
                    table.identifiedRows[row].cells.append(.init(text: .init(text: "")))
                }
                let cell = table.identifiedRows[row].cells.remove(at: from)
                table.identifiedRows[row].cells.insert(cell, at: to)
            }
            let alignment = table.alignments.remove(at: from)
            table.alignments.insert(alignment, at: to)
        case .copyColumn(_, let from, let to):
            try validColumn(from)
            try validColumn(to, insertion: true)
            for row in table.identifiedRows.indices {
                let text = table.identifiedRows[row].cells.indices.contains(from)
                    ? table.identifiedRows[row].cells[from].text : .init(text: "")
                while table.identifiedRows[row].cells.count < to {
                    table.identifiedRows[row].cells.append(.init(text: .init(text: "")))
                }
                table.identifiedRows[row].cells.insert(.init(text: text), at: to)
            }
            table.alignments.insert(table.alignments[from], at: to)
        case .alignColumn(_, let at, let alignment):
            try validColumn(at)
            table.alignments[at] = alignment
        default: throw Failure.unsupportedBlock
        }
        blocks[blockIndex].content = .table(table)
    }
}
