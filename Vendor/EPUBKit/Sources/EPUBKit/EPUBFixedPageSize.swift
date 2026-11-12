import AppKit
import Foundation

/// The size a pre-paginated page is drawn at, in its own units (CSS pixels):
/// its `<meta name="viewport">`, the package's `rendition:viewport`, its SVG's
/// viewBox, or its first image's size.
enum EPUBFixedPageSize {
    /// Pages read at open to settle a book's size; a cover often differs from
    /// the pages after it, so the commonest wins.
    private static let sampleCount = 12

    /// `width=1200, height=1600`, with any of the separators books use. Only
    /// plain or px sizes: `100%`, `8in` and `minimum-width` say nothing of pixels.
    static func viewport(_ content: String) -> CGSize? {
        guard let pattern = try? NSRegularExpression(pattern: #"(?<![\w-])(width|height)\s*[=:]\s*([0-9]*\.?[0-9]+)(?:px)?(?![\w%.])"#,
                                                     options: .caseInsensitive) else { return nil }
        let source = content as NSString
        var sides: [String: CGFloat] = [:]
        for match in pattern.matches(in: content, range: NSRange(location: 0, length: source.length)) {
            sides[source.substring(with: match.range(at: 1)).lowercased()] =
                Double(source.substring(with: match.range(at: 2))).map { CGFloat($0) }
        }
        guard let width = sides["width"], let height = sides["height"], width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// An `<svg>`'s viewBox size, else its absolute width and height.
    static func svg(_ node: XMLNode) -> CGSize? {
        let box = (node.attribute(named: "viewBox") ?? "").split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }
        if box.count == 4, box[2] >= 1, box[3] >= 1 { return CGSize(width: box[2], height: box[3]) }
        func absolute(_ name: String) -> CGFloat? {
            guard let value = node.attribute(named: name)?.trimmingCharacters(in: .whitespaces), !value.hasSuffix("%") else { return nil }
            return Double(value.replacingOccurrences(of: "px", with: "")).map { CGFloat($0) }
        }
        guard let width = absolute("width"), let height = absolute("height"), width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The size of a whole SVG file.
    static func svg(_ data: Data) -> CGSize? {
        guard let root = (try? XMLDocumentParser.parse(data))?.root else { return nil }
        return svg(root)
    }

    /// One chapter's page size, from its markup and what it points to.
    static func of(document: XMLDocumentParser, path: String, archive: ArchiveReader, packageViewport: CGSize?) -> CGSize? {
        let meta = document.elements(named: "meta").first { $0.attribute(named: "name")?.lowercased() == "viewport" }
        if let size = meta?.attributes["content"].flatMap(viewport) { return size }
        if let packageViewport { return packageViewport }
        if let size = document.elements(named: "svg").lazy.compactMap({ svg($0) }).first { return size }
        let directory = (path as NSString).deletingLastPathComponent
        for node in document.elements(named: "img") + document.elements(named: "image") {
            guard let source = node.attributes["src"] ?? node.attributes["xlink:href"] ?? node.attributes["href"],
                  URL(string: source)?.scheme == nil,
                  let image = ArchivePath.normalized(source.removingFragment, relativeTo: directory),
                  let size = XHTMLRenderer.imagePixelSize(at: image, in: archive) else { continue }
            return size
        }
        return nil
    }

    /// A chapter's page size read from the archive.
    static func of(_ chapter: EPUBChapter, archive: ArchiveReader, packageViewport: CGSize?) -> CGSize? {
        guard let data = try? archive.read(chapter.path, limit: 8 * 1024 * 1024) else { return nil }
        if chapter.isImage { return svg(data) }
        guard let document = try? XMLDocumentParser.parse(data) else { return nil }
        return of(document: document, path: chapter.path, archive: archive, packageViewport: packageViewport)
    }

    /// The book's page size: the commonest among pages sampled across it,
    /// when fixed pages are most of its reading flow.
    static func common(in chapters: [EPUBChapter], archive: ArchiveReader, packageViewport: CGSize?) -> CGSize? {
        let flow = chapters.filter(\.isLinear)
        let fixed = flow.filter { $0.layout == .fixed }
        guard fixed.count * 2 > flow.count else { return nil }
        var counts: [(size: CGSize, count: Int)] = []
        for index in stride(from: 0, to: fixed.count, by: max(1, fixed.count / sampleCount)) {
            guard let size = of(fixed[index], archive: archive, packageViewport: packageViewport) else { continue }
            if let known = counts.firstIndex(where: { $0.size == size }) {
                counts[known].count += 1
            } else {
                counts.append((size, 1))
            }
        }
        return counts.max { $0.count < $1.count }?.size
    }
}
