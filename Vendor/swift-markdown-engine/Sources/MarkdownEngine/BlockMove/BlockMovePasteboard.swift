import AppKit
import CryptoKit

/// Stable block identity is separate from its portable Markdown representation.
struct BlockMovePasteboard {
    enum Kind: String, Codable, CaseIterable {
        case image, equation, diagram, code, table
        var title: String {
            switch self {
            case .image: "Image"
            case .equation: "Equation"
            case .diagram: "Diagram"
            case .code: "Code Block"
            case .table: "Table"
            }
        }
    }
    struct Identity: Codable {
        let document: String?
        let editor: String
        let kind: Kind
        let location: Int
        let length: Int
        let sha256: String
    }
    struct Markdown: Codable {
        let source: String
        let baseFolder: URL?
    }
    static let moveType = NSPasteboard.PasteboardType("com.pageflow.block-move")
    static let markdownType = NSPasteboard.PasteboardType("com.pageflow.markdown-block")
    let identity: Identity
    let markdown: Markdown
    var range: NSRange { NSRange(location: identity.location, length: identity.length) }

    init(source: String, range: NSRange, kind: Kind, document: String?, editor: String, baseFolder: URL?) {
        identity = Identity(document: document, editor: editor, kind: kind, location: range.location, length: range.length,
                            sha256: Self.hash(source))
        markdown = Markdown(source: source, baseFolder: baseFolder)
    }
    private init(identity: Identity, markdown: Markdown) {
        self.identity = identity
        self.markdown = markdown
    }
    func isLocal(document: String?, editor: String) -> Bool {
        identity.document == document && identity.editor == editor
    }
    func matches(_ text: NSString) -> Bool {
        range.location >= 0 && range.length > 0 && range.location <= text.length && range.length <= text.length - range.location
            && Self.hash(text.substring(with: range)) == identity.sha256
            && Self.hash(markdown.source) == identity.sha256
    }
    private static func hash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func write(to item: NSPasteboardItem) {
        if let data = try? JSONEncoder().encode(identity) { item.setData(data, forType: Self.moveType) }
        if let data = try? JSONEncoder().encode(markdown) { item.setData(data, forType: Self.markdownType) }
        item.setString(markdown.source, forType: .string)
    }
    static func read(from pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: moveType), let md = pasteboard.data(forType: markdownType),
              let identity = try? JSONDecoder().decode(Identity.self, from: data),
              let markdown = try? JSONDecoder().decode(Markdown.self, from: md),
              identity.location >= 0, identity.length > 0, Self.hash(markdown.source) == identity.sha256 else { return nil }
        return Self(identity: identity, markdown: markdown)
    }

    /// Rewrites only image destinations. Remote URLs, titles, descriptions and alt tokens retain their bytes.
    func rebasedSource(to target: URL?) -> String {
        guard let base = markdown.baseFolder else { return markdown.source }
        let source = markdown.source as NSString
        let result = NSMutableString(string: markdown.source)
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: markdown.source, memoizing: false)
        for token in tokens.reversed() {
            let destinationRange: NSRange
            if token.kind == .imageLink {
                guard token.markerRanges.count >= 4,
                      let range = InlineParser.linkDestinationRange(in: source, openParen: token.markerRanges[2].location) else { continue }
                destinationRange = range
            } else if token.kind == .imageEmbed {
                let body = source.substring(with: token.contentRange) as NSString
                let headLength = body.range(of: "|").location
                destinationRange = NSRange(location: token.contentRange.location,
                                           length: headLength == NSNotFound ? body.length : headLength)
            } else { continue }
            Self.rebase(destinationRange, in: source, result: result, base: base, target: target)
        }
        return result as String
    }
    private static func rebase(_ range: NSRange, in source: NSString, result: NSMutableString, base: URL, target: URL?) {
        let raw = InlineParser.decodedLinkDestination(in: source, range: range)
        let parsedURL = URL(string: raw)
        if let scheme = parsedURL?.scheme, scheme != "file" { return }
        let name = raw.removingPercentEncoding ?? raw
        if name.hasPrefix("#") || name.isEmpty { return }
        let file = (parsedURL?.isFileURL == true ? parsedURL : nil)
            ?? URL(fileURLWithPath: name, relativeTo: base.appendingPathComponent("", isDirectory: true))
        let absolute = file.standardizedFileURL
        let targetPath = target?.standardizedFileURL.path
        let path: String
        if let targetPath, absolute.path.hasPrefix(targetPath + "/") { path = String(absolute.path.dropFirst(targetPath.count + 1)) }
        else { path = absolute.path }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%#?<>\\: ()")
        let replacement = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        result.replaceCharacters(in: range, with: replacement)
    }
}
