import Foundation

/// The import boundary consumes the existing block parser's immutable snapshot.
/// Each independent envelope can be exported verbatim until its semantic value changes.
enum SemanticMarkdownImport {
    static func decode(_ source: String) throws -> SemanticMarkdownDocument {
        let ns = source as NSString
        let regions = MarkdownAlignmentStyling.regions(in: ns)
        guard !regions.isEmpty else { return try decodePlain(source) }
        var blocks: [SemanticMarkdownBlock] = []
        var segments: [SemanticSourceMap.Segment] = []
        var visibleOffset = 0
        var cursor = 0
        func append(_ range: NSRange, alignment: MarkdownTextAlignment? = nil, envelope: NSRange? = nil) throws {
            let part = try decodePlain(ns.substring(with: range))
            for block in part.blocks {
                let blockAlignment: MarkdownTextAlignment?
                if case .blank = block.content { blockAlignment = nil } else { blockAlignment = alignment }
                let origin = block.origin.map { old in
                    SemanticMarkdownBlock.Origin(source: old.source,
                        range: NSRange(location: old.range.location + range.location, length: old.range.length),
                        content: old.content, alignment: blockAlignment, alignmentEnvelope: envelope, lineEnding: old.lineEnding)
                }
                blocks.append(SemanticMarkdownBlock(id: block.id, content: block.content, origin: origin,
                    lineEnding: block.lineEnding, alignment: blockAlignment))
            }
            segments += part.sourceMap.segments.map { $0.shifted(sourceBy: range.location, visibleBy: visibleOffset) }
            visibleOffset += part.visibleText.utf16.count
        }
        for region in regions {
            if region.open.location > cursor { try append(NSRange(location: cursor, length: region.open.location - cursor)) }
            let envelope = NSRange(location: region.open.location, length: NSMaxRange(region.close) - region.open.location)
            let alignment = MarkdownSourceFormatting.alignmentTag(in: ns.substring(with: region.open).trimmingCharacters(in: .newlines))
            segments.append(.init(source: NSRange(location: envelope.location, length: region.body.location - envelope.location),
                                  visible: NSRange(location: visibleOffset, length: 0), kind: .delimiter))
            try append(region.body, alignment: alignment, envelope: envelope)
            segments.append(.init(source: NSRange(location: NSMaxRange(region.body), length: NSMaxRange(envelope) - NSMaxRange(region.body)),
                                  visible: NSRange(location: visibleOffset, length: 0), kind: .delimiter))
            cursor = NSMaxRange(envelope)
        }
        if cursor < ns.length { try append(NSRange(location: cursor, length: ns.length - cursor)) }
        let visible = blocks.map(\.visibleText).joined()
        return SemanticMarkdownDocument(blocks: blocks, sourceOrigin: source,
            sourceMap: SemanticSourceMap(segments: segments, sourceUTF16Count: ns.length,
                visibleUTF16Count: visible.utf16.count, sourceText: source, visibleText: visible))
    }

    private static func decodePlain(_ source: String) throws -> SemanticMarkdownDocument {
        let ns = source as NSString
        let snapshot = BlockParser.snapshot(parsing: ns)
        var blocks: [SemanticMarkdownBlock] = []
        var segments: [SemanticSourceMap.Segment] = []
        var visibleOffset = 0
        for block in snapshot.blocks {
            let imported = try importBlock(block, source: ns)
            blocks.append(imported.block)
            segments += imported.segments.map { $0.shifted(sourceBy: block.range.location, visibleBy: visibleOffset) }
            visibleOffset += imported.block.visibleText.utf16.count
        }
        let visible = blocks.map(\.visibleText).joined()
        return SemanticMarkdownDocument(blocks: blocks, sourceOrigin: source,
            sourceMap: SemanticSourceMap(segments: segments, sourceUTF16Count: ns.length,
                visibleUTF16Count: visible.utf16.count, sourceText: source, visibleText: visible))
    }

    private struct Imported {
        let block: SemanticMarkdownBlock
        let segments: [SemanticSourceMap.Segment]
    }

    private static func importBlock(_ block: Block, source: NSString) throws -> Imported {
        let raw = source.substring(with: block.range)
        let local = raw as NSString
        let bodyEnd = contentEnd(local, range: NSRange(location: 0, length: local.length))
        let ending = local.substring(from: bodyEnd)
        var segments: [SemanticSourceMap.Segment] = []
        var visibleOffset = 0
        func add(_ range: NSRange, visibleLength: Int, kind: SemanticSourceMap.Kind) {
            guard range.length > 0 || visibleLength > 0 else { return }
            segments.append(.init(source: range,
                visible: NSRange(location: visibleOffset, length: visibleLength), kind: kind))
            visibleOffset += visibleLength
        }
        func inline(_ range: NSRange) throws -> SemanticInlineText {
            let result = try SemanticInlineCodec.decodeWithSourceMap(local.substring(with: range), htmlPolicy: .preserveOpaque)
            segments += result.map.segments.map { $0.shifted(sourceBy: range.location, visibleBy: visibleOffset) }
            visibleOffset += result.text.utf16Count
            return result.text
        }
        func lineEnding(from start: Int, through end: Int) {
            add(NSRange(location: start, length: end - start), visibleLength: end - start, kind: .lineEnding)
        }
        func result(_ content: SemanticMarkdownBlock.Content, ending: String = "") -> Imported {
            Imported(block: SemanticMarkdownBlock(content: content, originalSource: raw,
                originalRange: block.range, lineEnding: ending), segments: segments)
        }
        let localBlock = Block(kind: block.kind, range: NSRange(location: 0, length: local.length))
        switch block.kind {
        case .paragraph:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") {
                add(localBlock.range, visibleLength: 0, kind: .delimiter)
                return result(.metadata(raw))
            }
            let text = try inline(NSRange(location: 0, length: bodyEnd))
            lineEnding(from: bodyEnd, through: local.length)
            if text.runs.count == 1, case .object(.opaque) = text.runs[0].payload {
                return result(.opaque(local.substring(to: bodyEnd)), ending: ending)
            }
            return result(.paragraph(text), ending: ending)
        case .heading:
            guard case .heading(let level, _, let markers, _) = DocumentAST.node(for: localBlock, ns: local, scopedRanges: []) else {
                preconditionFailure("heading block must produce a heading node")
            }
            let start = markers.last.map(NSMaxRange) ?? 0
            add(NSRange(location: 0, length: start), visibleLength: 0, kind: .delimiter)
            let text = try inline(NSRange(location: start, length: bodyEnd - start))
            lineEnding(from: bodyEnd, through: local.length)
            return result(.heading(level: level, text: text), ending: ending)
        case .list:
            guard case .list(_, let parsed) = DocumentAST.node(for: localBlock, ns: local, scopedRanges: []) else {
                preconditionFailure("list block must produce list items")
            }
            var items: [SemanticMarkdownListItem] = []
            for item in parsed {
                add(NSRange(location: item.range.location, length: item.contentRange.location - item.range.location),
                    visibleLength: 0, kind: .delimiter)
                let text = try inline(item.contentRange)
                let end = NSMaxRange(item.contentRange)
                let itemEnding = local.substring(with: NSRange(location: end, length: NSMaxRange(item.range) - end))
                lineEnding(from: end, through: NSMaxRange(item.range))
                items.append(.init(orderedStart: item.ordered ? item.number : nil, indent: item.indent,
                    checked: item.checkbox == nil ? nil : item.checked, text: text, lineEnding: itemEnding))
            }
            return result(.list(items))
        case .blockquote:
            var lines: [SemanticMarkdownQuoteLine] = []
            var cursor = 0
            while cursor < local.length {
                let line = local.lineRange(for: NSRange(location: cursor, length: 0))
                let end = contentEnd(local, range: line)
                var start = cursor
                while start < end, local.character(at: start) == 32 || local.character(at: start) == 9 { start += 1 }
                var depth = 0
                while start < end, local.character(at: start) == 62 {
                    depth += 1
                    start += 1
                    if start < end, local.character(at: start) == 32 { start += 1 }
                }
                add(NSRange(location: cursor, length: start - cursor), visibleLength: 0, kind: .delimiter)
                let text = try inline(NSRange(location: start, length: end - start))
                let lineEnd = NSMaxRange(line)
                lines.append(.init(depth: depth, text: text,
                    lineEnding: local.substring(with: NSRange(location: end, length: lineEnd - end))))
                lineEnding(from: end, through: lineEnd)
                cursor = lineEnd
            }
            return result(.quote(lines))
        case .fencedCode:
            guard let fence = FencedCode.scan(in: local, range: localBlock.range) else {
                preconditionFailure("fenced block must contain an opening fence")
            }
            let body = local.substring(with: fence.content)
            let terminal = fence.isClosed ? ending : ""
            add(NSRange(location: 0, length: fence.isClosed ? bodyEnd : local.length), visibleLength: 1, kind: .object)
            if fence.isClosed { lineEnding(from: bodyEnd, through: local.length) }
            return result(.code(language: fence.language(in: local), body: body, isClosed: fence.isClosed), ending: terminal)
        case .blockLatex:
            let body = raw.range(of: "$$").flatMap { opening in
                raw.range(of: "$$", range: opening.upperBound..<raw.endIndex).map {
                    String(raw[opening.upperBound..<$0.lowerBound])
                }
            }
            add(NSRange(location: 0, length: bodyEnd), visibleLength: 1, kind: .object)
            lineEnding(from: bodyEnd, through: local.length)
            return result(body.map(SemanticMarkdownBlock.Content.math) ?? .opaque(local.substring(to: bodyEnd)), ending: ending)
        case .table:
            guard let table = MarkdownTableSource(source: raw, range: localBlock.range) else {
                preconditionFailure("table block must satisfy the shared table scanner")
            }
            let rows = try table.rows.enumerated().filter { $0.offset != 1 }.map { _, row in
                try row.cells.map { cell in
                    try SemanticTableCellCodec.decode(local.substring(with: cell.contentRange))
                }
            }
            let alignment = MarkdownTableScanner.alignments(in: local.substring(with: table.rows[1].contentRange)) ?? []
            add(NSRange(location: 0, length: bodyEnd), visibleLength: 1, kind: .object)
            lineEnding(from: bodyEnd, through: local.length)
            return result(.table(.init(rows: rows, alignments: alignment)), ending: ending)
        case .thematicBreak:
            add(NSRange(location: 0, length: bodyEnd), visibleLength: 1, kind: .object)
            lineEnding(from: bodyEnd, through: local.length)
            return result(.separator, ending: ending)
        case .blank:
            add(localBlock.range, visibleLength: local.length, kind: .lineEnding)
            return result(.blank(raw))
        }
    }

    static func contentEnd(_ source: NSString, range: NSRange) -> Int {
        var end = NSMaxRange(range)
        if end > range.location, source.character(at: end - 1) == 10 { end -= 1 }
        if end > range.location, source.character(at: end - 1) == 13 { end -= 1 }
        return end
    }

}
