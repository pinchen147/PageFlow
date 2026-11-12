import AppKit
import Foundation

public enum EPUBError: Error, Equatable {
    case unreadableArchive
    case invalidMimetype
    case missingResource(String)
    case invalidContainer
    case invalidPackage
    case invalidContent(String)
    case resourceLimit
    /// The book's text is encrypted (Adobe ADEPT, Apple FairPlay, Readium LCP…).
    case drmProtected
}

public struct EPUBContentsEntry: Equatable, Identifiable, Sendable {
    public let title: String
    public let chapterIndex: Int
    public let fragment: String?
    /// How deeply the entry is nested in the book's contents (0 at the top).
    public var depth = 0
    public var id: String { "\(chapterIndex):\(fragment ?? ""):\(title)" }

    public init(title: String, chapterIndex: Int, fragment: String?, depth: Int = 0) {
        self.title = title
        self.chapterIndex = chapterIndex
        self.fragment = fragment
        self.depth = depth
    }
}

public struct EPUBChapter: @unchecked Sendable {
    public let id: String
    public let title: String
    public let path: String
    /// An SVG spine item, shown as a page-sized image.
    let isImage: Bool
    /// False for a spine item marked linear="no" (answers, a chart): it is
    /// read outside the reading flow, from the links that point to it.
    public let isLinear: Bool
    /// Fixed for a pre-paginated spine item: one page, placed, never flowed.
    public var layout: EPUBLayout = .reflowable
    /// Where a fixed page sits in a two-page spread, when the book says.
    public var side: EPUBPageSide?
}

public struct EPUBRenderedChapter: @unchecked Sendable {
    public let chapter: EPUBChapter
    public let attributedText: NSAttributedString
    public let anchors: [String: Int]
    /// Where each id'd element a note reference could point to sits in the text.
    public let noteTargets: [String: EPUBNoteTarget]
    /// Footnotes left out of the text because a reference shows them as
    /// pop-ups, by every id inside each.
    public let detachedNotes: [String: NSAttributedString]
    /// One id for each whole note in `detachedNotes`, in the book's order:
    /// the other ids are aliases, for that note or a part of it.
    public let detachedNoteIDs: [String]
    public let estimatedMemoryCost: Int
    public let notices: [EPUBContentNotice]
    /// How a fixed-layout chapter is placed on its one page; nil for a
    /// flowing chapter, or one that can't be placed and reflows with a notice.
    public let fixedPage: EPUBFixedPage?
    /// Laid out in vertical columns (`writing-mode: vertical-rl`).
    public var isVertical: Bool { EPUBWriting.isVertical(attributedText) }

    public init(chapter: EPUBChapter, attributedText: NSAttributedString,
                anchors: [String: Int], noteTargets: [String: EPUBNoteTarget] = [:],
                detachedNotes: [String: NSAttributedString] = [:], detachedNoteIDs: [String] = [],
                estimatedMemoryCost: Int, notices: [EPUBContentNotice], fixedPage: EPUBFixedPage? = nil) {
        self.fixedPage = fixedPage
        self.chapter = chapter
        self.attributedText = attributedText
        self.anchors = anchors
        self.noteTargets = noteTargets
        self.detachedNotes = detachedNotes
        self.detachedNoteIDs = detachedNoteIDs
        self.estimatedMemoryCost = estimatedMemoryCost
        self.notices = notices
    }
}

/// How a link refers to a note, read from its markup. Book links carry it
/// in their URL (``Foundation/URL/epubNoteReference``).
public enum EPUBNoteReference: String, Sendable {
    /// Marked as one: epub:type="noteref" or role="doc-noteref".
    case marked
    /// Looks like one: a short number or symbol, or superscript.
    case marker
}

/// An element a note reference can point to: its text in the chapter.
public struct EPUBNoteTarget: Equatable, Sendable {
    public let range: NSRange
    /// Marked as a footnote, endnote or rearnote, itself or by its list.
    public let isMarkedNote: Bool

    public init(range: NSRange, isMarkedNote: Bool) {
        self.range = range
        self.isMarkedNote = isMarkedNote
    }

    /// Whether a link of `reference` kind here shows this text as a note
    /// rather than jumping: a marked reference or note always does (unless
    /// it is a whole chapter's worth); a marker only to a short block.
    public func showsAsNote(for reference: EPUBNoteReference) -> Bool {
        guard range.length > 0 else { return false }
        if reference == .marked || isMarkedNote { return range.length <= 20_000 }
        return range.length <= 800
    }
}

public extension URL {
    /// How this book link refers to a note, if it reads as a note reference.
    var epubNoteReference: EPUBNoteReference? {
        guard scheme == EPUBBook.internalLinkScheme else { return nil }
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "note" }?.value.flatMap(EPUBNoteReference.init(rawValue:))
    }
}

public struct EPUBSearchResult: Hashable, Sendable {
    public let chapterIndex: Int
    public let range: NSRange

    public init(chapterIndex: Int, range: NSRange) {
        self.chapterIndex = chapterIndex
        self.range = range
    }
}

public enum EPUBLayout: String, Equatable, Sendable {
    case reflowable
    case fixed
}

/// The side of a two-page spread a fixed page is made for (`page-spread-*`);
/// center keeps it alone, between the two.
public enum EPUBPageSide: String, Equatable, Sendable {
    case left
    case right
    case center
}

/// Which way the book's pages turn: a right-to-left book (Arabic, Hebrew,
/// manga) opens on the right and turns toward the left.
public enum EPUBPageProgression: String, Equatable, Sendable {
    case leftToRight
    case rightToLeft
}

public enum EPUBContentNotice: String, Equatable, Hashable, Sendable, CaseIterable {
    case fixedLayoutFallback
    case verticalWritingFallback
    case mathMLFallback
    case audioUnavailable
    case videoUnavailable
    case remoteResourceUnavailable
}

public struct EPUBBook: @unchecked Sendable {
    /// Gives back decoded images, and stylesheets past a small allowance, for a
    /// book not being read just now.
    public func releaseCaches() {
        images.removeDecodedImages()
        stylesheets.shrink()
    }

    /// The book's file is now `url`, a copy of the same bytes (Save As). Every
    /// copy of this value, and every chapter already styled, follows it.
    public func relocate(to url: URL) { images.relocate(to: url) }

    /// The book's tab is closing: its snapshot of the file goes now.
    public func closeFile() { images.closeSnapshot() }

    /// Whether the book reads from its own snapshot, so a move can't reach it.
    public var hasFileSnapshot: Bool { images.hasSnapshot }

    /// Clears snapshots a quit or crash left: at launch, before any book opens.
    public static func removeLeftoverFileSnapshots() { EPUBFileSnapshot.removeLeftovers() }

    /// Clears this copy's snapshots as the app quits, and leaves another running
    /// copy's alone.
    public static func removeAllFileSnapshots() { EPUBFileSnapshot.removeOwnAndLeftovers() }

    /// The book is being read again: it keeps what it reads, as it did before.
    public func resumeCaches() { stylesheets.grow() }

    public static let internalLinkScheme = "pageflow-epub"

    public let title: String
    /// The publication's unique identifier (the package's `dc:identifier`),
    /// the same whatever the file is called or wherever it is; nil when the
    /// package names none.
    public let identifier: String?
    /// The book's authors (`dc:creator`), in the package's order.
    public let authors: [String]
    public let chapters: [EPUBChapter]
    public let contents: [EPUBContentsEntry]
    /// The print edition's page labels, in reading order; empty when the
    /// book has no page list.
    public let pageList: [EPUBPageListEntry]
    /// The book's landmarks (cover, contents, start of the text…), in order.
    public let landmarks: [EPUBLandmark]
    public let layout: EPUBLayout
    /// The spine's `page-progression-direction`.
    public let pageProgression: EPUBPageProgression
    /// The size of this book's fixed pages in their own units, when most of
    /// its pages are fixed; pages of another size fit inside it. Nil for a
    /// flowing book, or one whose pages name no size.
    public let fixedPageSize: CGSize?
    /// The package's `rendition:viewport`.
    let packageViewport: CGSize?
    var sourceURL: URL { images.sourceURL }
    /// Decodes images on demand for every chapter of this book.
    private let images: EPUBImageStore
    /// What the book's stylesheets say, parsed once for all its chapters.
    let stylesheets: EPUBStylesheets
    /// The narration the book carries (EPUB 3 media overlays).
    public let mediaOverlays: EPUBMediaOverlays
    /// Each chapter's plain text, extracted once for Find.
    let searchText = EPUBSearchText()

    public static func open(url: URL) throws -> EPUBBook {
        let archive = try ArchiveReader(url: url)
        // Tolerate trailing whitespace (a CRLF-terminated marker is a common
        // authoring slip); the marker itself must still be exact.
        let marker = String(decoding: try archive.read("mimetype", limit: 64), as: UTF8.self)
        guard marker.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw EPUBError.invalidMimetype
        }

        try DRMDetector.rejectProtectedMarkers(in: archive)

        let container = try XMLDocumentParser.parse(
            try archive.read("META-INF/container.xml", limit: 256 * 1024)
        )
        guard let rootfile = container.firstElement(named: "rootfile")?.attribute(named: "full-path"),
              let packagePath = ArchivePath.normalized(rootfile) else {
            throw EPUBError.invalidContainer
        }

        let package = try PackageParser.parse(
            try archive.read(packagePath, limit: 2 * 1024 * 1024),
            packagePath: packagePath
        )
        try DRMDetector.rejectEncryptedContent(in: archive, package: package)
        var contents = try NavigationParser.parse(package: package, archive: archive)
        let extras = NavigationExtrasParser.parse(package: package, archive: archive)
        let titleByChapter = Dictionary(
            contents.map { ($0.chapterIndex, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )

        let bookTitle = package.title.isEmpty ? url.deletingPathExtension().lastPathComponent : package.title
        // A spine file without its own contents entry continues the entry
        // before it (chapters are often split across files).
        var runningTitle = bookTitle
        let chapters = package.spine.enumerated().map { index, item in
            let isLinear = !package.nonlinear.contains(index)
            // A supplement's title never carries on into the reading flow.
            let title = titleByChapter[index] ?? runningTitle
            if isLinear { runningTitle = title }
            return EPUBChapter(id: item.id, title: title, path: item.path, isImage: item.isSVG, isLinear: isLinear,
                               layout: package.layout(ofSpineItem: index), side: package.side(ofSpineItem: index))
        }
        guard !chapters.isEmpty else { throw EPUBError.invalidPackage }

        if contents.isEmpty {
            contents = chapters.enumerated().map {
                EPUBContentsEntry(title: $0.element.title, chapterIndex: $0.offset, fragment: nil)
            }
        }
        return EPUBBook(
            title: bookTitle,
            identifier: package.identifier,
            authors: package.authors,
            chapters: chapters,
            contents: contents,
            pageList: extras.pageList,
            landmarks: extras.landmarks,
            layout: package.layout,
            // Vertical-rl text reads right to left unless the spine says otherwise.
            pageProgression: !package.declaresProgression
                && WritingModeScanner.readsRightToLeft(spine: package.spine, archive: archive)
                ? .rightToLeft : package.pageProgression,
            fixedPageSize: EPUBFixedPageSize.common(in: chapters, archive: archive, packageViewport: package.viewport),
            packageViewport: package.viewport,
            images: EPUBImageStore(sourceURL: url),
            stylesheets: archive.stylesheets,
            mediaOverlays: MediaOverlayParser.overlays(package: package, archive: archive)
        )
    }

    /// Renders one chapter; images scale down to fit `imageBounds` (for paged
    /// layout, the page's text area).
    public func renderChapter(
        at index: Int,
        imageBounds: CGSize = CGSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    ) throws -> EPUBRenderedChapter {
        guard chapters.indices.contains(index) else { throw EPUBError.invalidPackage }
        let chapter = chapters[index]
        let archive = try ArchiveReader(url: sourceURL, stylesheets: stylesheets)
        let bytes = try source(of: chapter, in: archive)
        let renderer = XHTMLRenderer(
            archive: archive, resourcePath: chapter.path, images: images, imageBounds: imageBounds,
            keepsNotesInline: chapter.layout == .fixed
        )
        let attributedText = try renderer.render(bytes)
        var fixedPage: EPUBFixedPage?
        if chapter.layout == .fixed {
            fixedPage = EPUBFixedPageBuilder(bytes: bytes, chapter: chapter, archive: archive,
                                             packageViewport: packageViewport)?
                .page(rendered: attributedText, elements: renderer.elementRanges,
                      images: renderer.installedImages, store: images)
            if fixedPage == nil { renderer.addNotice(.fixedLayoutFallback) }
        }
        return EPUBRenderedChapter(
            chapter: chapter,
            attributedText: attributedText,
            anchors: renderer.anchors,
            noteTargets: renderer.noteTargets,
            detachedNotes: renderer.detachedNotes,
            detachedNoteIDs: renderer.detachedNoteIDs,
            estimatedMemoryCost: renderer.estimatedMemoryCost,
            notices: renderer.notices,
            fixedPage: fixedPage
        )
    }

    /// The sides of a spread the book's fixed pages are made for, by chapter.
    public var pageSides: [Int: EPUBPageSide] {
        chapters.indices.reduce(into: [:]) { sides, index in
            if let side = chapters[index].side { sides[index] = side }
        }
    }

    /// The spine items outside the reading flow (linear="no").
    public var excludedChapters: Set<Int> { Set(chapters.indices.filter { !chapters[$0].isLinear }) }

    public func search(_ query: String) throws -> [EPUBSearchResult] {
        try searchBook(query).results
    }

    /// A chapter's XHTML; an SVG page becomes a document holding just that image.
    func source(of chapter: EPUBChapter, in archive: ArchiveReader) throws -> Data {
        guard chapter.isImage else { return try archive.read(chapter.path, limit: 8 * 1024 * 1024) }
        let name = (chapter.path as NSString).lastPathComponent
        let href = (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        return Data(#"<html xmlns="http://www.w3.org/1999/xhtml"><body><img src="\#(href)"/></body></html>"#.utf8)
    }
}
