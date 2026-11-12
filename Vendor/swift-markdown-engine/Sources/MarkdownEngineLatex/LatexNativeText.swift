import Foundation

/// A formula split into SwiftMath-compatible LaTeX and trailing native text.
public struct LatexNativeTextParts: Equatable, Sendable {
    /// The LaTeX source to pass to SwiftMath.
    public let latex: String

    /// Trailing annotations to draw with the system font.
    public let annotations: [String]

    /// Whether native text occurred where moving it would change the formula.
    public let requiresSourceFallback: Bool
}

/// Separates a trailing `\text{…}` annotation when SwiftMath lacks its glyphs.
///
/// Non-ASCII text that occurs within a formula stays in place so the caller
/// can use its normal raw-source fallback without changing mathematical order.
public enum LatexNativeText {
    /// Splits a formula from a final non-ASCII `\text{…}` annotation.
    public static func split(_ source: String) -> LatexNativeTextParts {
        let marker = "\\text{"
        var output = ""
        var annotations: [String] = []
        var requiresSourceFallback = false
        var cursor = source.startIndex

        while let markerRange = source.range(of: marker, range: cursor..<source.endIndex) {
            output += source[cursor..<markerRange.lowerBound]
            var index = markerRange.upperBound
            var depth = 1
            var escaped = false
            while index < source.endIndex, depth > 0 {
                let character = source[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                }
                index = source.index(after: index)
            }
            guard depth == 0 else {
                output += source[markerRange.lowerBound...]
                cursor = source.endIndex
                break
            }

            let close = source.index(before: index)
            let text = String(source[markerRange.upperBound..<close])
            let trailingSource = source[index...]
            if text.unicodeScalars.contains(where: { !$0.isASCII }),
               trailingSource.allSatisfy(\.isWhitespace) {
                annotations.append(text)
                output += "\\,"
            } else {
                if text.unicodeScalars.contains(where: { !$0.isASCII }) {
                    requiresSourceFallback = true
                }
                output += source[markerRange.lowerBound..<index]
            }
            cursor = index
        }
        if cursor < source.endIndex { output += source[cursor...] }
        return LatexNativeTextParts(
            latex: thinningControlSpaces(in: output),
            annotations: annotations,
            requiresSourceFallback: requiresSourceFallback
        )
    }

    /// `\ ` as the thin space SwiftMath reads. Commands are read whole, since a
    /// space after a row break (`\\ `) is no control space: replaced, it reads as
    /// a row break and a literal comma.
    private static func thinningControlSpaces(in latex: String) -> String {
        var output = ""
        output.reserveCapacity(latex.utf8.count)
        var escaped = false
        for character in latex {
            if escaped {
                output.append(character == " " ? "," : character)
                escaped = false
            } else {
                output.append(character)
                escaped = character == "\\"
            }
        }
        return output
    }
}
