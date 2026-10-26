import AppKit

/// Where the reference editor's table chrome sits (doc 24 §5.3, §7.4.2), in the text
/// view's coordinates: grips, the table handle, the add bars, the wrapper the
/// pointer may roam without hiding them, and the drop boundaries of a grip
/// drag. Pure geometry: hover never asks TextKit anything.
struct TableChromeLayout: Equatable {
    /// Every cell's rect, row 0 the header.
    let cells: [[NSRect]]
    /// The part of the table the editor shows (a wide table's scroller span).
    let clip: NSRect
    let minimumHandleX: CGFloat?

    enum Zone: Equatable {
        case columnGrip, rowGrip, handle, addRow, addColumn, resize
    }

    init(cells: [[NSRect]], clip: NSRect = .infinite, minimumHandleX: CGFloat? = nil) {
        self.cells = cells
        self.clip = clip
        self.minimumHandleX = minimumHandleX
    }

    var table: NSRect {
        guard let first = cells.first?.first, let last = cells.last?.last else { return .zero }
        return first.union(last)
    }

    /// The table's left edge as shown (a scrolled wide table's visible left).
    var visibleLeft: CGFloat { max(table.minX, clip.minX) }
    var visibleRight: CGFloat { min(table.maxX, clip.maxX) }

    /// A column grip: a 24 × 14 box centred on the top border over the column.
    func columnGrip(_ column: Int) -> NSRect {
        guard let header = cells.first, header.indices.contains(column) else { return .zero }
        return NSRect(x: header[column].midX - 12, y: table.minY - 7, width: 24, height: 14)
    }

    /// A row grip: a 14 × 24 box centred on the left border beside the row.
    func rowGrip(_ row: Int) -> NSRect {
        guard cells.indices.contains(row), let cell = cells[row].first else { return .zero }
        return NSRect(x: visibleLeft - 7, y: cell.midY - 12, width: 14, height: 24)
    }

    /// The table handle: 26 × 26, 44 left of the table, level with its top.
    var handle: NSRect { NSRect(x: max(visibleLeft - 44, minimumHandleX ?? (visibleLeft - 44)), y: table.minY, width: 26, height: 26) }

    /// The add-row bar: the table's (visible) width, 18 under the bottom border.
    var addRowBar: NSRect { NSRect(x: visibleLeft, y: table.maxY, width: visibleRight - visibleLeft, height: 18) }

    /// The add-column bar: 18 right of the right border, only while that edge shows.
    var addColumnBar: NSRect? {
        guard table.maxX <= clip.maxX + 0.5, table.maxX >= clip.minX else { return nil }
        return NSRect(x: table.maxX, y: table.minY, width: 18, height: table.height)
    }

    /// The area that keeps the chrome while the pointer crosses it: the table,
    /// a 48 gutter on the left, 16 above, 18 below and right, and the bridge to
    /// the "…" button beside the top-right corner (bug fix b).
    var wrapper: NSRect {
        let body = NSRect(x: visibleLeft - 48, y: table.minY - 16, width: visibleRight - visibleLeft + 48 + 18, height: table.height + 16 + 18)
        let bridge = NSRect(x: visibleRight, y: table.minY - 4, width: 22 + 28 + 4, height: 28 + 8)
        return body.union(bridge)
    }

    /// The cell under `point`: binary searches over row and column edges.
    func cell(at point: NSPoint) -> CellCoord? {
        guard clip.contains(point) || clip.isInfinite, let header = cells.first, !header.isEmpty else { return nil }
        func search(_ count: Int, _ low: (Int) -> CGFloat, _ high: (Int) -> CGFloat, _ value: CGFloat) -> Int? {
            var lower = 0, upper = count - 1
            while lower <= upper {
                let middle = (lower + upper) / 2
                if value < low(middle) { upper = middle - 1 } else if value >= high(middle) { lower = middle + 1 } else { return middle }
            }
            return nil
        }
        guard let row = search(cells.count, { cells[$0][0].minY }, { cells[$0][0].maxY }, point.y),
              let column = search(header.count, { header[$0].minX }, { header[$0].maxX }, point.x) else { return nil }
        return CellCoord(row: row, column: column)
    }

    /// The chrome zone under `point` for the hovered cell, in the reference editor's hit order.
    func zone(at point: NSPoint, hovered: CellCoord, showsAddRow: Bool, showsAddColumn: Bool) -> Zone? {
        if columnGrip(hovered.column).insetBy(dx: -2, dy: -2).contains(point), columnGrip(hovered.column).midX >= clip.minX - 1,
           columnGrip(hovered.column).midX <= clip.maxX + 1 { return .columnGrip }
        if rowGrip(hovered.row).insetBy(dx: -2, dy: -2).contains(point) { return .rowGrip }
        if handle.contains(point) { return .handle }
        if showsAddRow, addRowBar.contains(point) { return .addRow }
        if showsAddColumn, let bar = addColumnBar, bar.contains(point) { return .addColumn }
        if resizeColumn(at: point) != nil { return .resize }
        return nil
    }

    /// The column whose right border is within −4…+5 pt of `point`, inside the
    /// table (doc 24 §5.7.7); the first column's left edge resizes nothing.
    func resizeColumn(at point: NSPoint) -> Int? {
        guard point.y >= table.minY, point.y <= table.maxY, clip.isInfinite || clip.contains(point) else { return nil }
        let edges = columnBoundaries
        for index in 1..<edges.count where point.x >= edges[index] - 4 - 1 && point.x <= edges[index] + 5 - 1 {
            return index - 1
        }
        return nil
    }

    // MARK: - Drop boundaries (grip drag)

    /// Column boundaries: each column's left edge, then the table's right edge.
    var columnBoundaries: [CGFloat] { (cells.first?.map(\.minX) ?? []) + [table.maxX] }
    /// Row boundaries: each row's top edge, then the table's bottom edge.
    var rowBoundaries: [CGFloat] { cells.compactMap { $0.first?.minY } + [table.maxY] }

    /// The nearest valid boundary to `value`. Rows never drop above the header.
    func nearestBoundary(to value: CGFloat, rows: Bool) -> Int {
        let edges = rows ? rowBoundaries : columnBoundaries
        let candidates = rows ? Array(1..<edges.count) : Array(edges.indices)
        return candidates.min { abs(edges[$0] - value) < abs(edges[$1] - value) } ?? 0
    }
}
