//
//  NativeTextView+Accessibility.swift
//  MarkdownEngine
//
//  A rendered block (math, an image, a table, a diagram) draws over its
//  hidden source, so an assistive app reading the text would hear markup.
//  It hears a short label for the block instead (D13).
//

import AppKit

extension NativeTextView {
    override func accessibilityString(for range: NSRange) -> String? {
        guard let storage = textStorage, range.location != NSNotFound,
              NSMaxRange(range) <= storage.length,
              let tokens = (delegate as? NativeTextViewCoordinator)?.cachedParsedDocument?.tokens else {
            return super.accessibilityString(for: range)
        }
        let source = storage.mutableString
        var spoken = ""
        var cursor = range.location
        for token in tokens where NSIntersectionRange(token.range, range).length > 0 {
            guard let label = Self.accessibilityLabel(for: token, in: source),
                  isRendered(token.range, in: storage) else { continue }
            let block = NSIntersectionRange(token.range, range)
            if block.location > cursor {
                spoken += source.substring(with: NSRange(location: cursor, length: block.location - cursor))
            }
            spoken += label
            cursor = max(cursor, NSMaxRange(block))
        }
        if cursor < NSMaxRange(range) {
            spoken += source.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return spoken
    }

    /// A block draws as an image only while it is not revealed for editing.
    private func isRendered(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        var rendered = false
        storage.enumerateAttribute(.renderedBlockImage, in: range, options: []) { value, _, stop in
            if value != nil { rendered = true; stop.pointee = true }
        }
        return rendered
    }

    /// What a rendered block is called aloud; `nil` for text that renders as text.
    static func accessibilityLabel(for token: MarkdownToken, in source: NSString) -> String? {
        let text = source.substring(with: token.range)
        switch token.kind {
        case .inlineLatex, .blockLatex:
            let formula = text.trimmingCharacters(in: CharacterSet(charactersIn: "$").union(.whitespacesAndNewlines))
            return "math: \(formula)"
        case .imageLink:
            let alt = text.dropFirst(2).prefix { $0 != "]" }
            return alt.isEmpty ? "image" : "image: \(alt)"
        case .imageEmbed:
            let name = text.dropFirst(3).prefix { $0 != "]" && $0 != "|" }
            return "image: \(name)"
        case .table:
            let rows = text.split(whereSeparator: \.isNewline).count
            return "table, \(max(0, rows - 1)) rows"
        case .codeBlock:
            let language = MarkdownTokenizer.extractLanguage(from: token, in: source) ?? ""
            return language.isEmpty ? nil : "\(language) diagram"
        default:
            return nil
        }
    }
}
