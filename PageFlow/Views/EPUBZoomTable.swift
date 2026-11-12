//
//  EPUBZoomTable.swift
//  PageFlow
//
//  Finds the table under a point in a chapter's text (the renderer builds
//  each as an `NSTextTable`) and lays it out at its natural width for the
//  zoom panel.
//

import AppKit
import EPUBKit

enum EPUBZoomTable {
    /// Space around the table in the panel.
    static let inset = NSSize(width: 24, height: 20)

    // MARK: - Finding

    /// The whole table holding `index`, or nil when it is not in one.
    static func range(at index: Int, in text: NSAttributedString) -> NSRange? {
        guard index >= 0, index < text.length else { return nil }
        guard let style = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
              let block = style.textBlocks.last(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock else { return nil }
        let range = text.range(of: block.table, at: index)
        return range.length > 0 ? range : nil
    }

    // MARK: - Laying out

    /// The table at its natural width, without its last paragraph break: the
    /// panel ends at the last row. Its columns are its longest lines: on the
    /// page they may be shares of the width, which here would be the whole layout.
    static func layout(_ table: NSAttributedString) -> (text: NSAttributedString, width: CGFloat) {
        let text = NSMutableAttributedString(attributedString: table)
        while text.length > 0, text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        guard text.length > 0 else { return (text, 200) }
        guard let columns = NaturalColumns(of: text) else { return (text, max(600, naturalWidth(of: text))) }
        columns.apply(to: text)
        return (text, columns.tableWidth)
    }

    private static func naturalWidth(of text: NSAttributedString) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: 100_000, height: 100_000),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).width)
    }

    /// A table's columns as wide as their longest lines, read from its cells
    /// at the size they are drawn.
    private struct NaturalColumns {
        private static let minimumColumn: CGFloat = 18
        /// Rounding room, so a line measured whole doesn't wrap by a fraction.
        private static let slack: CGFloat = 2

        private let table: NSTextTable
        private let widths: [CGFloat]
        private let padding: CGFloat
        private let border: CGFloat
        private let borderColor: NSColor

        /// Nil for text that isn't laid out as a table.
        init?(of text: NSAttributedString) {
            guard let first = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.first as? NSTextTableBlock else { return nil }
            let table = first.table
            var widths = [CGFloat](repeating: Self.minimumColumn, count: table.numberOfColumns)
            var spanning: [(block: NSTextTableBlock, width: CGFloat)] = []
            let string = text.string as NSString
            string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                       options: [.byParagraphs, .substringNotRequired]) { _, line, _, _ in
                let location = min(line.location, text.length - 1)
                guard let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
                      let block = style.textBlocks.first as? NSTextTableBlock, block.table === table,
                      widths.indices.contains(block.startingColumn) else { return }
                let width = Self.width(of: text.attributedSubstring(from: line)) + style.headIndent + Self.slack
                if block.columnSpan == 1 {
                    widths[block.startingColumn] = max(widths[block.startingColumn], width)
                } else {
                    spanning.append((block, width))
                }
            }
            // What a spanning cell still needs goes to the last column it covers.
            let padding = first.width(for: .padding, edge: .minX)
            let border = first.width(for: .border, edge: .minX)
            for (block, width) in spanning {
                let end = min(block.startingColumn + block.columnSpan, widths.count)
                let covered = widths[block.startingColumn..<end].reduce(0, +)
                    + CGFloat(end - block.startingColumn - 1) * (padding * 2 + border)
                if width > covered { widths[end - 1] += width - covered }
            }
            self.table = table
            self.widths = widths
            self.padding = padding
            self.border = border
            borderColor = first.borderColor(for: .minX) ?? .separatorColor
        }

        /// A cell's paragraph on its own: measured in its block, it takes the block's width.
        private static func width(of line: NSAttributedString) -> CGFloat {
            let plain = NSMutableAttributedString(attributedString: line)
            plain.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: plain.length))
            return ceil(plain.size().width)
        }

        var tableWidth: CGFloat {
            ceil(widths.reduce(0, +) + CGFloat(widths.count) * (padding * 2 + border) + border)
        }

        func apply(to text: NSMutableAttributedString) {
            // Copies: the page's text shares these blocks.
            var styler = EPUBTextBlockStyler(scale: 1, borderColor: borderColor)
            styler.setColumnWidths(widths, for: table)
            var copies: [ObjectIdentifier: NSParagraphStyle] = [:]
            text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let source = value as? NSParagraphStyle, !source.textBlocks.isEmpty else { return }
                let key = ObjectIdentifier(source)
                if copies[key] == nil, let copy = source.mutableCopy() as? NSMutableParagraphStyle {
                    copy.textBlocks = styler.restyled(source.textBlocks)
                    copies[key] = copy
                }
                if let copy = copies[key] { text.addAttribute(.paragraphStyle, value: copy, range: range) }
            }
        }
    }

    /// A read-only, selectable TextKit 1 view of the laid-out table, in a
    /// plain view of its size: the scroll view resizes a text view it holds.
    static func textView(_ text: NSAttributedString, width: CGFloat, background: NSColor) -> NSView {
        let storage = NSTextStorage(attributedString: text)
        let layout = EPUBPageLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: width + inset.width * 2, height: ceil(used.height) + inset.height * 2)
        let view = EPUBZoomTableView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        view.storage = storage
        view.textContainerInset = inset
        view.isEditable = false
        view.isSelectable = true
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.drawsBackground = true
        view.backgroundColor = background
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setAccessibilityLabel("Table")
        view.setFrameSize(size)
        let holder = NSView(frame: NSRect(origin: .zero, size: size))
        holder.addSubview(view)
        return holder
    }
}

/// Keeps its hand-built text stack alive, as page text views do.
final class EPUBZoomTableView: NSTextView {
    var storage: NSTextStorage?
}
