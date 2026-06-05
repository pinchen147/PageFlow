//
//  MathTextParser.swift
//  PageFlow
//
//  Parses comment text to extract LaTeX math expressions ($...$ and $$...$$)
//

import Foundation

/// A segment of parsed comment text
enum TextSegment: Equatable {
    case plain(String)
    case inlineMath(String)   // $...$
    case displayMath(String)  // $$...$$
}

/// Parser for extracting LaTeX math from comment text
struct MathTextParser {

    // Compiled once and reused across calls — building these per parse was the
    // dominant cost when re-rendering comment bubbles that contain math.
    private static let displayRegex = try? NSRegularExpression(pattern: "\\$\\$(.+?)\\$\\$", options: .dotMatchesLineSeparators)
    private static let inlineRegex = try? NSRegularExpression(pattern: "\\$([^$]+?)\\$", options: [])

    /// Parses text containing LaTeX delimiters into segments.
    /// Returns nil if text contains no math delimiters (optimization for plain text).
    static func parse(_ text: String) -> [TextSegment]? {
        // Fast path: no dollar sign means no math
        guard text.contains("$") else {
            return nil
        }

        // Find all math regions (display first, then inline)
        var mathRanges: [(range: Range<String.Index>, isDisplay: Bool, content: String)] = []

        // Find display math: $$...$$
        if let displayRegex = Self.displayRegex {
            let nsRange = NSRange(text.startIndex..., in: text)
            displayRegex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
                guard let match = match,
                      let fullRange = Range(match.range, in: text),
                      let contentRange = Range(match.range(at: 1), in: text) else { return }
                let content = String(text[contentRange])
                if !content.trimmingCharacters(in: .whitespaces).isEmpty {
                    mathRanges.append((fullRange, true, content))
                }
            }
        }

        // Find inline math: $...$ (but not inside display math regions)
        if let inlineRegex = Self.inlineRegex {
            let nsRange = NSRange(text.startIndex..., in: text)
            inlineRegex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
                guard let match = match,
                      let fullRange = Range(match.range, in: text),
                      let contentRange = Range(match.range(at: 1), in: text) else { return }

                // Skip if this overlaps with any display math
                let overlaps = mathRanges.contains { existing in
                    existing.range.overlaps(fullRange)
                }
                guard !overlaps else { return }

                let content = String(text[contentRange])
                if !content.trimmingCharacters(in: .whitespaces).isEmpty {
                    mathRanges.append((fullRange, false, content))
                }
            }
        }

        // If no math found, return nil
        guard !mathRanges.isEmpty else {
            return nil
        }

        // Sort by position
        mathRanges.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Build segments
        var segments: [TextSegment] = []
        var currentIndex = text.startIndex

        for mathRegion in mathRanges {
            // Add plain text before this math
            if currentIndex < mathRegion.range.lowerBound {
                let plainText = String(text[currentIndex..<mathRegion.range.lowerBound])
                let processed = plainText.replacingOccurrences(of: "\\$", with: "$")
                if !processed.isEmpty {
                    segments.append(.plain(processed))
                }
            }

            // Add the math segment
            if mathRegion.isDisplay {
                segments.append(.displayMath(mathRegion.content))
            } else {
                segments.append(.inlineMath(mathRegion.content))
            }

            currentIndex = mathRegion.range.upperBound
        }

        // Add any remaining plain text
        if currentIndex < text.endIndex {
            let plainText = String(text[currentIndex...])
            let processed = plainText.replacingOccurrences(of: "\\$", with: "$")
            if !processed.isEmpty {
                segments.append(.plain(processed))
            }
        }

        return segments.isEmpty ? nil : segments
    }
}
