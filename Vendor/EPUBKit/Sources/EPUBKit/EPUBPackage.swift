import Foundation

struct PackageItem {
    let id: String
    let path: String
    let mediaType: String
    let properties: Set<String>
    /// The manifest id of the SMIL document that narrates this item.
    var mediaOverlay: String? = nil
}

extension PackageItem {
    var isXHTML: Bool { mediaType.lowercased().hasPrefix("application/xhtml+xml") }
    var isSVG: Bool { mediaType.lowercased().hasPrefix("image/svg+xml") }
}

struct ParsedPackage {
    let title: String
    /// The package's unique identifier: the `dc:identifier` its
    /// `unique-identifier` names, else its first; nil when blank.
    let identifier: String?
    /// The `dc:creator` names, in order; blank ones dropped.
    let authors: [String]
    let packageDirectory: String
    let manifest: [String: PackageItem]
    let spine: [PackageItem]
    /// Spine positions marked linear="no": supplements read outside the flow.
    var nonlinear: Set<Int> = []
    /// The EPUB 2 `<guide>` references: type, title and package-relative href.
    var guide: [(type: String, title: String, href: String)] = []
    /// `media:duration` for a whole book, and per overlay by its manifest id.
    var mediaDuration: TimeInterval? = nil
    var mediaDurations: [String: TimeInterval] = [:]
    let navigation: PackageItem?
    let ncx: PackageItem?
    let layout: EPUBLayout
    let pageProgression: EPUBPageProgression
    /// Each spine item's `properties` on its itemref, by spine position.
    var spineProperties: [Set<String>] = []
    /// The package's `rendition:spread`.
    var spread: String?
    /// The package's `rendition:viewport`: a default size for fixed pages.
    var viewport: CGSize?
    /// The spine names a direction (`rtl` or `ltr`, not `default`).
    var declaresProgression = false
}

extension ParsedPackage {
    /// The package's `rendition:layout`, unless the spine item overrides it.
    func layout(ofSpineItem index: Int) -> EPUBLayout {
        let properties = spineProperties.indices.contains(index) ? spineProperties[index] : []
        if properties.contains("rendition:layout-pre-paginated") { return .fixed }
        if properties.contains("rendition:layout-reflowable") { return .reflowable }
        return layout
    }

    /// Where a fixed page sits in a two-page spread: its `page-spread-*`, or
    /// alone in the middle when `rendition:spread` is none.
    func side(ofSpineItem index: Int) -> EPUBPageSide? {
        guard layout(ofSpineItem: index) == .fixed else { return nil }
        let properties = spineProperties.indices.contains(index) ? spineProperties[index] : []
        func has(_ name: String) -> Bool { properties.contains(name) || properties.contains("rendition:\(name)") }
        let override = properties.first { $0.hasPrefix("rendition:spread-") }
        if override == "rendition:spread-none" || (override == nil && spread == "none") { return .center }
        if has("page-spread-center") { return .center }
        if has("page-spread-left") { return .left }
        return has("page-spread-right") ? .right : nil
    }
}

enum PackageParser {
    static func parse(_ data: Data, packagePath: String) throws -> ParsedPackage {
        let document = try XMLDocumentParser.parse(data)
        guard document.root?.localName == "package" else { throw EPUBError.invalidPackage }
        let directory = (packagePath as NSString).deletingLastPathComponent
        var manifest: [String: PackageItem] = [:]
        for node in document.elements(named: "item") {
            guard let id = node.attribute(named: "id"),
                  let href = node.attribute(named: "href"),
                  let mediaType = node.attribute(named: "media-type"),
                  let path = ArchivePath.normalized(href.removingFragment, relativeTo: directory),
                  manifest[id] == nil else { throw EPUBError.invalidPackage }
            let properties = Set((node.attribute(named: "properties") ?? "").split(separator: " ").map(String.init))
            manifest[id] = PackageItem(id: id, path: path, mediaType: mediaType, properties: properties,
                                       mediaOverlay: node.attribute(named: "media-overlay"))
        }
        let refs = document.elements(named: "itemref")
        // SVG pages read as image chapters; other types are skipped.
        let readable = try refs.compactMap { node -> (item: PackageItem, linear: Bool, properties: Set<String>)? in
            guard let id = node.attribute(named: "idref"), let item = manifest[id] else { throw EPUBError.invalidPackage }
            let linear = node.attribute(named: "linear")?.trimmingCharacters(in: .whitespaces).lowercased() != "no"
            let properties = Set((node.attribute(named: "properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            return item.isXHTML || item.isSVG ? (item, linear, properties) : nil
        }
        let spine = readable.map(\.item)
        // A spine with no linear item at all reads every item in order.
        let nonlinear = readable.contains(where: \.linear)
            ? Set(readable.indices.filter { !readable[$0].linear }) : []
        let guide = document.elements(named: "reference").compactMap { node -> (String, String, String)? in
            guard node.parent?.localName == "guide", let type = node.attribute(named: "type"),
                  let href = node.attribute(named: "href") else { return nil }
            return (type, node.attribute(named: "title") ?? "", href)
        }
        var mediaDuration: TimeInterval?
        var mediaDurations: [String: TimeInterval] = [:]
        for meta in document.elements(named: "meta") where meta.attribute(named: "property") == "media:duration" {
            guard let duration = MediaOverlayParser.clockValue(meta.text) else { continue }
            if let refines = meta.attribute(named: "refines") {
                mediaDurations[refines.hasPrefix("#") ? String(refines.dropFirst()) : refines] = duration
            } else {
                mediaDuration = duration
            }
        }
        let title = document.firstElement(named: "title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifiers = document.elements(named: "identifier")
        let uniqueID = document.root?.attribute(named: "unique-identifier")
        let identifier = (identifiers.first { uniqueID != nil && $0.attribute(named: "id") == uniqueID } ?? identifiers.first)?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = document.elements(named: "creator")
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // The package-wide value: a meta refining an item says nothing of the book.
        func rendition(_ property: String) -> String? {
            let meta = document.elements(named: "meta").first {
                $0.attributes["refines"] == nil
                    && ($0.attribute(named: "property") == property || $0.attribute(named: "name") == property)
            }
            return (meta?.attributes["content"] ?? meta?.text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let layout: EPUBLayout = rendition("rendition:layout") == "pre-paginated" ? .fixed : .reflowable
        let navigation = manifest.values.first { $0.properties.contains("nav") }
        let spineNode = document.firstElement(named: "spine")
        let tocID = spineNode?.attribute(named: "toc")
        let direction = spineNode?.attribute(named: "page-progression-direction")?.lowercased()
        let progression: EPUBPageProgression = direction == "rtl" ? .rightToLeft : .leftToRight
        return ParsedPackage(
            title: title,
            identifier: identifier?.isEmpty == false ? identifier : nil,
            authors: authors,
            packageDirectory: directory,
            manifest: manifest,
            spine: spine,
            nonlinear: nonlinear,
            guide: guide,
            mediaDuration: mediaDuration,
            mediaDurations: mediaDurations,
            navigation: navigation,
            ncx: tocID.flatMap { manifest[$0] },
            layout: layout,
            pageProgression: progression,
            spineProperties: readable.map(\.properties),
            spread: rendition("rendition:spread"),
            viewport: rendition("rendition:viewport").flatMap(EPUBFixedPageSize.viewport),
            declaresProgression: direction == "rtl" || direction == "ltr"
        )
    }
}

extension String {
    var removingFragment: String { split(separator: "#", maxSplits: 1).first.map(String.init) ?? self }
}

enum NavigationParser {
    static func parse(package: ParsedPackage, archive: ArchiveReader) throws -> [EPUBContentsEntry] {
        if let navigation = package.navigation {
            let document = try XMLDocumentParser.parse(try archive.read(navigation.path, limit: 2 * 1024 * 1024))
            let toc = document.elements(named: "nav").first {
                let type = $0.attribute(named: "epub:type") ?? $0.attribute(named: "type") ?? ""
                return type.split(separator: " ").contains("toc")
            }
            if let toc {
                return links(in: toc, base: (navigation.path as NSString).deletingLastPathComponent, package: package)
            }
        }
        if let ncx = package.ncx {
            let document = try XMLDocumentParser.parse(try archive.read(ncx.path, limit: 2 * 1024 * 1024))
            let base = (ncx.path as NSString).deletingLastPathComponent
            return document.elements(named: "navPoint").compactMap { point in
                guard let src = point.firstDescendant(named: "content")?.attribute(named: "src") else { return nil }
                let title = point.firstDescendant(named: "text")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return entry(title: title, href: src, base: base, package: package,
                             depth: ancestors(of: point, named: "navPoint", within: nil))
            }
        }
        return []
    }

    private static func links(in node: XMLNode, base: String, package: ParsedPackage) -> [EPUBContentsEntry] {
        node.descendants(named: "a").compactMap { link in
            guard let href = link.attribute(named: "href") else { return nil }
            return entry(
                title: link.text.trimmingCharacters(in: .whitespacesAndNewlines),
                href: href,
                base: base,
                package: package,
                // The top list's entries sit inside one <ol>.
                depth: max(0, ancestors(of: link, named: "ol", within: node) - 1)
            )
        }
    }

    /// How many `name` elements enclose `node`, up to (not counting) `stop`.
    private static func ancestors(of node: XMLNode, named name: String, within stop: XMLNode?) -> Int {
        var count = 0
        var current = node.parent
        while let element = current, element !== stop {
            if element.localName == name { count += 1 }
            current = element.parent
        }
        return count
    }

    private static func entry(title: String, href: String, base: String, package: ParsedPackage,
                              depth: Int) -> EPUBContentsEntry? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let path = ArchivePath.normalized(String(parts[0]), relativeTo: base),
              let index = package.spine.firstIndex(where: { $0.path == path }) else { return nil }
        return EPUBContentsEntry(
            title: title.isEmpty ? package.spine[index].id : title,
            chapterIndex: index,
            fragment: parts.count == 2 ? String(parts[1]) : nil,
            depth: depth
        )
    }
}
