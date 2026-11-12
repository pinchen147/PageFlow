import Foundation

final class XMLNode {
    let name: String
    let attributes: [String: String]
    weak var parent: XMLNode?
    var children: [XMLNode] = []
    var ownText = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var localName: String { Self.local(name) }
    var text: String { ownText + children.map(\.text).joined() }
    func attribute(named name: String) -> String? {
        attributes[name] ?? attributes.first { Self.local($0.key) == Self.local(name) }?.value
    }
    func firstDescendant(named name: String) -> XMLNode? {
        children.first(where: { $0.localName == name }) ?? children.lazy.compactMap { $0.firstDescendant(named: name) }.first
    }
    func descendants(named name: String) -> [XMLNode] {
        children.flatMap { child in
            (child.localName == name ? [child] : []) + child.descendants(named: name)
        }
    }
    static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

final class XMLDocumentParser: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private var stack: [XMLNode] = []
    private var error: Error?

    static func parse(_ data: Data) throws -> XMLDocumentParser {
        let document = XMLDocumentParser()
        let parser = XMLParser(data: prepared(data))
        parser.shouldProcessNamespaces = false
        parser.delegate = document
        guard parser.parse(), document.error == nil, document.root != nil else {
            throw EPUBError.invalidContent("xml")
        }
        return document
    }

    static func prepared(_ data: Data) -> Data {
        guard var string = String(data: data, encoding: .utf8) else { return data }
        let entities = [
            "&nbsp;": "&#160;", "&copy;": "&#169;", "&reg;": "&#174;",
            "&ndash;": "&#8211;", "&mdash;": "&#8212;", "&hellip;": "&#8230;"
        ]
        for (entity, replacement) in entities {
            string = string.replacingOccurrences(of: entity, with: replacement)
        }
        return Data(string.utf8)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        node.parent = stack.last
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.ownText += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }

    func elements(named name: String) -> [XMLNode] {
        guard let root else { return [] }
        return (root.localName == name ? [root] : []) + root.descendants(named: name)
    }
    func firstElement(named name: String) -> XMLNode? { elements(named: name).first }
}
