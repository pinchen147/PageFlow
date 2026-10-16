import Foundation

/// the reference editor's link URL rules (`Mh`, doc 24 §6.7): what the Link field
/// accepts and how it is normalised before it is written to Markdown.
enum MarkdownLinkURL {
    enum Failure: Error, Equatable {
        case notALink
        case tooLong
    }

    static let maximumBytes = 2048

    static func normalize(_ input: String) -> Result<String, Failure> {
        var text = input
        while let first = text.unicodeScalars.first, first.value <= 0x20 { text.unicodeScalars.removeFirst() }
        while let last = text.unicodeScalars.last, last.value <= 0x20 { text.unicodeScalars.removeLast() }
        text.removeAll { $0 == "\t" || $0 == "\r" || $0 == "\n" }
        text = text.replacingOccurrences(of: "\\", with: "/")
        guard !text.isEmpty else { return .failure(.notALink) }
        guard text.utf8.count <= maximumBytes else { return .failure(.tooLong) }
        let hasWhitespace = text.contains { $0.isWhitespace }
        let lower = text.lowercased()
        if text.hasPrefix("#") { return hasWhitespace ? .failure(.notALink) : .success(text) }
        if text.hasPrefix("//") { return .failure(.notALink) }
        if text.hasPrefix("/") { return .success(text.replacingOccurrences(of: " ", with: "%20")) }
        if lower.hasPrefix("tel:") { return .success(text.replacingOccurrences(of: " ", with: "")) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            guard !hasWhitespace, URL(string: text) != nil else { return extractSingleURL(from: text) }
            return .success(text)
        }
        if hasWhitespace { return extractSingleURL(from: text) }
        // Any other scheme is refused; `example.com:8080` is a host and port, not a scheme.
        if let colon = text.firstIndex(of: ":") {
            let scheme = text[..<colon]
            if !scheme.isEmpty, !scheme.contains("."), scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-".contains($0) }) {
                return .failure(.notALink)
            }
        }
        if lower.hasPrefix("go/") { return .success("http://" + text) }
        if isEmail(text) { return .success("mailto:" + text) }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return .failure(.notALink) }
        return .success("https://" + text)
    }

    /// A single http(s) or mailto URL inside free text.
    private static func extractSingleURL(from text: String) -> Result<String, Failure> {
        let candidates = text.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            let lower = $0.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
        }
        guard candidates.count == 1, URL(string: candidates[0]) != nil else { return .failure(.notALink) }
        return .success(candidates[0])
    }

    private static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix(".") else { return false }
        return !text.contains { $0.isWhitespace || $0 == "/" }
    }

    /// `[` and `]` in link text are escaped; an unbalanced `(` or `)` in the URL is percent-encoded.
    static func markdown(text: String, url: String) -> String {
        let escapedText = text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        var depth = 0
        var balanced = true
        for character in url {
            if character == "(" { depth += 1 } else if character == ")" { depth -= 1; if depth < 0 { balanced = false } }
        }
        if depth != 0 { balanced = false }
        let safeURL = balanced ? url : url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(escapedText)](\(safeURL))"
    }
}
