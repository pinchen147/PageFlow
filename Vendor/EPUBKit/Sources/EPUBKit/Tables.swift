import AppKit
import Foundation

/// A book table, laid out by TextKit 1 from `NSTextTableBlock` paragraphs.
/// It remembers how narrow its content can get, so the reader can shrink
/// the text of a table too wide for the page.
public final class EPUBTextTable: NSTextTable {
    /// The widest word of each column added up, at the size the chapter was rendered.
    public var minimumTextWidth: CGFloat = 0
    /// Padding and borders across all columns, in points at that size.
    public var fixedWidth: CGFloat = 0
    /// Each column's widest word and longest line, at that size; empty for
    /// a nested table, which lays itself out.
    var narrowestColumns: [CGFloat] = []
    var widestColumns: [CGFloat] = []

    /// Column content widths for a page `width` points wide with every
    /// size multiplied by `scale`: each column's longest line when they
    /// all fit, else shares of the page between narrowest and widest.
    func columnWidths(fitting width: CGFloat, scale: CGFloat) -> (widths: [CGFloat], type: NSTextBlock.ValueType)? {
        let fixed = fixedWidth * scale
        guard !widestColumns.isEmpty, width > fixed else { return nil }
        let available = width - fixed
        let widest = widestColumns.map { $0 * scale }
        let narrowest = narrowestColumns.map { $0 * scale }
        let sumWidest = widest.reduce(0, +)
        let sumNarrowest = narrowest.reduce(0, +)
        if sumWidest <= available { return (widest, .absoluteValueType) }
        let share = sumNarrowest >= available ? 0 : (available - sumNarrowest) / (sumWidest - sumNarrowest)
        let fitted = zip(narrowest, widest).map { $0 + ($1 - $0) * share }
        let total = fitted.reduce(0, +)
        // Shares of the page, so the table spans it whatever the text does.
        return (fitted.map { $0 / total * available / width * 100 }, .percentageValueType)
    }

    /// Each column's widest word as `text` sets it now, for this table's cells
    /// in `range`. Measured, since a face set small isn't the same face scaled.
    public func widestWords(in text: NSAttributedString, range: NSRange) -> [CGFloat] {
        var widest = [CGFloat](repeating: 0, count: numberOfColumns)
        let string = text.string as NSString
        text.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
            guard let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock, cell.table === self,
                  cell.columnSpan == 1, widest.indices.contains(cell.startingColumn) else { return }
            var start = run.location
            while start < NSMaxRange(run) {
                var stop = start
                while stop < NSMaxRange(run), !TableBuilder.isBreak(string.character(at: stop)) { stop += 1 }
                if stop > start {
                    // Without its cell, or the word measures as the cell would lay it out.
                    let word = NSMutableAttributedString(attributedString: text.attributedSubstring(
                        from: NSRange(location: start, length: stop - start)))
                    word.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: word.length))
                    widest[cell.startingColumn] = max(widest[cell.startingColumn], ceil(word.size().width))
                }
                start = stop + 1
            }
        }
        return widest
    }

    /// How much the text must shrink to fit `width` when every size is
    /// multiplied by `scale`; 1 when it fits.
    public func shrinkFactor(toFit width: CGFloat, scale: CGFloat) -> CGFloat {
        let text = minimumTextWidth * scale
        guard text > 0, text + fixedWidth * scale > width else { return 1 }
        return max(0, (width - fixedWidth * scale) / text)
    }
}

/// Copies table blocks for another text size and theme. Every paragraph of
/// one cell must keep sharing one block, so copies are made once per block.
public struct EPUBTextBlockStyler {
    private let scale: CGFloat
    private let borderColor: NSColor
    private let textWidth: CGFloat?
    private var tables: [ObjectIdentifier: NSTextTable] = [:]
    private var blocks: [ObjectIdentifier: NSTextBlock] = [:]
    private var columnWidths: [ObjectIdentifier: (widths: [CGFloat], type: NSTextBlock.ValueType)] = [:]

    /// With a `textWidth`, columns are sized again for that page width.
    public init(scale: CGFloat, borderColor: NSColor, textWidth: CGFloat? = nil) {
        self.scale = scale
        self.borderColor = borderColor
        self.textWidth = textWidth
    }

    /// Lays `table`'s copy out with these column content widths, in points.
    public mutating func setColumnWidths(_ widths: [CGFloat], for table: NSTextTable) {
        columnWidths[ObjectIdentifier(table)] = (widths, .absoluteValueType)
    }

    public mutating func restyled(_ source: [NSTextBlock]) -> [NSTextBlock] {
        var copies: [NSTextBlock] = []
        for block in source { copies.append(restyled(block)) }
        return copies
    }

    private mutating func restyled(_ block: NSTextBlock) -> NSTextBlock {
        if let done = blocks[ObjectIdentifier(block)] { return done }
        guard let cell = block as? NSTextTableBlock else { return block }
        let copy = NSTextTableBlock(table: restyled(table: cell.table), startingRow: cell.startingRow,
                                    rowSpan: cell.rowSpan, startingColumn: cell.startingColumn,
                                    columnSpan: cell.columnSpan)
        copyGeometry(from: cell, to: copy)
        if cell.columnSpan == 1, let sized = columnWidths(of: cell.table),
           sized.widths.indices.contains(cell.startingColumn) {
            columnWidths[ObjectIdentifier(cell.table)] = sized
            copy.setValue(sized.widths[cell.startingColumn], type: sized.type, for: .width)
        }
        blocks[ObjectIdentifier(block)] = copy
        return copy
    }

    private func columnWidths(of table: NSTextTable) -> (widths: [CGFloat], type: NSTextBlock.ValueType)? {
        if let sized = columnWidths[ObjectIdentifier(table)] { return sized }
        guard let textWidth, let table = table as? EPUBTextTable else { return nil }
        return table.columnWidths(fitting: textWidth, scale: scale)
    }

    private mutating func restyled(table: NSTextTable) -> NSTextTable {
        if let done = tables[ObjectIdentifier(table)] { return done }
        let copy = EPUBTextTable()
        copy.numberOfColumns = table.numberOfColumns
        copy.layoutAlgorithm = table.layoutAlgorithm
        copy.collapsesBorders = table.collapsesBorders
        copy.hidesEmptyCells = table.hidesEmptyCells
        if let source = table as? EPUBTextTable {
            copy.minimumTextWidth = source.minimumTextWidth
            copy.fixedWidth = source.fixedWidth
            copy.narrowestColumns = source.narrowestColumns
            copy.widestColumns = source.widestColumns
        }
        copyGeometry(from: table, to: copy)
        tables[ObjectIdentifier(table)] = copy
        return copy
    }

    private func copyGeometry(from source: NSTextBlock, to copy: NSTextBlock) {
        for layer in [NSTextBlock.Layer.padding, .border, .margin] {
            for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] {
                let type = source.widthValueType(for: layer, edge: edge)
                let width = source.width(for: layer, edge: edge)
                copy.setWidth(type == .absoluteValueType ? width * scale : width, type: type, for: layer, edge: edge)
            }
        }
        for dimension in [NSTextBlock.Dimension.width, .minimumWidth, .maximumWidth,
                          .height, .minimumHeight, .maximumHeight] {
            let type = source.valueType(for: dimension)
            let value = source.value(for: dimension)
            guard value != 0 else { continue }
            copy.setValue(type == .absoluteValueType ? value * scale : value, type: type, for: dimension)
        }
        copy.verticalAlignment = source.verticalAlignment
        copy.backgroundColor = source.backgroundColor
        for edge in [NSRectEdge.minX, .minY, .maxX, .maxY] where source.borderColor(for: edge) != nil {
            copy.setBorderColor(borderColor, for: edge)
        }
    }
}

/// One `<table>` being read: its grid, so cells land in the right column
/// past earlier rowspans, and its cells, measured when the table ends.
final class TableBuilder {
    static let cellPadding: CGFloat = 5
    static let borderWidth: CGFloat = 1
    private static let maxColumns = 64
    private static let maxSpan = 1_000

    let table = EPUBTextTable()
    /// The blocks the table sits in (a table nested in a cell).
    let outerBlocks: [NSTextBlock]
    private var row = -1
    private var column = 0
    private var occupied: Set<Int> = []
    private var cells: [(range: NSRange, column: Int, span: Int, block: NSTextTableBlock)] = []
    private var openCellStart: Int?

    init(outerBlocks: [NSTextBlock]) {
        self.outerBlocks = outerBlocks
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.numberOfColumns = 1
        table.setWidth(Metrics.tableMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(Metrics.tableMargin, type: .absoluteValueType, for: .margin, edge: .maxY)
    }

    private enum Metrics {
        static let tableMargin: CGFloat = 8
    }

    func startRow() {
        row += 1
        column = 0
    }

    /// The block for the next cell of the current row.
    func startCell(attributes: [String: String], at location: Int) -> NSTextTableBlock {
        if row < 0 { startRow() }
        func span(_ name: String) -> Int {
            min(Self.maxSpan, max(1, attributes[name].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 1))
        }
        let rowSpan = span("rowspan")
        var columnSpan = span("colspan")
        while occupied.contains(key(row, column)) { column += 1 }
        column = min(column, Self.maxColumns - 1)
        columnSpan = min(columnSpan, Self.maxColumns - column)
        for r in row..<(row + rowSpan) {
            for c in column..<(column + columnSpan) { occupied.insert(key(r, c)) }
        }
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: rowSpan,
                                     startingColumn: column, columnSpan: columnSpan)
        block.setWidth(Self.cellPadding, type: .absoluteValueType, for: .padding)
        block.setWidth(Self.borderWidth, type: .absoluteValueType, for: .border)
        block.setBorderColor(.labelColor)
        block.verticalAlignment = .topAlignment
        table.numberOfColumns = max(table.numberOfColumns, column + columnSpan)
        cells.append((NSRange(location: location, length: 0), column, columnSpan, block))
        openCellStart = location
        column += columnSpan
        return block
    }

    func endCell(at location: Int) {
        guard let start = openCellStart, let last = cells.indices.last else { return }
        cells[last].range = NSRange(location: start, length: max(0, location - start))
        openCellStart = nil
    }

    private func key(_ row: Int, _ column: Int) -> Int { row * Self.maxColumns + column }

    /// Sizes the columns to their content, as a browser would: each as wide
    /// as its longest line when the table fits `width` (the page's text
    /// width), else shared out between narrowest and widest. Records how
    /// narrow the content can get, for styling to shrink a table that
    /// still doesn't fit.
    func finish(in text: NSAttributedString, width: CGFloat) {
        let columns = table.numberOfColumns
        var narrowest = [CGFloat](repeating: 0, count: columns)
        var widest = [CGFloat](repeating: 0, count: columns)
        let string = text.string as NSString
        let measured = cells.prefix(4_000).filter {
            $0.span == 1 && $0.range.length > 0 && NSMaxRange($0.range) <= text.length
        }
        for cell in measured {
            var start = cell.range.location
            var lineStart = start
            let end = NSMaxRange(cell.range)
            while start <= end {
                var stop = start
                while stop < end, !Self.isBreak(string.character(at: stop)) { stop += 1 }
                if stop > start {
                    let word = text.attributedSubstring(from: NSRange(location: start, length: stop - start))
                    narrowest[cell.column] = max(narrowest[cell.column], ceil(word.size().width))
                }
                if stop >= end || string.character(at: stop) == 0x0A {
                    let line = text.attributedSubstring(from: NSRange(location: lineStart, length: stop - lineStart))
                    widest[cell.column] = max(widest[cell.column], ceil(line.size().width))
                    lineStart = stop + 1
                }
                start = stop + 1
            }
        }
        table.minimumTextWidth = narrowest.reduce(0, +)
        table.fixedWidth = CGFloat(columns) * (Self.cellPadding * 2 + Self.borderWidth) + Self.borderWidth
        // Only a top-level table knows its width; a nested one lays itself out.
        guard outerBlocks.isEmpty, columns > 1 else { return }
        // Room for a wider font family than the one measured.
        table.widestColumns = zip(widest, narrowest).map { max($0 * 1.15 + 2, $1, Self.minimumColumn) }
        table.narrowestColumns = narrowest.map { max($0, Self.minimumColumn) }
        guard let sized = table.columnWidths(fitting: width, scale: 1) else { return }
        for cell in cells where cell.span == 1 {
            cell.block.setValue(sized.widths[cell.column], type: sized.type, for: .width)
        }
    }

    /// A table's margin only spaces its cells' own blocks, so the text after
    /// it would start against its border: in vertical chapters, its ink on it.
    func keepNextParagraphClear(at location: Int, in text: NSMutableAttributedString) {
        guard outerBlocks.isEmpty, location < text.length else { return }
        let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        text.enumerateAttribute(.paragraphStyle, in: paragraph) { value, range, _ in
            guard let source = value as? NSParagraphStyle, source.textBlocks.isEmpty,
                  source.paragraphSpacingBefore < Metrics.tableMargin,
                  let style = source.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.paragraphSpacingBefore = Metrics.tableMargin
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private static let minimumColumn: CGFloat = 18

    /// Spaces end a word; CJK breaks between any two characters.
    fileprivate static func isBreak(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x09 || character == 0x200B
            || (0x2E80...0xD7AF).contains(character) || (0xF900...0xFAFF).contains(character)
            || (0xFF00...0xFFEF).contains(character)
    }
}
