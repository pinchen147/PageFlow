import Foundation

/// What a chapter's markup says styling it and drawing a page of it will take,
/// read without rendering it, so the main thread can tell whether a far page's
/// chapter can be styled in the moment it is asked for.
public struct EPUBChapterCost: Equatable, Sendable {
    /// Files in the book: every render indexes them again.
    var archiveEntries = 0
    /// Images and drawings. Styling reads each one's header.
    var images = 0
    /// The bytes of the three largest, about what a page of them decodes in draw.
    var largestImageBytes = 0
    /// Linked and imported sheets by path, with their size.
    var sheets: [String: Int] = [:]
    /// `<style>` blocks, parsed for each chapter.
    var inlineStyleBytes = 0
    /// Formulas typeset while styling.
    var formulas = 0
    /// A fixed page draws its images large, at sizes known only once placed.
    var isFixedLayout = false

    // Measured in a Release build on a heavily loaded Mac (load average 250-320).
    private static let msPerArchiveEntry = 0.005 // 10,000 entries: 51 ms
    private static let msPerCharacter = 0.001
    private static let msPerImageHeader = 1.0 // 256 KB inflated, then parsed
    private static let msPerImageKB = 0.1 // 300 KB JPEG: 30 ms
    private static let msPerSheetKB = 0.17 // 220 KB sheet: 37 ms
    private static let msPerFormula = 1.0

    func milliseconds(characters: Int, unparsedSheetBytes: Int) -> Double {
        guard !isFixedLayout else { return .infinity }
        return Double(archiveEntries) * Self.msPerArchiveEntry
            + Double(characters) * Self.msPerCharacter
            + Double(images) * Self.msPerImageHeader
            + Double(largestImageBytes) / 1024 * Self.msPerImageKB
            + Double(unparsedSheetBytes + inlineStyleBytes) / 1024 * Self.msPerSheetKB
            + Double(formulas) * Self.msPerFormula
    }
}

public extension EPUBBook {
    /// Every chapter's cost, in spine order; empty if cancelled or unreadable.
    /// Reads the book's markup, so call it off the main thread.
    func chapterCosts() -> [EPUBChapterCost] {
        guard let archive = try? ArchiveReader(url: sourceURL, expandedLimit: .max) else { return [] }
        var sheetFiles: [String: [String: Int]] = [:]
        var costs: [EPUBChapterCost] = []
        costs.reserveCapacity(chapters.count)
        for chapter in chapters {
            guard !Task.isCancelled else { return [] }
            var cost = (try? source(of: chapter, in: archive)).map {
                ChapterCostScanner.scan($0, resourcePath: chapter.path, archive: archive, sheetFiles: &sheetFiles)
            } ?? EPUBChapterCost()
            cost.archiveEntries = archive.entryCount
            cost.isFixedLayout = chapter.layout == .fixed
            costs.append(cost)
        }
        return costs
    }

    /// About how long styling a chapter of `characters` and drawing a page of
    /// it holds the thread doing it. Sheets already parsed cost nothing.
    func stylingMilliseconds(_ cost: EPUBChapterCost, characters: Int) -> Double {
        let unparsed = cost.sheets.reduce(0) { $0 + (stylesheets.holds($1.key) ? 0 : $1.value) }
        return cost.milliseconds(characters: characters, unparsedSheetBytes: unparsed)
    }
}

private final class ChapterCostScanner: NSObject, XMLParserDelegate {
    /// An inline drawing's size isn't known up front; a typical one's decode.
    private static let inlineDrawingBytes = 64 * 1024

    private let archive: ArchiveReader
    private let directory: String
    private var imagePaths: Set<String> = []
    private var images: [Int] = []
    private var inlineCSS: String?
    private var sheetFiles: [String: [String: Int]]
    private var cost = EPUBChapterCost()

    private init(archive: ArchiveReader, resourcePath: String, sheetFiles: [String: [String: Int]]) {
        self.archive = archive
        directory = (resourcePath as NSString).deletingLastPathComponent
        self.sheetFiles = sheetFiles
    }

    /// `sheetFiles` remembers each sheet's files across chapters, so it is read once.
    static func scan(_ data: Data, resourcePath: String, archive: ArchiveReader,
                     sheetFiles: inout [String: [String: Int]]) -> EPUBChapterCost {
        let scanner = ChapterCostScanner(archive: archive, resourcePath: resourcePath, sheetFiles: sheetFiles)
        let parser = XMLParser(data: XMLDocumentParser.prepared(data))
        parser.shouldProcessNamespaces = false
        parser.delegate = scanner
        parser.parse()
        sheetFiles = scanner.sheetFiles
        scanner.cost.images = scanner.images.count
        scanner.cost.largestImageBytes = scanner.images.sorted(by: >).prefix(3).reduce(0, +)
        return scanner.cost
    }

    private func addImage(_ source: String) {
        guard let path = ArchivePath.normalized(source.removingFragment, relativeTo: directory),
              imagePaths.insert(path).inserted else { return }
        images.append(archive.size(of: path) ?? 0)
    }

    private func addSheet(at path: String) {
        if sheetFiles[path] == nil {
            var files = [path: archive.size(of: path) ?? 0]
            // @import, one level, as the chapter's own reading does.
            if let data = try? archive.read(path, limit: 2 * 1024 * 1024) {
                let folder = (path as NSString).deletingLastPathComponent
                for imported in CSSRules.imports(in: String(decoding: data, as: UTF8.self)) {
                    if let target = ArchivePath.normalized(imported, relativeTo: folder) {
                        files[target] = archive.size(of: target) ?? 0
                    }
                }
            }
            sheetFiles[path] = files
        }
        cost.sheets.merge(sheetFiles[path] ?? [:]) { first, _ in first }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch XMLNode.local(elementName) {
        case "img", "image":
            if let source = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] { addImage(source) }
        case "svg":
            images.append(Self.inlineDrawingBytes)
        case "math":
            cost.formulas += 1
        case "style":
            inlineCSS = ""
        case "link":
            guard let rel = attributes["rel"]?.lowercased(), rel.contains("stylesheet"), !rel.contains("alternate"),
                  let href = attributes["href"],
                  let path = ArchivePath.normalized(href.removingFragment, relativeTo: directory) else { return }
            addSheet(at: path)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { inlineCSS? += string }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { inlineCSS? += String(decoding: data, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard XMLNode.local(elementName) == "style", let text = inlineCSS else { return }
        cost.inlineStyleBytes += text.utf8.count
        for imported in CSSRules.imports(in: text) {
            if let target = ArchivePath.normalized(imported, relativeTo: directory) { addSheet(at: target) }
        }
        inlineCSS = nil
    }
}
