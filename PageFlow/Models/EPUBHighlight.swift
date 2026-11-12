//
//  EPUBHighlight.swift
//  PageFlow
//
//  A highlighted passage in an EPUB, with an optional note. Its place is a
//  range of UTF-16 offsets in its chapter's styled text, so it stays on the
//  same words whatever the page size or text settings.
//

import AppKit
import Foundation

/// How a highlight marks its words: a tint behind them, or a line under them.
enum EPUBHighlightStyle: String, Codable, Equatable, Sendable {
    case tint
    case underline
}

extension EPUBHighlightStyle {
    var passageLabel: String { self == .underline ? "Underlined" : "Highlighted" }
    var removalTitle: String { self == .underline ? "Remove Underline" : "Remove Highlight" }

    /// The colours this kind of mark offers.
    @MainActor var presets: [SettingsManager.ColorPreset] {
        switch self {
        case .tint: SettingsManager.shared.highlightPresets
        case .underline: SettingsManager.shared.underlinePresets
        }
    }
}

struct EPUBHighlight: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var chapterIndex: Int
    /// UTF-16 offsets in the chapter's styled text.
    var range: NSRange
    /// A highlight colour as `#RRGGBB` or `#RRGGBBAA`, from the same presets as PDF's.
    var color: String
    var style: EPUBHighlightStyle
    /// The reader's note; nil (or blank) when there is none.
    var note: String?
    /// The highlighted words, kept for the sidebar when the chapter isn't styled.
    var excerpt: String
    let createdAt: Date

    init(id: UUID = UUID(), chapterIndex: Int, range: NSRange, color: String, style: EPUBHighlightStyle = .tint,
         note: String? = nil, excerpt: String = "", createdAt: Date = Date()) {
        self.id = id
        self.chapterIndex = max(0, chapterIndex)
        self.range = NSRange(location: max(0, range.location), length: max(0, range.length))
        self.color = color
        self.style = style
        self.note = note
        self.excerpt = excerpt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, chapterIndex, location, length, color, style, note, excerpt, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            chapterIndex: container.decode(Int.self, forKey: .chapterIndex),
            range: NSRange(location: container.decode(Int.self, forKey: .location),
                           length: container.decode(Int.self, forKey: .length)),
            color: container.decode(String.self, forKey: .color),
            // Highlights from before underlines are tints; a style a later
            // build adds reads as one too.
            style: (try? container.decodeIfPresent(EPUBHighlightStyle.self, forKey: .style)) ?? .tint,
            note: container.decodeIfPresent(String.self, forKey: .note),
            excerpt: container.decodeIfPresent(String.self, forKey: .excerpt) ?? "",
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(chapterIndex, forKey: .chapterIndex)
        try container.encode(range.location, forKey: .location)
        try container.encode(range.length, forKey: .length)
        try container.encode(color, forKey: .color)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(excerpt, forKey: .excerpt)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Whether the reader wrote something.
    var hasNote: Bool { !(note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Has a note's card, in the panel and on the page, even with nothing
    /// written in it, as an empty PDF comment keeps its bubble.
    var isNote: Bool { note != nil }

    /// The colours this mark offers: a note's are Settings' comment colours,
    /// as a PDF comment's are.
    @MainActor func presets(asNote: Bool) -> [SettingsManager.ColorPreset] {
        asNote && style == .tint ? SettingsManager.shared.commentPresets : style.presets
    }

    var nsColor: NSColor { SettingsManager.ColorPreset.color(fromHex: color) ?? DesignTokens.highlightYellow }

    /// Reading order: by chapter, then by where the highlight starts.
    static func inReadingOrder(_ lhs: EPUBHighlight, _ rhs: EPUBHighlight) -> Bool {
        (lhs.chapterIndex, lhs.range.location, lhs.range.length)
            < (rhs.chapterIndex, rhs.range.location, rhs.range.length)
    }
}

extension Array where Element == EPUBHighlight {
    /// Highlights `range` in `chapter`. One that overlaps existing highlights
    /// (or touches one of its colour and style) merges with them into one,
    /// taking the new colour and style and keeping every note; the result
    /// keeps the first one's id. Returns that id.
    @discardableResult
    mutating func addHighlight(chapter: Int, range: NSRange, color: String, style: EPUBHighlightStyle = .tint,
                               excerpt: (NSRange) -> String) -> UUID? {
        guard range.length > 0 else { return nil }
        let touching = indices.filter {
            let other = self[$0]
            guard other.chapterIndex == chapter else { return false }
            let overlaps = other.range.location < NSMaxRange(range) && range.location < NSMaxRange(other.range)
            let adjoins = other.range.location == NSMaxRange(range) || range.location == NSMaxRange(other.range)
            return overlaps || (adjoins && other.style == style && SettingsManager.ColorPreset.colorsMatch(other.color, color))
        }
        var merged = range
        for index in touching { merged = NSUnionRange(merged, self[index].range) }
        let existing = touching.map { self[$0] }.sorted(by: EPUBHighlight.inReadingOrder)
        let notes = existing.compactMap(\.note).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let highlight = EPUBHighlight(
            id: existing.first?.id ?? UUID(),
            chapterIndex: chapter,
            range: merged,
            color: color,
            style: style,
            note: notes.isEmpty ? nil : notes.joined(separator: "\n\n"),
            excerpt: excerpt(merged),
            createdAt: existing.map(\.createdAt).min() ?? Date()
        )
        for index in touching.reversed() { remove(at: index) }
        append(highlight)
        sort(by: EPUBHighlight.inReadingOrder)
        return highlight.id
    }

    /// The highlight covering `offset` in `chapter`, if any.
    func highlight(chapter: Int, containing offset: Int) -> EPUBHighlight? {
        first { $0.chapterIndex == chapter && NSLocationInRange(offset, $0.range) }
    }
}
