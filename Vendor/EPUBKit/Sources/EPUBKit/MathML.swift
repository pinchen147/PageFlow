import AppKit
import Foundation

// MARK: - Typesetting hook

/// A formula to typeset: LaTeX sources to try in order (the converted
/// MathML, then the book's own TeX annotation) and its display mode.
public struct EPUBMathFormula: Equatable, Sendable {
    public let sources: [String]
    /// A block (`display="block"`) formula rather than one inline in text.
    public let isDisplay: Bool
}

/// A typeset formula at ``EPUBMath/referenceSize``: its box, how far it
/// reaches below the baseline, and how to draw it.
public final class EPUBMathLayout: @unchecked Sendable {
    public let size: CGSize
    public let descent: CGFloat
    private let drawing: @Sendable (CGContext, CGColor) -> Void

    /// `draw` paints the formula with its box's bottom-left corner at the
    /// context's origin, y up, in the colour given.
    public init(size: CGSize, descent: CGFloat, draw: @escaping @Sendable (CGContext, CGColor) -> Void) {
        self.size = size
        self.descent = descent
        drawing = draw
    }

    func draw(in context: CGContext, color: CGColor) { drawing(context, color) }
}

/// Typesets formulas for the renderer. The app supplies one (EPUBKit links
/// no math engine); it is called off the main thread, once per chapter.
public protocol EPUBMathTypesetter: Sendable {
    /// One layout per formula, nil where no source could be typeset.
    func typeset(_ formulas: [EPUBMathFormula]) -> [EPUBMathLayout?]
}

public enum EPUBMath {
    /// The text size formulas are typeset at; they scale with the text around them.
    public static let referenceSize: CGFloat = 18
    /// A formula's words, on its attachment: what Copy gives.
    public static let textAttribute = NSAttributedString.Key("EPUBFormulaText")

    /// Text for Copy: each formula as its words, images (attachment characters) left out.
    public static func wordsForCopying(in text: NSMutableAttributedString) {
        text.enumerateAttribute(textAttribute, in: NSRange(location: 0, length: text.length), options: .reverse) { value, range, _ in
            guard let words = value as? String else { return }
            text.replaceCharacters(in: range, with: NSAttributedString(string: words))
        }
        text.mutableString.replaceOccurrences(of: "\u{FFFC}", with: "", options: [],
                                              range: NSRange(location: 0, length: text.length))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: EPUBMathTypesetter?

    /// The typesetter chapters use; without one, formulas show as text.
    public static var typesetter: EPUBMathTypesetter? {
        get { lock.withLock { installed } }
        set { lock.withLock { installed = newValue } }
    }
}

/// A typeset formula in the text: it takes the size of the text it sits in
/// and draws in that text's colour, so restyling never re-typesets it.
public final class EPUBMathCell: NSTextAttachmentCell {
    let layout: EPUBMathLayout

    @MainActor init(layout: EPUBMathLayout) {
        self.layout = layout
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func cellSize() -> NSSize { layout.size }
    public override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -layout.descent) }

    public override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                                   glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        var scale: CGFloat = 1
        if let storage = textContainer.layoutManager?.textStorage { scale = Self.scale(at: charIndex, in: storage) }
        if textContainer.layoutOrientation == .vertical {
            // Upright: as tall along the line as the formula is, as wide across.
            if lineFrag.width > 1, layout.size.height * scale > lineFrag.width {
                scale = lineFrag.width / layout.size.height
            }
            // And no wider than the page across the columns.
            let across = textContainer.size.height
            if across > 1, layout.size.width * scale > across { scale = across / layout.size.width }
            return NSRect(x: 0, y: -layout.size.width * scale / 2,
                          width: layout.size.height * scale, height: layout.size.width * scale)
        }
        // A formula wider than the line shrinks to fit it.
        if lineFrag.width > 1, layout.size.width * scale > lineFrag.width {
            scale = lineFrag.width / layout.size.width
        }
        return NSRect(x: 0, y: -layout.descent * scale,
                      width: layout.size.width * scale, height: layout.size.height * scale)
    }

    nonisolated private static func scale(at index: Int, in storage: NSTextStorage) -> CGFloat {
        guard index < storage.length,
              let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else { return 1 }
        return font.pointSize / EPUBMath.referenceSize
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                              characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let color = layoutManager.pageTextColor(at: charIndex) ?? .labelColor
        guard layoutManager.isLaidOutVertically else { return draw(cellFrame, color: color) }
        drawUpright(in: cellFrame) { draw($0, color: color) }
    }

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, color: .labelColor)
    }

    private func draw(_ frame: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext, layout.size.width > 0 else { return }
        let scale = frame.width / layout.size.width
        let flipped = NSGraphicsContext.current?.isFlipped ?? true
        context.saveGState()
        if flipped {
            context.translateBy(x: frame.minX, y: frame.maxY)
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: scale, y: scale)
        }
        layout.draw(in: context, color: color.cgColor)
        context.restoreGState()
    }
}

// MARK: - MathML

/// A `<math>` element read into a small tree, converted when it ends.
final class MathMLNode {
    let name: String
    let attributes: [String: String]
    var children: [MathMLNode] = []
    var text = ""
    weak var parent: MathMLNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Every token's text, in order: the formula read linearly.
    var linearText: String {
        children.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : children.filter { !["annotation", "annotation-xml"].contains($0.name) }.map(\.linearText).joined()
    }

    /// The book's own TeX for the formula, from a `<semantics>` annotation.
    var texAnnotation: String? {
        for child in children {
            if child.name == "annotation",
               let encoding = child.attributes["encoding"]?.lowercased(),
               encoding.contains("tex") {
                let tex = child.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tex.isEmpty { return tex }
            }
            if let nested = child.texAnnotation { return nested }
        }
        return nil
    }
}

/// Reads a `<math>` subtree as the parser reports it.
final class MathMLCapture {
    let root: MathMLNode
    private var current: MathMLNode
    /// The slot in the text this formula fills.
    /// Nil for a hidden formula, which has none.
    let location: Int?

    init(attributes: [String: String], location: Int?) {
        root = MathMLNode(name: "math", attributes: attributes)
        current = root
        self.location = location
    }

    var isDisplay: Bool { Self.isDisplay(root.attributes) }

    static func isDisplay(_ attributes: [String: String]) -> Bool {
        attributes["display"]?.lowercased() == "block" || attributes["mode"]?.lowercased() == "display"
    }

    func open(_ name: String, attributes: [String: String]) {
        let node = MathMLNode(name: name, attributes: attributes)
        node.parent = current
        current.children.append(node)
        current = node
    }

    func text(_ string: String) { current.text += string }

    /// Returns true when this closes `<math>`.
    func close() -> Bool {
        guard let parent = current.parent else { return true }
        current = parent
        return false
    }
}

/// Presentation MathML to LaTeX, in the dialect the app's SwiftMath
/// typesetter reads. Nil for markup it doesn't know, so the book's TeX
/// annotation or alt text can stand in instead of a wrong formula.
enum MathMLConverter {
    static func latex(_ node: MathMLNode) -> String? {
        let result = convert(node)?.trimmingCharacters(in: .whitespaces)
        return result?.isEmpty == false ? result : nil
    }

    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "coth", "arcsin", "arccos", "arctan",
        "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "dim", "ker",
        "deg", "gcd", "arg", "hom", "Pr"
    ]
    /// Operators whose under/over scripts are limits.
    private static let largeOperators: Set<String> = [
        "∑", "∏", "∐", "∫", "∬", "∭", "∮", "⋃", "⋂", "⋁", "⋀", "⨁", "⨂", "⨀", "lim", "max", "min", "sup", "inf"
    ]
    private static let invisible: Set<Character> = ["\u{2061}", "\u{2062}", "\u{2063}", "\u{2064}", "\u{200B}"]

    private static func convert(_ node: MathMLNode) -> String? {
        let parts = node.children
        func all(_ nodes: [MathMLNode]) -> String? {
            var out = ""
            for child in nodes {
                guard let latex = convert(child) else { return nil }
                out += latex
            }
            return out
        }
        func arg(_ index: Int) -> String? {
            parts.indices.contains(index) ? convert(parts[index]).map { "{\($0)}" } : nil
        }
        switch node.name {
        case "none":
            return ""
        case "math", "mrow", "mstyle", "mpadded", "merror", "mtd":
            return fenced(parts) ?? all(parts)
        case "semantics", "maction":
            return parts.first.flatMap(convert) ?? ""
        case "annotation", "annotation-xml", "mphantom", "mprescripts", "malignmark", "maligngroup":
            return ""
        case "mi":
            return identifier(node)
        case "mn":
            return escaped(node.text.trimmingCharacters(in: .whitespacesAndNewlines)) + " "
        case "mo":
            return operatorText(node.text) + " "
        case "mtext", "ms":
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return " " }
            let quoted = node.name == "ms" ? "\"\(text)\"" : text
            return "\\text{\(escaped(quoted, inText: true))}"
        case "mspace":
            let width = node.attributes["width"] ?? ""
            return width.hasSuffix("em") && (Double(width.dropLast(2)) ?? 0) >= 1 ? "\\quad " : "\\, "
        case "mfrac":
            guard let numerator = arg(0), let denominator = arg(1) else { return nil }
            if let thickness = node.attributes["linethickness"], ["0", "0px", "0em", "0pt"].contains(thickness) {
                return "{\(numerator) \\atop \(denominator)}"
            }
            return "\\frac\(numerator)\(denominator)"
        case "msqrt":
            return all(parts).map { "\\sqrt{\($0)}" }
        case "mroot":
            guard let base = arg(0), let index = arg(1) else { return nil }
            return "\\sqrt[\(index.dropFirst().dropLast())]\(base)"
        case "msup":
            guard let base = arg(0), let sup = arg(1) else { return nil }
            return "\(base)^\(sup)"
        case "msub":
            guard let base = arg(0), let sub = arg(1) else { return nil }
            return "\(base)_\(sub)"
        case "msubsup":
            guard let base = arg(0), let sub = arg(1), let sup = arg(2) else { return nil }
            return "\(base)_\(sub)^\(sup)"
        case "munder", "mover", "munderover":
            return underOver(node)
        case "mmultiscripts":
            return multiscripts(parts)
        case "mfenced":
            let open = node.attributes["open"] ?? "("
            let close = node.attributes["close"] ?? ")"
            let separators = Array((node.attributes["separators"] ?? ",").filter { !$0.isWhitespace })
            var inner = ""
            for (index, child) in parts.enumerated() {
                guard let latex = convert(child) else { return nil }
                if index > 0, !separators.isEmpty {
                    inner += operatorText(String(separators[min(index - 1, separators.count - 1)])) + " "
                }
                inner += latex
            }
            return "\\left\(delimiter(open)) \(inner) \\right\(delimiter(close))"
        case "menclose":
            guard let inner = all(parts) else { return nil }
            let notation = node.attributes["notation"] ?? ""
            if notation.contains("radical") { return "\\sqrt{\(inner)}" }
            if notation.contains("top") || notation.contains("box") { return "\\overline{\(inner)}" }
            return inner
        case "mtable":
            var rows: [String] = []
            for row in parts where row.name == "mtr" || row.name == "mlabeledtr" {
                var cells: [String] = []
                let content = row.name == "mlabeledtr" ? Array(row.children.dropFirst()) : row.children
                for cell in content {
                    guard let latex = convert(cell) else { return nil }
                    cells.append(latex)
                }
                rows.append(cells.joined(separator: " & "))
            }
            return "\\begin{matrix}\(rows.joined(separator: " \\\\ "))\\end{matrix}"
        case "mtr":
            return all(parts)
        default:
            return nil
        }
    }

    private static func identifier(_ node: MathMLNode) -> String {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let variant = node.attributes["mathvariant"] ?? ""
        if functions.contains(text) { return "\\\(text) " }
        let body = escaped(text)
        if variant.contains("bold") { return "\\mathbf{\(body)}" }
        if text.count > 1 || variant == "normal", text.allSatisfy({ $0.isASCII }) { return "\\mathrm{\(body)}" }
        return body + " "
    }

    /// `(…)`, `[…]`, `|…|` around a row: a pair that grows with its content.
    private static func fenced(_ parts: [MathMLNode]) -> String? {
        guard parts.count >= 2, let first = parts.first, let last = parts.last,
              first.name == "mo", last.name == "mo" else { return nil }
        let open = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let close = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let openers: Set<String> = ["(", "[", "{", "|", "‖", "⟨", "⌈", "⌊"]
        let closers: Set<String> = [")", "]", "}", "|", "‖", "⟩", "⌉", "⌋"]
        guard openers.contains(open), closers.contains(close),
              first.attributes["stretchy"] != "false" else { return nil }
        var inner = ""
        for child in parts.dropFirst().dropLast() {
            guard let latex = convert(child) else { return nil }
            inner += latex
        }
        return "\\left\(delimiter(open)) \(inner) \\right\(delimiter(close)) "
    }

    private static func delimiter(_ text: String) -> String {
        switch text.trimmingCharacters(in: .whitespaces) {
        case "": return "."
        case "{": return "\\{"
        case "}": return "\\}"
        case "‖": return "\\|"
        case "⟨", "〈": return "\\langle"
        case "⟩", "〉": return "\\rangle"
        case "⌈": return "\\lceil"
        case "⌉": return "\\rceil"
        case "⌊": return "\\lfloor"
        case "⌋": return "\\rfloor"
        case let other: return other
        }
    }

    private static func underOver(_ node: MathMLNode) -> String? {
        let parts = node.children
        guard let baseNode = parts.first, let base = convert(baseNode) else { return nil }
        let baseText = baseNode.linearText
        func script(_ index: Int) -> String? { parts.indices.contains(index) ? convert(parts[index]) : nil }
        let under = node.name == "mover" ? nil : script(1)
        let over = node.name == "mover" ? script(1) : node.name == "munderover" ? script(2) : nil
        if node.name != "munder", over == nil { return nil }
        if node.name != "mover", under == nil { return nil }
        // Accents over a base.
        if let overNode = node.name == "munder" ? nil : parts.last, under == nil {
            switch overNode.linearText {
            case "^", "ˆ", "\u{0302}": return "\\hat{\(base)}"
            case "~", "˜", "\u{0303}": return "\\tilde{\(base)}"
            case "¯", "‾", "_", "\u{0304}", "\u{0305}": return "\\overline{\(base)}"
            case "→", "⃗", "\u{20D7}": return "\\vec{\(base)}"
            case "˙", "\u{0307}": return "\\dot{\(base)}"
            case "¨", "\u{0308}": return "\\ddot{\(base)}"
            case "⏞", "︷": return "\\overline{\(base)}"
            default: break
            }
        }
        if over == nil, let underNode = parts.last, ["_", "¯", "‾", "⏟", "︸", "\u{0332}"].contains(underNode.linearText) {
            return "\\underline{\(base)}"
        }
        var result = largeOperators.contains(baseText) ? base : "{\(base)}"
        if let under { result += "_{\(under)}" }
        if let over { result += "^{\(over)}" }
        return result
    }

    private static func multiscripts(_ parts: [MathMLNode]) -> String? {
        guard let baseNode = parts.first, let base = convert(baseNode) else { return nil }
        var post: [MathMLNode] = []
        var pre: [MathMLNode] = []
        var seenPrescripts = false
        for child in parts.dropFirst() {
            if child.name == "mprescripts" { seenPrescripts = true; continue }
            if seenPrescripts { pre.append(child) } else { post.append(child) }
        }
        func scripts(_ nodes: [MathMLNode]) -> String? {
            var out = ""
            for pair in stride(from: 0, to: nodes.count - 1, by: 2) {
                guard let sub = convert(nodes[pair]), let sup = convert(nodes[pair + 1]) else { return nil }
                if !sub.isEmpty { out += "_{\(sub)}" }
                if !sup.isEmpty { out += "^{\(sup)}" }
            }
            return out
        }
        guard let before = scripts(pre), let after = scripts(post) else { return nil }
        return (before.isEmpty ? "" : "{}\(before)") + "{\(base)}\(after)"
    }

    private static func operatorText(_ raw: String) -> String {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).filter { !invisible.contains($0) })
        switch text {
        case "": return ""
        case "{": return "\\{"
        case "}": return "\\}"
        case "\\": return "\\backslash"
        case "−": return "-"
        case "…", "...": return "\\ldots"
        case "⋯": return "\\cdots"
        case "‖": return "\\|"
        case "⟨", "〈": return "\\langle"
        case "⟩", "〉": return "\\rangle"
        case "'", "′": return "'"
        default:
            if functions.contains(text) { return "\\\(text)" }
            if text.count > 1, text.allSatisfy({ $0.isLetter }) { return "\\mathrm{\(text)}" }
            return escaped(text)
        }
    }

    /// TeX's special characters, escaped.
    private static func escaped(_ text: String, inText: Bool = false) -> String {
        var out = ""
        for character in text {
            switch character {
            case "\\": out += "\\backslash "
            case "{", "}", "#", "$", "%", "&", "_": out += "\\\(character)"
            case "^": out += inText ? "\\^{}" : "\\hat{}"
            case "~": out += inText ? "\\~{}" : "\\sim "
            case let other where invisible.contains(other): continue
            default: out.append(character)
            }
        }
        return out
    }
}
