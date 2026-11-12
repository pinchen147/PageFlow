//
//  EPUBReaderState.swift
//  PageFlow
//
//  Persisted EPUB reader state: where the user left off (chapter + character
//  offset), how the book is laid out, and the typography in effect. Carried
//  by `DocumentViewState` so an EPUB reopens exactly as it was left, like the
//  PDF and Markdown entries. Bookmarks and highlights now live in
//  `EPUBAnnotationStore`; the fields here are read to move older records.
//

import Foundation

/// How EPUB pages are arranged, named like PDF's display modes.
enum EPUBPageLayout: String, Codable, Equatable, Sendable, CaseIterable {
    case singlePageContinuous
    case singlePage
    case twoUp
    case twoUpContinuous

    var title: String {
        switch self {
        case .singlePageContinuous: return "Single Page Continuous"
        case .singlePage: return "Single Page"
        case .twoUp: return "Two Pages"
        case .twoUpContinuous: return "Two Pages Continuous"
        }
    }

    var pagesPerRow: Int { self == .twoUp || self == .twoUpContinuous ? 2 : 1 }
    var isContinuous: Bool { self == .singlePageContinuous || self == .twoUpContinuous }

    /// Accepts the earlier Scroll / Pages / Book values.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "continuous": self = .singlePageContinuous
        case "paged": self = .singlePage
        case "book": self = .twoUp
        default: self = EPUBPageLayout(rawValue: raw) ?? .singlePageContinuous
        }
    }
}

/// The font family EPUB text is rendered with. The system font is already a
/// sans-serif, so the choice is between the default and a serif design.
enum EPUBFontFamily: String, Codable, Equatable, Sendable {
    case system
    case serif
}

/// How much paper surrounds the text. Wider margins also shorten the
/// longest line, so a large page keeps them.
nonisolated enum EPUBPageMargins: String, Codable, Equatable, Sendable, CaseIterable {
    case narrow
    case normal
    case wide

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .normal: "Normal"
        case .wide: "Wide"
        }
    }

    /// The least space around the text; the running header and page number
    /// sit in the top and bottom margins.
    var insets: NSEdgeInsets {
        switch self {
        case .narrow: NSEdgeInsets(top: 48, left: 28, bottom: 48, right: 28)
        case .normal: NSEdgeInsets(top: 64, left: 56, bottom: 64, right: 56)
        case .wide: NSEdgeInsets(top: 72, left: 88, bottom: 72, right: 88)
        }
    }

    /// The longest line, in ems of the body text.
    var measureInEms: CGFloat {
        switch self {
        case .narrow: 46
        case .normal: 40
        case .wide: 34
        }
    }
}

/// How EPUB pages are sized and scaled to the window.
enum EPUBZoom: Codable, Equatable, Sendable {
    /// Pages take the window's size and the text re-flows (Reflow to Fit).
    case reflow
    /// Pages keep their size, scaled to fit the window (Zoom to Fit).
    case fit
    /// Pages keep their size at this scale (1 = 100%).
    case scale(CGFloat)

    /// The explicit scale; nil while the pages are fitted to the window.
    var pageScale: CGFloat? {
        if case .scale(let scale) = self { scale } else { nil }
    }
}

/// The reader's page colours. `system` follows the Mac's appearance (Light
/// or Dark), like Markdown's default; the others pin a scheme.
enum EPUBReaderTheme: String, Codable, Equatable, Sendable {
    case system
    case light
    case sepia
    case dark

    /// The colours pages are drawn in, with `system` following `isDark`.
    func palette(isDark: Bool) -> EPUBPagePalette {
        switch self {
        case .system: isDark ? .dark : .light
        case .light: .light
        case .sepia: .sepia
        case .dark: .dark
        }
    }
}

/// The colours a page is actually drawn in: a theme the reader chose, with
/// System already settled for the Mac's appearance.
enum EPUBPagePalette: Equatable, Sendable {
    case light
    case sepia
    case dark
}

/// EPUB text presentation. Sizes are clamped to a readable range so a
/// hand-edited or future record can't produce an unusable layout.
struct EPUBTypography: Codable, Equatable, Sendable {
    static let fontSizeRange: ClosedRange<CGFloat> = 12...32
    static let lineHeightRange: ClosedRange<CGFloat> = 1.0...2.5
    /// Space added after each body paragraph, in ems.
    static let paragraphSpacingRange: ClosedRange<CGFloat> = 0...1.5

    var family: EPUBFontFamily
    /// An installed font family chosen over `family`; nil for the preset.
    var fontName: String?
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var theme: EPUBReaderTheme
    var margins: EPUBPageMargins
    /// Body text set flush to both edges, as the book's renderer sets it.
    var isJustified: Bool
    var isHyphenated: Bool
    var paragraphSpacing: CGFloat

    init(family: EPUBFontFamily = .system, fontName: String? = nil, fontSize: CGFloat = 17,
         lineHeight: CGFloat = 1.4, theme: EPUBReaderTheme = .system, margins: EPUBPageMargins = .normal,
         isJustified: Bool = true, isHyphenated: Bool = true, paragraphSpacing: CGFloat = 0) {
        self.family = family
        self.fontName = fontName.flatMap { $0.isEmpty ? nil : $0 }
        self.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        self.lineHeight = min(max(lineHeight, Self.lineHeightRange.lowerBound), Self.lineHeightRange.upperBound)
        self.theme = theme
        self.margins = margins
        self.isJustified = isJustified
        self.isHyphenated = isHyphenated
        self.paragraphSpacing = min(max(paragraphSpacing, Self.paragraphSpacingRange.lowerBound),
                                    Self.paragraphSpacingRange.upperBound)
    }

    /// The chosen font if this Mac has it; without it text falls back to the family.
    var installedFontName: String? {
        fontName.flatMap { EPUBTextStyling.isInstalled($0) ? $0 : nil }
    }

    /// The settings that move text between pages: everything but the theme.
    /// Keyed on the font drawn, so removing a font can't reuse its page breaks.
    var layoutSignature: String {
        [family.rawValue, installedFontName ?? "", "\(fontSize)", "\(lineHeight)", margins.rawValue,
         isJustified ? "justified" : "ragged", isHyphenated ? "hyphenated" : "whole", "\(paragraphSpacing)"]
            .joined(separator: "|")
    }

    /// Whether text breaks into the same pages under both.
    func paginatesLike(_ other: EPUBTypography) -> Bool { layoutSignature == other.layoutSignature }

    private enum CodingKeys: String, CodingKey {
        case family, fontSize, lineHeight
        /// Builds before the System theme: Light was the default, not a choice.
        case theme
        case colorTheme
        // Added with the text settings; older records take the defaults.
        case fontName, margins, isJustified, isHyphenated, paragraphSpacing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A record from before the System theme saved its default as Light:
        // it follows the Mac now, like a new book. Sepia and Dark were chosen.
        let theme: EPUBReaderTheme
        if let chosen = try container.decodeIfPresent(EPUBReaderTheme.self, forKey: .colorTheme) {
            theme = chosen
        } else {
            let legacy = try container.decode(EPUBReaderTheme.self, forKey: .theme)
            theme = legacy == .light ? .system : legacy
        }
        try self.init(
            family: container.decode(EPUBFontFamily.self, forKey: .family),
            fontName: container.decodeIfPresent(String.self, forKey: .fontName),
            fontSize: container.decode(CGFloat.self, forKey: .fontSize),
            lineHeight: container.decode(CGFloat.self, forKey: .lineHeight),
            theme: theme,
            // A margin a later build adds reads as Normal here.
            margins: (try? container.decodeIfPresent(EPUBPageMargins.self, forKey: .margins)) ?? .normal,
            isJustified: container.decodeIfPresent(Bool.self, forKey: .isJustified) ?? true,
            isHyphenated: container.decodeIfPresent(Bool.self, forKey: .isHyphenated) ?? true,
            paragraphSpacing: container.decodeIfPresent(CGFloat.self, forKey: .paragraphSpacing) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(family, forKey: .family)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(lineHeight, forKey: .lineHeight)
        try container.encode(theme, forKey: .colorTheme)
        // Older builds read `theme` and don't know System.
        try container.encode(theme == .system ? .light : theme, forKey: .theme)
        try container.encodeIfPresent(fontName, forKey: .fontName)
        try container.encode(margins, forKey: .margins)
        try container.encode(isJustified, forKey: .isJustified)
        try container.encode(isHyphenated, forKey: .isHyphenated)
        try container.encode(paragraphSpacing, forKey: .paragraphSpacing)
    }
}

/// Where the reader's view sits, finer than a page: the text at its top edge
/// and how far below that text's line the edge is. Kept in the text, so it
/// still means the same words after a re-layout; in the same layout it comes
/// back to the same scroll offset.
nonisolated struct EPUBReadingPlace: Codable, Equatable, Sendable {
    var chapter: Int
    var offset: Int
    /// Page points from the top of the line holding `offset` to the view's top edge.
    var delta: CGFloat
    /// How far the pages are panned sideways, in page points.
    var x: CGFloat
}

/// A reading place and the page it is on now.
struct EPUBReadingSpot: Equatable {
    let page: Int
    let place: EPUBReadingPlace
}

/// The view a book is read in, which knows where it is scrolled to.
@MainActor
protocol EPUBReadingSurface: AnyObject {
    /// Nil when there is nothing finer than the page: pages fitted to the window.
    var readingPlace: EPUBReadingPlace? { get }
    /// Told the place as the view goes, since nothing reads it after that.
    var onLeaving: ((EPUBReadingPlace?) -> Void)? { get set }
}

/// A user-placed bookmark at a location in the book.
struct EPUBBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var chapterIndex: Int
    var characterOffset: Int
    var title: String
    var excerpt: String
    let createdAt: Date

    init(id: UUID = UUID(), chapterIndex: Int, characterOffset: Int,
         title: String, excerpt: String, createdAt: Date = Date()) {
        self.id = id
        self.chapterIndex = max(0, chapterIndex)
        self.characterOffset = max(0, characterOffset)
        self.title = title
        self.excerpt = excerpt
        self.createdAt = createdAt
    }
}

/// Everything an EPUB tab needs to reopen where and how it was left.
struct EPUBPersistedReaderState: Codable, Equatable, Sendable {
    var chapterIndex: Int
    var characterOffset: Int
    var layout: EPUBPageLayout
    var typography: EPUBTypography
    /// Kept by builds before the annotation store; read once to move them
    /// there, then written empty.
    var bookmarks: [EPUBBookmark]
    /// As `bookmarks`. In reading order; a record from before highlights has none.
    var highlights: [EPUBHighlight]
    /// How the pages are sized and scaled; Reflow to Fit when unset.
    var zoom: EPUBZoom?
    /// The page size the book was laid out in (Reflow to Fit sets it).
    var pageSize: CGSize?
    /// Where in the page the view was left; a record from before this has none.
    var place: EPUBReadingPlace?

    private enum CodingKeys: String, CodingKey {
        // The layout keeps the key of the earlier reading mode.
        case chapterIndex, characterOffset, layout = "readingMode", typography, bookmarks, highlights, zoom, pageSize, place
    }

    init(chapterIndex: Int, characterOffset: Int,
         layout: EPUBPageLayout = .singlePageContinuous,
         typography: EPUBTypography = EPUBTypography(),
         bookmarks: [EPUBBookmark] = [],
         highlights: [EPUBHighlight] = [],
         zoom: EPUBZoom? = nil, pageSize: CGSize? = nil, place: EPUBReadingPlace? = nil) {
        self.chapterIndex = max(0, chapterIndex)
        self.characterOffset = max(0, characterOffset)
        self.layout = layout
        self.typography = typography
        self.bookmarks = bookmarks
        self.highlights = highlights.sorted(by: EPUBHighlight.inReadingOrder)
        self.zoom = zoom
        self.pageSize = pageSize
        self.place = place
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            chapterIndex: container.decode(Int.self, forKey: .chapterIndex),
            characterOffset: container.decode(Int.self, forKey: .characterOffset),
            layout: container.decode(EPUBPageLayout.self, forKey: .layout),
            typography: container.decode(EPUBTypography.self, forKey: .typography),
            bookmarks: container.decode([EPUBBookmark].self, forKey: .bookmarks),
            highlights: container.decodeIfPresent([EPUBHighlight].self, forKey: .highlights) ?? [],
            zoom: container.decodeIfPresent(EPUBZoom.self, forKey: .zoom),
            pageSize: container.decodeIfPresent(CGSize.self, forKey: .pageSize),
            place: container.decodeIfPresent(EPUBReadingPlace.self, forKey: .place)
        )
    }
}
