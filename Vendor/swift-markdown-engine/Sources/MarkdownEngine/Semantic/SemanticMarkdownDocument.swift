import Foundation

struct SemanticMarkdownListItem: Equatable {
    var orderedStart: Int?
    var indent: Int
    var checked: Bool?
    var text: SemanticInlineText
    var lineEnding: String
}

struct SemanticMarkdownQuoteLine: Equatable {
    var depth: Int
    var text: SemanticInlineText
    var lineEnding: String
}

struct SemanticMarkdownTableCell: Identifiable, Equatable {
    let id: UUID
    var text: SemanticInlineText

    init(id: UUID = UUID(), text: SemanticInlineText) {
        self.id = id
        self.text = text
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }
}

struct SemanticMarkdownTableRow: Identifiable, Equatable {
    let id: UUID
    var cells: [SemanticMarkdownTableCell]

    init(id: UUID = UUID(), cells: [SemanticMarkdownTableCell]) {
        self.id = id
        self.cells = cells
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.cells == rhs.cells }
}

struct SemanticMarkdownTable: Equatable {
    var identifiedRows: [SemanticMarkdownTableRow]
    var alignments: [MarkdownTableAlignment]

    init(rows: [[SemanticInlineText]], alignments: [MarkdownTableAlignment]) {
        identifiedRows = rows.map { SemanticMarkdownTableRow(cells: $0.map { .init(text: $0) }) }
        self.alignments = alignments
    }

    /// Text replacement preserves identities by position. Structural moves use
    /// `identifiedRows` directly so identity follows the moved native owner.
    var rows: [[SemanticInlineText]] {
        get { identifiedRows.map { $0.cells.map(\.text) } }
        set {
            identifiedRows = newValue.enumerated().map { rowIndex, texts in
                let previous = identifiedRows.indices.contains(rowIndex) ? identifiedRows[rowIndex] : nil
                let cells = texts.enumerated().map { column, text in
                    SemanticMarkdownTableCell(
                        id: previous.flatMap { $0.cells.indices.contains(column) ? $0.cells[column].id : nil } ?? UUID(),
                        text: text)
                }
                return SemanticMarkdownTableRow(id: previous?.id ?? UUID(), cells: cells)
            }
        }
    }
}

struct SemanticMarkdownBlock: Identifiable {
    enum Content: Equatable {
        case paragraph(SemanticInlineText)
        case heading(level: Int, text: SemanticInlineText)
        case list([SemanticMarkdownListItem])
        case quote([SemanticMarkdownQuoteLine])
        case code(language: String?, body: String, isClosed: Bool)
        case math(String)
        case table(SemanticMarkdownTable)
        case separator
        case blank(String)
        case metadata(String)
        case opaque(String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
            switch (lhs, rhs) {
            case (.paragraph(let a), .paragraph(let b)): return a == b
            case (.heading(let al, let a), .heading(let bl, let b)): return al == bl && a == b
            case (.list(let a), .list(let b)): return a == b
            case (.quote(let a), .quote(let b)): return a == b
            case (.code(let al, let a, let ac), .code(let bl, let b, let bc)):
                let languageA = al.map { Array($0.utf16) }
                let languageB = bl.map { Array($0.utf16) }
                return languageA == languageB && exact(a, b) && ac == bc
            case (.math(let a), .math(let b)), (.blank(let a), .blank(let b)),
                 (.metadata(let a), .metadata(let b)), (.opaque(let a), .opaque(let b)):
                return exact(a, b)
            case (.table(let a), .table(let b)): return a == b
            case (.separator, .separator): return true
            default: return false
            }
        }

        var visibleText: String {
            switch self {
            case .paragraph(let text), .heading(_, let text): return text.text
            case .list(let items): return items.map { $0.text.text + $0.lineEnding }.joined()
            case .quote(let lines): return lines.map { $0.text.text + $0.lineEnding }.joined()
            case .code: return "\u{FFFC}"
            case .math, .table, .separator, .opaque: return "\u{FFFC}"
            case .blank(let whitespace): return whitespace
            case .metadata: return ""
            }
        }
    }

    struct Origin: Equatable {
        let source: String
        let range: NSRange
        let content: Content
        var alignment: MarkdownTextAlignment? = nil
        var alignmentEnvelope: NSRange? = nil
        let lineEnding: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.source.utf16.elementsEqual(rhs.source.utf16) && lhs.range == rhs.range
                && lhs.content == rhs.content && lhs.alignment == rhs.alignment && lhs.alignmentEnvelope == rhs.alignmentEnvelope && lhs.lineEnding.utf16.elementsEqual(rhs.lineEnding.utf16)
        }
    }

    let id: UUID
    var content: Content
    let origin: Origin?
    var lineEnding: String
    var alignment: MarkdownTextAlignment? = nil

    var originalSource: String? { origin?.source }
    var originalRange: NSRange? { origin?.range }
    var originalContent: Content? { origin?.content }

    init(id: UUID, content: Content, origin: Origin?, lineEnding: String, alignment: MarkdownTextAlignment? = nil) {
        self.id = id
        self.content = content
        self.origin = origin
        self.lineEnding = lineEnding
        self.alignment = alignment
    }

    init(content: Content, lineEnding: String = "", alignment: MarkdownTextAlignment? = nil) {
        self.init(id: UUID(), content: content, origin: nil, lineEnding: lineEnding, alignment: alignment)
    }

    init(content: Content, originalSource: String, originalRange: NSRange, lineEnding: String = "") {
        self.init(id: UUID(), content: content,
            origin: Origin(source: originalSource, range: originalRange, content: content, lineEnding: lineEnding),
            lineEnding: lineEnding)
    }

    var visibleText: String { content.visibleText + lineEnding }
}

struct SemanticMarkdownDocument {
    var blocks: [SemanticMarkdownBlock]
    /// Exact external import material. Never mutated or used as an editor buffer.
    let sourceOrigin: String
    /// Addresses the immutable imported revision, not later edits to `blocks`.
    let sourceMap: SemanticSourceMap

    var visibleText: String { blocks.map(\.visibleText).joined() }

    func isSemanticallyEquivalent(to other: Self) -> Bool {
        blocks.map(\.content) == other.blocks.map(\.content)
            && blocks.map(\.lineEnding) == other.blocks.map(\.lineEnding)
            && blocks.map(\.alignment) == other.blocks.map(\.alignment)
    }
}
