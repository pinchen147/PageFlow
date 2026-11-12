import Foundation

/// A publisher's print page label (EPUB 3 nav `page-list`, EPUB 2 NCX
/// `pageList`): where page "iv" or "123" of the print edition starts.
public struct EPUBPageListEntry: Equatable, Sendable {
    public let label: String
    public let chapterIndex: Int
    public let fragment: String?

    public init(label: String, chapterIndex: Int, fragment: String?) {
        self.label = label
        self.chapterIndex = chapterIndex
        self.fragment = fragment
    }
}

/// A landmark from the nav `landmarks` list (or an EPUB 2 `<guide>`): a
/// structural place such as the cover, the contents or the start of the text.
public struct EPUBLandmark: Equatable, Identifiable, Sendable {
    public let title: String
    /// The `epub:type` (`cover`, `toc`, `bodymatter`…) or guide type.
    public let type: String
    public let chapterIndex: Int
    public let fragment: String?
    public var id: String { "\(type):\(chapterIndex):\(fragment ?? "")" }

    public init(title: String, type: String, chapterIndex: Int, fragment: String?) {
        self.title = title
        self.type = type
        self.chapterIndex = chapterIndex
        self.fragment = fragment
    }

    /// A name for a landmark without link text.
    static func title(forType type: String) -> String {
        switch type.lowercased() {
        case "cover": "Cover"
        case "toc": "Contents"
        case "bodymatter", "text", "start": "Start"
        case "titlepage", "title-page": "Title Page"
        case "frontmatter": "Front Matter"
        case "backmatter": "Back Matter"
        case "loi": "List of Illustrations"
        case "lot": "List of Tables"
        case "index": "Index"
        case "bibliography": "Bibliography"
        case "glossary": "Glossary"
        case "acknowledgements", "acknowledgments": "Acknowledgements"
        default: type.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

/// The navigation the book has besides its contents.
struct NavigationExtras {
    var pageList: [EPUBPageListEntry] = []
    var landmarks: [EPUBLandmark] = []
}

enum NavigationExtrasParser {
    /// Reads the nav document's page list, else the NCX's. A malformed
    /// document leaves the book without them rather than failing it.
    static func parse(package: ParsedPackage, archive: ArchiveReader) -> NavigationExtras {
        var extras = NavigationExtras()
        if let navigation = package.navigation,
           let data = try? archive.read(navigation.path, limit: 2 * 1024 * 1024),
           let document = try? XMLDocumentParser.parse(data) {
            let base = (navigation.path as NSString).deletingLastPathComponent
            if let list = nav(ofType: "page-list", in: document) {
                extras.pageList = list.descendants(named: "a").compactMap { link in
                    pageEntry(label: link.text, href: link.attribute(named: "href"), base: base, package: package)
                }
            }
            if let list = nav(ofType: "landmarks", in: document) {
                extras.landmarks = list.descendants(named: "a").compactMap { link in
                    let type = (link.attribute(named: "epub:type") ?? "").split(separator: " ").first.map(String.init) ?? ""
                    return landmark(title: link.text, type: type, href: link.attribute(named: "href"),
                                    base: base, package: package)
                }
            }
        }
        if extras.landmarks.isEmpty {
            extras.landmarks = package.guide.compactMap {
                landmark(title: $0.title, type: $0.type, href: $0.href, base: package.packageDirectory, package: package)
            }
        }
        if extras.pageList.isEmpty, let ncx = package.ncx,
           let data = try? archive.read(ncx.path, limit: 2 * 1024 * 1024),
           let document = try? XMLDocumentParser.parse(data) {
            let base = (ncx.path as NSString).deletingLastPathComponent
            extras.pageList = document.elements(named: "pageTarget").compactMap { target in
                let label = target.firstDescendant(named: "text")?.text ?? target.attribute(named: "value") ?? ""
                return pageEntry(label: label, href: target.firstDescendant(named: "content")?.attribute(named: "src"),
                                 base: base, package: package)
            }
        }
        return extras
    }

    /// The `<nav>` whose `epub:type` names `type`.
    static func nav(ofType type: String, in document: XMLDocumentParser) -> XMLNode? {
        document.elements(named: "nav").first {
            let types = $0.attribute(named: "epub:type") ?? $0.attribute(named: "type") ?? ""
            return types.split(separator: " ").contains(Substring(type))
        }
    }

    private static func landmark(title: String, type: String, href: String?, base: String,
                                 package: ParsedPackage) -> EPUBLandmark? {
        guard let href, let target = target(of: href, base: base, package: package) else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return EPUBLandmark(title: title.isEmpty ? EPUBLandmark.title(forType: type) : title, type: type,
                            chapterIndex: target.chapter, fragment: target.fragment)
    }

    private static func pageEntry(label: String, href: String?, base: String,
                                  package: ParsedPackage) -> EPUBPageListEntry? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let href, let target = target(of: href, base: base, package: package) else { return nil }
        return EPUBPageListEntry(label: label, chapterIndex: target.chapter, fragment: target.fragment)
    }

    /// The spine item and fragment an href names, relative to `base`.
    static func target(of href: String, base: String, package: ParsedPackage) -> (chapter: Int, fragment: String?)? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = ArchivePath.normalized(String(parts[0]), relativeTo: base),
              let index = package.spine.firstIndex(where: { $0.path == path }) else { return nil }
        let fragment = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : nil
        return (index, fragment)
    }
}
