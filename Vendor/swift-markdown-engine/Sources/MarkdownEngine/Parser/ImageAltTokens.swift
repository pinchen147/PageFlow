//
//  ImageAltTokens.swift
//  MarkdownEngine
//
//  The size, alignment and crop an image keeps in its alt text (doc 26 §2):
//  `![Chart|center|crop=0.12,0.05,0.8,0.9|420](chart.png)`. Tokens follow
//  unescaped `|` separators and are read from the right, in any order; the
//  first segment that is not a token, plus everything left of it, is the
//  description, kept byte for byte. The writer puts the width last so
//  Obsidian, which reads only a trailing width, still sizes the image. The
//  image file itself never changes: a crop is a normalized rect drawn from it.
//

import CoreGraphics
import Foundation

/// Portable display metadata encoded in an image's Markdown description.
public struct ImageAltTokens: Equatable, Sendable {
    /// Horizontal placement within the editor's reading column.
    public enum Alignment: String, Sendable, CaseIterable {
        /// Align the image with the column's leading edge.
        case left
        /// Center the image within the column.
        case center
        /// Align the image with the column's trailing edge.
        case right
    }

    /// The description as written in the source, escapes included.
    public var description: String
    /// The display width in points (`|420`), or nil to size from the image.
    public var width: CGFloat?
    /// Horizontal placement; descriptions without a token default to left.
    public var alignment: Alignment
    /// The kept part of the source image as normalized x, y, w, h from its
    /// top-left corner, or nil for the whole image.
    public var crop: CGRect?

    /// Creates metadata without changing the underlying image or its destination.
    public init(description: String = "", width: CGFloat? = nil, alignment: Alignment = .left, crop: CGRect? = nil) {
        self.description = description
        self.width = width
        self.alignment = alignment
        self.crop = crop
    }

    /// The description as a person reads it: backslash escapes decoded.
    public var displayDescription: String { Self.unescape(description) }

    /// The image's size once cropped: `natural` scaled by the crop's w and h.
    public func croppedSize(of natural: CGSize) -> CGSize {
        guard let crop else { return natural }
        return CGSize(width: natural.width * crop.width, height: natural.height * crop.height)
    }

    // MARK: Reading

    /// Reads `alt`, the text between `![` and `]` (or inside `![[…]]`).
    /// A segment that is not a whole valid token is description text, never a
    /// half-token; the rightmost token of each kind wins and duplicates to its
    /// left are dropped.
    public static func parse(_ alt: String) -> ImageAltTokens {
        let text = alt as NSString
        let segments = segmentRanges(in: text)
        var tokens = ImageAltTokens()
        var seenWidth = false, seenAlignment = false, seenCrop = false
        var last = segments.count - 1
        // The first segment is always description, so `|420` alone is a width
        // but `420` alone is a description.
        while last >= 1 {
            let segment = text.substring(with: segments[last]).trimmingCharacters(in: spacesAndTabs)
            guard let token = Token(segment) else { break }
            switch token {
            case .width(let value):
                if !seenWidth { tokens.width = value }
                seenWidth = true
            case .alignment(let value):
                if !seenAlignment { tokens.alignment = value }
                seenAlignment = true
            case .crop(let rect):
                // A full rect is a valid token that means "no crop".
                if !seenCrop { tokens.crop = isFullRect(rect) ? nil : rect }
                seenCrop = true
            }
            last -= 1
        }
        tokens.description = text.substring(to: NSMaxRange(segments[last]))
        return tokens
    }

    /// The ranges between unescaped `|` characters. A `|` after an odd number
    /// of backslashes is a literal pipe.
    private static func segmentRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        var backslashes = 0
        for index in 0..<text.length {
            let unit = text.character(at: index)
            if unit == backslash {
                backslashes += 1
                continue
            }
            if unit == pipe, backslashes % 2 == 0 {
                ranges.append(NSRange(location: start, length: index - start))
                start = index + 1
            }
            backslashes = 0
        }
        ranges.append(NSRange(location: start, length: text.length - start))
        return ranges
    }

    private enum Token {
        case width(CGFloat)
        case alignment(Alignment)
        case crop(CGRect)

        init?(_ segment: String) {
            let lowered = segment.lowercased()
            if let alignment = Alignment(rawValue: lowered) {
                self = .alignment(alignment)
            } else if let width = Self.width(lowered) {
                self = .width(width)
            } else if lowered.hasPrefix("crop="), let rect = Self.crop(lowered.dropFirst(5)) {
                self = .crop(rect)
            } else {
                return nil
            }
        }

        /// `420` or Obsidian's `640x480` (the height is read and ignored).
        private static func width(_ segment: String) -> CGFloat? {
            let parts = segment.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.allSatisfy({ (1...6).contains($0.count) && $0.allSatisfy(\.isASCIIDigit) }),
                  let value = Int(parts[0]), (1...ImageAltTokens.maximumWidth).contains(value) else { return nil }
            return CGFloat(value)
        }

        private static func crop(_ numbers: Substring) -> CGRect? {
            let parts = numbers.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var values: [Double] = []
            for part in parts {
                guard let value = fraction(part) else { return nil }
                values.append(value)
            }
            let (x, y, w, h) = (values[0], values[1], values[2], values[3])
            guard w >= 0.01, h >= 0.01, x + w <= 1.0001, y + h <= 1.0001 else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        /// A plain decimal in [0, 1]: `0`, `1`, `0.5`, `.5`, `0.1234`.
        private static func fraction(_ text: Substring) -> Double? {
            let pieces = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
                  pieces.contains(where: { !$0.isEmpty }),
                  let value = Double(text), value.isFinite, (0...1).contains(value) else { return nil }
            return value
        }
    }

    // MARK: Writing

    /// The alt text for `tokens`: the description, then `|center` or `|right`,
    /// then `|crop=x,y,w,h`, then `|<width>` LAST (O9). Defaults are omitted:
    /// no width token without a width, no `left`, no full-rect crop.
    public static func format(_ tokens: ImageAltTokens) -> String {
        var suffix = ""
        if tokens.alignment != .left {
            suffix += "|" + tokens.alignment.rawValue
        }
        if let crop = tokens.crop.map(writableCrop), !isFullRect(crop) {
            suffix += "|crop=" + [crop.minX, crop.minY, crop.width, crop.height].map(formatFraction).joined(separator: ",")
        }
        if let width = tokens.width {
            let rounded = Int(min(max(width.rounded(.toNearestOrAwayFromZero), 1), CGFloat(maximumWidth)))
            suffix += "|\(rounded)"
        }
        var description = tokens.description
        // A description ending in an odd run of backslashes would escape the
        // first separator; doubling the last one keeps the text it reads as.
        if !suffix.isEmpty, description.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 {
            description += "\\"
        }
        return description + suffix
    }

    /// A description someone typed, made safe to write: tabs, newlines, other
    /// control characters and bidi controls removed, whitespace collapsed and
    /// trimmed, at most 2048 UTF-16 units (a surrogate pair is never split),
    /// then `\`, `[`, `]` and `|` escaped.
    public static func sanitizedDescription(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control && !bidiControls.contains(scalar.value)
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var capped = ""
        var units = 0
        for scalar in collapsed.unicodeScalars {
            units += scalar.utf16.count
            guard units <= maximumDescriptionLength else { break }
            capped.unicodeScalars.append(scalar)
        }
        return escape(capped)
    }

    /// `\`, `[`, `]` and `|` backslash-escaped, so the text stays one alt
    /// segment inside one image.
    public static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "[" || character == "]" || character == "|" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// CommonMark backslash escapes decoded: a backslash before ASCII
    /// punctuation stands for that punctuation; any other backslash is literal.
    public static func unescape(_ text: String) -> String {
        var decoded = ""
        var pendingBackslash = false
        for character in text {
            if pendingBackslash {
                pendingBackslash = false
                if character.isASCII, character.isPunctuation || character.isSymbol {
                    decoded.append(character)
                    continue
                }
                decoded.append("\\")
            }
            if character == "\\" {
                pendingBackslash = true
            } else {
                decoded.append(character)
            }
        }
        if pendingBackslash { decoded.append("\\") }
        return decoded
    }

    // MARK: Shared

    /// Largest width accepted from a portable image token, in points.
    public static let maximumWidth = 100_000
    /// Maximum description length accepted by the alt-text editor.
    public static let maximumDescriptionLength = 2_048

    /// True for a crop that keeps the whole image.
    public static func isFullRect(_ rect: CGRect) -> Bool {
        rect.minX == 0 && rect.minY == 0 && rect.width >= 0.9999 && rect.height >= 0.9999
    }

    /// `rect` rounded to 4 decimals and kept readable: every token written
    /// reads back as the same crop.
    private static func writableCrop(_ rect: CGRect) -> CGRect {
        func round4(_ value: CGFloat) -> CGFloat { (min(max(value, 0), 1) * 10_000).rounded() / 10_000 }
        let width = max(round4(rect.width), 0.01)
        let height = max(round4(rect.height), 0.01)
        return CGRect(x: min(round4(rect.minX), 1 - width), y: min(round4(rect.minY), 1 - height),
                      width: width, height: height)
    }

    /// `0`, `1`, or `0.` plus up to 4 decimals without trailing zeros.
    private static func formatFraction(_ value: CGFloat) -> String {
        let tenThousandths = Int((value * 10_000).rounded())
        if tenThousandths <= 0 { return "0" }
        if tenThousandths >= 10_000 { return "1" }
        var digits = String(tenThousandths)
        digits = String(repeating: "0", count: 4 - digits.count) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "0." + digits
    }

    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let pipe = unichar(UInt8(ascii: "|"))
    private static let spacesAndTabs = CharacterSet(charactersIn: " \t")
    private static let bidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
