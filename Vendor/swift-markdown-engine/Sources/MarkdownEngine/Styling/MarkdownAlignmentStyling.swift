//
//  MarkdownAlignmentStyling.swift
//  MarkdownEngine
//
//  Renders `<div align="…">` wrappers (MarkdownSourceFormatting+Alignment):
//  the block between them takes the alignment, and the tag lines with the
//  blank lines just inside them collapse out of sight, like hidden markers.
//

import AppKit

enum MarkdownAlignmentStyling {
    /// `ranges` with every paragraph style inside a wrapper aligned, plus the
    /// hidden tag lines. Cheap when the note has no wrapper.
    static func applying(
        to ranges: [StyledRange],
        text: String,
        base: NSParagraphStyle,
        hiddenFont: NSFont
    ) -> [StyledRange] {
        let ns = text as NSString
        guard ns.range(of: "<div align=", options: .caseInsensitive).location != NSNotFound else { return ranges }
        let regions = Self.regions(in: ns)
        guard !regions.isEmpty else { return ranges }

        func aligned(_ style: NSParagraphStyle, _ alignment: NSTextAlignment) -> NSParagraphStyle {
            let copy = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            copy.alignment = alignment
            return copy
        }
        var result: [StyledRange] = []
        result.reserveCapacity(ranges.count + regions.count * 3)
        // Plain paragraphs carry only the base style: give the body an aligned one
        // first, so block styles applied later still win (and get aligned below).
        for region in regions {
            result.append((region.body, [.paragraphStyle: aligned(base, region.alignment)]))
        }
        for (range, attributes) in ranges {
            // An image line keeps its own alignment token, even inside a wrapper.
            guard let style = attributes[.paragraphStyle] as? NSParagraphStyle, !isImageLine(at: range.location, in: ns),
                  let region = regions.first(where: { NSLocationInRange(range.location, $0.body) }) else {
                result.append((range, attributes))
                continue
            }
            var patched = attributes
            patched[.paragraphStyle] = aligned(style, region.alignment)
            result.append((range, patched))
        }
        // The same no-height line the collapsed image separator uses.
        let hidden: [NSAttributedString.Key: Any] = [
            .font: hiddenFont, .foregroundColor: NSColor.clear, .paragraphStyle: MarkdownStyler.collapsedSeparatorStyle
        ]
        for region in regions {
            for line in region.hiddenLines { result.append((line, hidden)) }
        }
        return result
    }

    private static func isImageLine(at location: Int, in ns: NSString) -> Bool {
        guard location < ns.length else { return false }
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: location, length: 0)))
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("![")
    }

    struct Region {
        let alignment: NSTextAlignment
        let open: NSRange
        let close: NSRange
        /// The aligned content between the hidden lines.
        let body: NSRange
        /// The tag lines and the blank lines just inside them.
        let hiddenLines: [NSRange]
        /// Open tag through close tag.
        var span: NSRange { NSUnionRange(open, close) }
    }

    /// Every wrapper outside fenced code, found by searching for the tags
    /// rather than walking every line (this runs on each restyle).
    static func regions(in ns: NSString) -> [Region] {
        let fences = fencedRanges(in: ns)
        func lines(containing needle: String) -> [NSRange] {
            var found: [NSRange] = []
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let hit = ns.range(of: needle, options: .caseInsensitive, range: search)
                guard hit.location != NSNotFound else { break }
                let line = ns.lineRange(for: hit)
                if !fences.contains(where: { NSLocationInRange(hit.location, $0) }) { found.append(line) }
                search = NSRange(location: NSMaxRange(line), length: ns.length - NSMaxRange(line))
            }
            return found
        }
        func content(_ line: NSRange) -> String { ns.substring(with: line).trimmingCharacters(in: .newlines) }
        func isBlank(_ line: NSRange) -> Bool { content(line).trimmingCharacters(in: .whitespaces).isEmpty }
        let opens = lines(containing: "<div align=").compactMap { line in
            MarkdownSourceFormatting.alignmentTag(in: content(line)).map { (line, $0) }
        }
        guard !opens.isEmpty else { return [] }
        let closes = lines(containing: "</div>").filter { MarkdownSourceFormatting.isClosingTag(content($0)) }

        var regions: [Region] = []
        for (index, (open, alignment)) in opens.enumerated() {
            // The first close after this open, before the next open: no nesting.
            let limit = index + 1 < opens.count ? opens[index + 1].0.location : ns.length
            guard let close = closes.first(where: { $0.location > open.location && $0.location < limit }) else { continue }
            var first = NSMaxRange(open)
            var last = close.location
            var hidden = [open, close]
            if first < last, case let line = ns.lineRange(for: NSRange(location: first, length: 0)), isBlank(line) {
                hidden.append(line); first = NSMaxRange(line)
            }
            if first < last, case let line = ns.lineRange(for: NSRange(location: last - 1, length: 0)), isBlank(line) {
                hidden.append(line); last = line.location
            }
            guard first < last else { continue }
            regions.append(Region(alignment: alignment.nsTextAlignment, open: open, close: close,
                                  body: NSRange(location: first, length: last - first), hiddenLines: hidden))
        }
        return regions
    }

    /// Fenced code (``` or ~~~ at a line start through its closing fence).
    static func fencedRanges(in ns: NSString) -> [NSRange] {
        guard ns.range(of: "```").location != NSNotFound || ns.range(of: "~~~").location != NSNotFound else { return [] }
        var ranges: [NSRange] = []
        var openFence: (start: Int, marker: String)?
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, enclosing, _ in
            let trimmed = (line ?? "").trimmingCharacters(in: .whitespaces)
            let marker = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            guard let marker else { return }
            if let open = openFence {
                if marker == open.marker {
                    ranges.append(NSRange(location: open.start, length: NSMaxRange(enclosing) - open.start))
                    openFence = nil
                }
            } else {
                openFence = (range.location, marker)
            }
        }
        if let open = openFence { ranges.append(NSRange(location: open.start, length: ns.length - open.start)) }
        return ranges
    }
}

extension MarkdownTextAlignment {
    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justify: .justified
        }
    }
}
