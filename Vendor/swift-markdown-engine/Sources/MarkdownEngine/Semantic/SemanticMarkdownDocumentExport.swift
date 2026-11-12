import Foundation

extension SemanticMarkdownImport {
    enum ExportFailure: Error { case unrepresentableCodeBody, invalidStructure, invalidOrigin, roundTripMismatch }
    private typealias Piece = SemanticMarkdownExportResult.Piece

    static func encode(_ document: SemanticMarkdownDocument) throws -> String { try export(document).source }

    static func export(_ document: SemanticMarkdownDocument) throws -> SemanticMarkdownExportResult {
        let base = document.sourceOrigin as NSString
        var pieces: [Piece] = []
        var blockRanges: [UUID: NSRange] = [:]
        var offset = 0
        var emittedEnvelopes = Set<NSRange>()
        for block in document.blocks {
            if let envelope = block.origin?.alignmentEnvelope {
                let indices = document.blocks.indices.filter { document.blocks[$0].origin?.alignmentEnvelope == envelope }
                let members = indices.map { document.blocks[$0] }
                guard let first = indices.first, let last = indices.last else { throw ExportFailure.invalidOrigin }
                if last - first + 1 != indices.count {
                    let text = try generatedBlock(block)
                    blockRanges[block.id] = generatedContentRange(block, sourceLength: text.utf16.count, offset: offset)
                    append([.generated(text)], to: &pieces)
                    offset += text.utf16.count
                    continue
                }
                if emittedEnvelopes.contains(envelope) { continue }
                emittedEnvelopes.insert(envelope)
                guard envelope.location >= 0, NSMaxRange(envelope) <= base.length else { throw ExportFailure.invalidOrigin }
                let original = try decode(base.substring(with: envelope))
                let unchanged = members.count == original.blocks.count && zip(members, original.blocks).allSatisfy {
                    $0.content == $1.content && $0.alignment == $1.alignment && $0.lineEnding == $1.lineEnding
                }
                if unchanged {
                    for member in members {
                        if let range = member.originalRange {
                            blockRanges[member.id] = NSRange(location: offset + range.location - envelope.location, length: range.length)
                        }
                    }
                    append([.original(envelope)], to: &pieces)
                    offset += envelope.length
                } else {
                    for member in members {
                        let text = try generatedBlock(member)
                        blockRanges[member.id] = generatedContentRange(member, sourceLength: text.utf16.count, offset: offset)
                        append([.generated(text)], to: &pieces)
                        offset += text.utf16.count
                    }
                }
                continue
            }
            if let origin = block.origin {
                guard origin.range.location >= 0, origin.range.length >= 0,
                      origin.range.location <= base.length, origin.range.length <= base.length - origin.range.location,
                      base.substring(with: origin.range).utf16.elementsEqual(origin.source.utf16) else {
                    throw ExportFailure.invalidOrigin
                }
            }
            let blockPieces: [Piece]
            if let origin = block.origin, block.content == origin.content, block.alignment == origin.alignment,
               block.lineEnding.utf16.elementsEqual(origin.lineEnding.utf16) {
                blockPieces = [.original(origin.range)]
            } else if case .table(let table) = block.content, block.alignment == nil {
                blockPieces = try tablePieces(table, block: block)
            } else {
                blockPieces = [.generated(try generatedBlock(block))]
            }
            let length = try rendered(blockPieces, base: base).utf16.count
            blockRanges[block.id] = generatedContentRange(block, sourceLength: length, offset: offset)
            offset += length
            append(blockPieces, to: &pieces)
        }
        let source = try rendered(pieces, base: base)
        // Validation covers both changed envelopes and their current neighboring seams.
        let reopened = try decode(source)
        guard reopened.isSemanticallyEquivalent(to: document) else { throw ExportFailure.roundTripMismatch }
        var cellRanges: [UUID: NSRange] = [:]
        for block in document.blocks {
            guard case .table(let table) = block.content, let range = blockRanges[block.id],
                  let scanned = MarkdownTableSource(source: source, range: range) else { continue }
            let rows = scanned.rows.enumerated().filter { $0.offset != 1 }.map(\.element)
            guard rows.count == table.identifiedRows.count else { throw ExportFailure.roundTripMismatch }
            for (row, spans) in zip(table.identifiedRows, rows) {
                guard row.cells.count == spans.cells.count else { throw ExportFailure.roundTripMismatch }
                for (cell, span) in zip(row.cells, spans.cells) { cellRanges[cell.id] = span.contentRange }
            }
        }
        return SemanticMarkdownExportResult(originSource: document.sourceOrigin, source: source, pieces: pieces, sourceMap: reopened.sourceMap,
                                            blockRanges: blockRanges, cellRanges: cellRanges)
    }

    private static func rendered(_ pieces: [Piece], base: NSString) throws -> String {
        try pieces.map { piece in
            switch piece {
            case .original(let range):
                guard range.location >= 0, range.length >= 0, range.location <= base.length,
                      range.length <= base.length - range.location else { throw ExportFailure.invalidOrigin }
                return base.substring(with: range)
            case .generated(let text): return text
            }
        }.joined()
    }

    private static func append(_ additions: [Piece], to result: inout [Piece]) {
        for piece in additions {
            switch piece {
            case .original(let range) where range.length == 0: continue
            case .generated(let text) where text.isEmpty: continue
            default: break
            }
            if case .original(let next) = piece, case .original(let previous) = result.last,
               NSMaxRange(previous) == next.location {
                result[result.count - 1] = .original(NSRange(location: previous.location, length: previous.length + next.length))
            } else { result.append(piece) }
        }
    }

    private static func generatedContentRange(_ block: SemanticMarkdownBlock, sourceLength: Int, offset: Int) -> NSRange {
        guard let alignment = block.alignment else { return NSRange(location: offset, length: sourceLength) }
        let prefix = ("<div align=\"" + alignment.rawValue + "\">\n\n").utf16.count
        let suffix = "\n</div>\n".utf16.count
        return NSRange(location: offset + prefix, length: max(0, sourceLength - prefix - suffix))
    }

    private static func generatedBlock(_ block: SemanticMarkdownBlock) throws -> String {
        if let alignment = block.alignment {
            var plain = block
            plain.alignment = nil
            let body = try generatedBlock(plain)
            guard body.hasSuffix("\n") else { throw ExportFailure.invalidStructure }
            return "<div align=\"" + alignment.rawValue + "\">\n\n" + body + "\n</div>\n"
        }
        let ending = block.lineEnding
        switch block.content {
        case .paragraph(let text): return try SemanticInlineCodec.encode(text) + ending
        case .heading(let level, let text):
            guard (1...6).contains(level) else { throw ExportFailure.invalidStructure }
            let encoded = try SemanticInlineCodec.encode(text)
            // Spaces after an ATX marker belong to its delimiter. Encode literal
            // leading spaces so native text remains part of the heading value.
            let leadingSpaces = encoded.prefix { $0 == " " }.count
            let body = String(repeating: "&#32;", count: leadingSpaces) + encoded.dropFirst(leadingSpaces)
            return String(repeating: "#", count: level) + " " + body + ending
        case .list(let items):
            return try items.map { item in
                guard item.indent >= 0 else { throw ExportFailure.invalidStructure }
                let marker = item.orderedStart.map { "\($0)." } ?? "-"
                let task = item.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
                return String(repeating: " ", count: item.indent) + marker + " " + task
                    + (try SemanticInlineCodec.encode(item.text)) + item.lineEnding
            }.joined()
        case .quote(let lines):
            return try lines.map { line in
                guard line.depth > 0 else { throw ExportFailure.invalidStructure }
                return String(repeating: ">", count: line.depth) + " "
                    + (try SemanticInlineCodec.encode(line.text)) + line.lineEnding
            }.joined()
        case .code(let language, let body, let closed):
            if closed, !body.isEmpty, !body.hasSuffix("\n"), !body.hasSuffix("\r") { throw ExportFailure.unrepresentableCodeBody }
            var maximum = 0, consecutive = 0
            for unit in body.utf16 {
                consecutive = unit == 96 ? consecutive + 1 : 0
                maximum = max(maximum, consecutive)
            }
            let fence = String(repeating: "`", count: max(3, maximum + 1))
            return fence + (language ?? "") + newline(for: block) + body + (closed ? fence + ending : "")
        case .math(let body): return "$$" + body + "$$" + ending
        case .table: throw ExportFailure.invalidStructure
        case .separator: return "---" + ending
        case .blank(let raw), .metadata(let raw): return raw
        case .opaque(let raw): return raw + ending
        }
    }

    private static func newline(for block: SemanticMarkdownBlock) -> String {
        (block.origin?.source.contains("\r\n") == true || block.lineEnding == "\r\n") ? "\r\n" : "\n"
    }

    private static func tablePieces(_ table: SemanticMarkdownTable, block: SemanticMarkdownBlock) throws -> [Piece] {
        guard let header = table.identifiedRows.first, !table.alignments.isEmpty,
              header.cells.count == table.alignments.count else { throw ExportFailure.invalidStructure }
        let newline = newline(for: block)
        func rowSource(_ row: SemanticMarkdownTableRow) throws -> String {
            "| " + (try row.cells.map { try SemanticTableCellCodec.encode($0.text) }).joined(separator: " | ") + " |"
        }
        let alignment = table.alignments.map { value -> String in
            switch value { case .left: return "---"; case .center: return ":---:"; case .right: return "---:" }
        }
        guard let origin = block.origin, case .table(let original) = origin.content,
              original.alignments == table.alignments,
              original.identifiedRows.first?.id == header.id,
              let scanned = MarkdownTableSource(source: origin.source, range: NSRange(location: 0, length: origin.source.utf16.count)) else {
            var rows = [try rowSource(header), "| " + alignment.joined(separator: " | ") + " |"]
            rows += try table.identifiedRows.dropFirst().map(rowSource)
            return [.generated(rows.joined(separator: newline) + block.lineEnding)]
        }
        let physical = scanned.rows.enumerated().filter { $0.offset != 1 }.map(\.element)
        let indexed = Dictionary(uniqueKeysWithValues: original.identifiedRows.enumerated().map { ($0.element.id, $0.offset) })
        let local = origin.source as NSString
        var pieces: [Piece] = []
        func sourcePiece(_ range: NSRange) -> Piece {
            .original(NSRange(location: origin.range.location + range.location, length: range.length))
        }
        func endingPieces(_ row: MarkdownTableScanner.Row, desired: String) -> [Piece] {
            local.substring(with: row.lineEndingRange).utf16.elementsEqual(desired.utf16)
                ? [sourcePiece(row.lineEndingRange)] : [.generated(desired)]
        }
        for (rowIndex, row) in table.identifiedRows.enumerated() {
            let isLast = rowIndex == table.identifiedRows.count - 1 && rowIndex != 0
            if let oldIndex = indexed[row.id], physical.indices.contains(oldIndex),
               row.cells.count == original.identifiedRows[oldIndex].cells.count {
                let raw = physical[oldIndex]
                var cursor = raw.contentRange.location
                for column in row.cells.indices where row.cells[column].text != original.identifiedRows[oldIndex].cells[column].text {
                    let cell = raw.cells[column]
                    let range = cell.contentRange.length == 0
                        ? NSRange(location: cell.rawRange.location + min(1, cell.rawRange.length), length: 0) : cell.contentRange
                    append([sourcePiece(NSRange(location: cursor, length: range.location - cursor)),
                            .generated(try SemanticTableCellCodec.encode(row.cells[column].text))], to: &pieces)
                    cursor = NSMaxRange(range)
                }
                append([sourcePiece(NSRange(location: cursor, length: NSMaxRange(raw.contentRange) - cursor))], to: &pieces)
                let oldEnding = local.substring(with: raw.lineEndingRange)
                let ending = isLast ? block.lineEnding : (oldEnding.isEmpty ? newline : oldEnding)
                append(endingPieces(raw, desired: ending), to: &pieces)
            } else {
                append([.generated(try rowSource(row) + (isLast ? block.lineEnding : newline))], to: &pieces)
            }
            if rowIndex == 0 {
                let separator = scanned.rows[1]
                append([sourcePiece(separator.contentRange)], to: &pieces)
                let oldEnding = local.substring(with: separator.lineEndingRange)
                let ending = table.identifiedRows.count == 1 ? block.lineEnding : (oldEnding.isEmpty ? newline : oldEnding)
                append(endingPieces(separator, desired: ending), to: &pieces)
            }
        }
        return pieces
    }
}
