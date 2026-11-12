import AppKit

/// How a chapter's text runs. A whole chapter is vertical or not: writing
/// modes on inner elements aren't laid out.
public enum EPUBWriting {
    /// On the whole of a vertical chapter's text, and so on every page cut from it.
    public static let verticalAttribute = NSAttributedString.Key("EPUBVerticalText")
    /// On a short run set upright in one character's space (tate-chu-yoko).
    public static let combinedAttribute = NSAttributedString.Key("EPUBCombinedUpright")
    /// The longest run that combines; a longer one stays rotated, as text.
    static let combinedLimit = 4

    public static func isVertical(_ text: NSAttributedString) -> Bool {
        text.length > 0 && text.attribute(verticalAttribute, at: 0, effectiveRange: nil) != nil
    }
}

/// A text container laid out for vertical text without a text view, as a
/// paginator's is. Its size is the logical one: width along a line.
public final class EPUBVerticalTextContainer: NSTextContainer {
    public override var layoutOrientation: NSLayoutManager.TextLayoutOrientation { .vertical }
}

/// Draws upright on a vertical page, whose text is drawn turned a quarter
/// turn clockwise. `body` gets `frame` as the page sees it, y down.
func drawUpright(in frame: NSRect, _ body: (NSRect) -> Void) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.translateBy(x: frame.midX, y: frame.midY)
    context.rotate(by: -.pi / 2)
    body(NSRect(x: -frame.height / 2, y: -frame.width / 2, width: frame.height, height: frame.width))
    context.restoreGState()
}

extension NSLayoutManager {
    var isLaidOutVertically: Bool { textContainers.first?.layoutOrientation == .vertical }
}

/// What a chapter's stylesheets and html/body inline styles say about its writing.
struct ChapterWriting: Equatable {
    enum Mode {
        case horizontal, verticalRightToLeft, verticalLeftToRight
    }

    var mode = Mode.horizontal
    /// Classes styled to combine upright (`text-combine-upright`).
    var combinedClasses: Set<String> = []
    /// The chapter's stylesheets, as read: the only rule the reader takes from
    /// them beyond writing is an image's size.
    var stylesheets: [String] = []

    /// Whether inline styles ask an element to combine upright.
    static func combines(inline style: String) -> Bool {
        CSSRules.declarations(style).contains(where: CSSRules.combinesUpright)
    }
}

/// Reads a chapter up to `<body>`: its html and body elements, its `<style>`
/// blocks and linked stylesheets. A truncated file is read as far as it goes.
final class WritingModeScanner: NSObject, XMLParserDelegate {
    private let archive: ArchiveReader
    private let directory: String
    private var css: [String] = []
    private var inlineCSS: String?
    private var elements: [String: CSSElement] = [:]

    private init(archive: ArchiveReader, resourcePath: String) {
        self.archive = archive
        directory = (resourcePath as NSString).deletingLastPathComponent
    }

    static func scan(_ data: Data, resourcePath: String, archive: ArchiveReader) -> ChapterWriting {
        let scanner = WritingModeScanner(archive: archive, resourcePath: resourcePath)
        let parser = XMLParser(data: XMLDocumentParser.prepared(data))
        parser.shouldProcessNamespaces = false
        parser.delegate = scanner
        parser.parse()
        return scanner.result
    }

    /// Whether a book without a declared direction reads right to left:
    /// vertical text in its first chapters (a cover or two may be horizontal).
    static func readsRightToLeft(spine: [PackageItem], archive: ArchiveReader) -> Bool {
        spine.lazy.filter(\.isXHTML).prefix(8).contains { item in
            guard let head = try? archive.readPrefix(item.path, length: 64 * 1024, limit: 8 * 1024 * 1024) else { return false }
            return scan(head, resourcePath: item.path, archive: archive).mode == .verticalRightToLeft
        }
    }

    private var result: ChapterWriting {
        let rules = css.flatMap(archive.stylesheets.writingRules(in:))
        func mode(_ name: String) -> ChapterWriting.Mode? {
            guard let element = elements[name] else { return nil }
            let root = name == "body" ? elements["html"] : nil
            return element.inline.compactMap(CSSRules.writingMode).last
                ?? rules.filter { $0.selectors.contains { element.matches($0, root: root) } }
                    .flatMap(\.declarations).compactMap(CSSRules.writingMode).last
        }
        var writing = ChapterWriting()
        writing.stylesheets = css
        // The body's writing mode decides the page, then the root's.
        writing.mode = mode("body") ?? mode("html") ?? .horizontal
        if writing.mode != .horizontal {
            for rule in rules where rule.declarations.contains(where: CSSRules.combinesUpright) {
                writing.combinedClasses.formUnion(rule.selectors.compactMap(CSSRules.lastClass))
            }
        }
        return writing
    }

    private func stylesheet(at path: String) -> String? {
        archive.stylesheets.text(at: path) { try? archive.read(path, limit: 2 * 1024 * 1024) }
    }

    private func addStylesheet(at path: String) {
        guard let text = stylesheet(at: path) else { return }
        addImports(of: text, relativeTo: (path as NSString).deletingLastPathComponent)
        css.append(text)
    }

    /// @import, one level.
    private func addImports(of text: String, relativeTo folder: String) {
        for imported in CSSRules.imports(in: text) {
            if let target = ArchivePath.normalized(imported, relativeTo: folder), let more = stylesheet(at: target) {
                css.append(more)
            }
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch XMLNode.local(elementName) {
        case "html":
            elements["html"] = CSSElement(name: "html", attributes: attributes)
        case "style":
            inlineCSS = ""
        case "link":
            // An alternate stylesheet isn't in force until a reader picks it.
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("stylesheet"), !rel.contains("alternate"),
                  let href = attributes["href"],
                  let path = ArchivePath.normalized(href.removingFragment, relativeTo: directory) else { return }
            addStylesheet(at: path)
        case "body":
            elements["body"] = CSSElement(name: "body", attributes: attributes)
            parser.abortParsing()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { inlineCSS? += string }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { inlineCSS? += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard XMLNode.local(elementName) == "style", let text = inlineCSS else { return }
        addImports(of: text, relativeTo: directory)
        css.append(text)
        inlineCSS = nil
    }
}

/// The html or body element, as selectors see it.
private struct CSSElement {
    let name: String
    let classes: Set<String>
    let id: String?
    let inline: [CSSRules.Declaration]

    init(name: String, attributes: [String: String]) {
        self.name = name
        classes = Set((attributes["class"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        id = attributes["id"]?.lowercased()
        inline = CSSRules.declarations(attributes["style"] ?? "")
    }

    /// Whether a selector names this element: its last part, with any
    /// parts before it naming the root, the only element above a body.
    func matches(_ selector: String, root: CSSElement?) -> Bool {
        let compounds = CSSRules.compounds(selector)
        guard let last = compounds.last, matchesCompound(last) else { return false }
        let ancestors = compounds.dropLast()
        guard !ancestors.isEmpty else { return true }
        return root.map { ancestors.allSatisfy($0.matchesCompound) } ?? false
    }

    private func matchesCompound(_ compound: String) -> Bool {
        var parts = compound
        if parts == ":root" { return name == "html" }
        if parts == "*" { return true }
        guard !parts.contains(":"), !parts.contains("[") else { return false }
        var tag = ""
        while let first = parts.first, first != ".", first != "#" { tag.append(parts.removeFirst()) }
        guard tag.isEmpty || tag == "*" || tag == name else { return false }
        for token in parts.split(whereSeparator: { $0 == "." || $0 == "#" }).map(String.init) {
            guard classes.contains(token) || id == token else { return false }
        }
        return true
    }
}

/// Just enough CSS: rules and their declarations, every block inside `@media`
/// and `@supports` read as if outside. Everything is lowercased.
enum CSSRules {
    typealias Declaration = (property: String, value: String)
    typealias Rule = (selectors: [String], declarations: [Declaration])

    /// The rules that say something about writing, all a chapter's scan reads.
    /// Most stylesheets say nothing about it, and those aren't parsed at all.
    static func writingRules(_ css: String) -> [Rule] {
        let text = css.lowercased()
        guard text.contains("writing-mode") || text.contains("text-combine") else { return [] }
        return parse(css).filter { $0.declarations.contains { writingMode($0) != nil || combinesUpright($0) } }
    }

    static func parse(_ css: String) -> [Rule] {
        let text = css.replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: " ", options: .regularExpression).lowercased()
        var rules: [Rule] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            let prelude = rest[..<open].split(whereSeparator: { $0 == "}" || $0 == ";" }).last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            rest = rest[rest.index(after: open)...]
            if prelude.hasPrefix("@media"), appliesOnlyElsewhere(prelude) {
                skipBlock(&rest)
                continue
            }
            if prelude.hasPrefix("@media") || prelude.hasPrefix("@supports") { continue }
            guard let close = rest.firstIndex(of: "}") else { break }
            if !prelude.hasPrefix("@") {
                rules.append((prelude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                              declarations(String(rest[..<close]))))
            }
            rest = rest[rest.index(after: close)...]
        }
        return rules
    }

    /// A media query for print or another device (Kindle's "amzn-…"): its
    /// rules don't apply here.
    private static func appliesOnlyElsewhere(_ query: String) -> Bool {
        ["print", "amzn", "kindle", "mobi", "kf8", "speech"].contains { query.contains($0) }
            && !query.contains("screen")
    }

    /// Moves past the rest of a block whose `{` has been read.
    private static func skipBlock(_ rest: inout Substring) {
        var depth = 1
        while depth > 0, let brace = rest.firstIndex(where: { $0 == "{" || $0 == "}" }) {
            depth += rest[brace] == "{" ? 1 : -1
            rest = rest[rest.index(after: brace)...]
        }
        if depth > 0 { rest = "" }
    }

    static func declarations(_ block: String) -> [Declaration] {
        block.lowercased().split(separator: ";").compactMap { item in
            let parts = item.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let value = parts[1].replacingOccurrences(of: "!important", with: "")
            return (parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func imports(in css: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"@import\s+(?:url\()?\s*["']?([^"')\s;]+)"#) else { return [] }
        let string = css as NSString
        return pattern.matches(in: css, range: NSRange(location: 0, length: string.length))
            .map { string.substring(with: $0.range(at: 1)) }
    }

    static func writingMode(_ declaration: Declaration) -> ChapterWriting.Mode? {
        guard ["writing-mode", "-epub-writing-mode", "-webkit-writing-mode", "-ms-writing-mode"]
            .contains(declaration.property) else { return nil }
        switch declaration.value {
        case "vertical-rl", "tb-rl", "tb": return .verticalRightToLeft
        case "vertical-lr", "tb-lr": return .verticalLeftToRight
        case "horizontal-tb", "lr-tb", "rl-tb", "lr", "rl": return .horizontal
        default: return nil
        }
    }

    static func combinesUpright(_ declaration: Declaration) -> Bool {
        switch declaration.property {
        case "text-combine-upright": declaration.value.hasPrefix("all") || declaration.value.hasPrefix("digits")
        case "-epub-text-combine", "-webkit-text-combine", "text-combine": declaration.value.hasPrefix("horizontal")
        default: false
        }
    }

    static func compounds(_ selector: String) -> [String] {
        selector.split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "+" || $0 == "~" }).map(String.init)
    }

    /// The class a selector's last compound names (`span.tcy`, `.tcy`).
    static func lastClass(_ selector: String) -> String? {
        guard let compound = compounds(selector).last, !compound.contains(":"), !compound.contains("["),
              let dot = compound.firstIndex(of: ".") else { return nil }
        return compound[compound.index(after: dot)...].split(whereSeparator: { $0 == "." || $0 == "#" }).first.map(String.init)
    }
}
