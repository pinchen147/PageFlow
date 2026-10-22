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
    /// NSTextView owns its AX children, so append the selected image's handles explicitly.
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let coordinator = delegate as? NativeTextViewCoordinator else { return children }
        children.append(contentsOf: coordinator.foldControls?.accessibilityControls ?? [])
        guard let controls = coordinator.imageControls else { return children }
        let group = controls.resizeAccessibilityGroup
        children.removeAll { ($0 as AnyObject) === group }
        if isEditable, coordinator.objectSelection != nil, !controls.isInteracting,
           !group.isHiddenOrHasHiddenAncestor {
            children.append(group)
        }
        return children
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let storage = textStorage, range.location != NSNotFound,
              NSMaxRange(range) <= storage.length,
              let coordinator = delegate as? NativeTextViewCoordinator else {
            return super.accessibilityString(for: range)
        }
        let source = storage.mutableString
        var replacements: [(range: NSRange, label: String)] = []
        let counts = Dictionary(uniqueKeysWithValues: coordinator.foldSession.index.regions.map { ($0.body, $0.hiddenBlockCount) })
        for hidden in coordinator.foldLayout.hiddenRanges where NSIntersectionRange(hidden, range).length > 0 {
            let count = counts[hidden] ?? 1
            replacements.append((NSIntersectionRange(hidden, range), "\(count) \(count == 1 ? "block" : "blocks") hidden\n"))
        }
        for token in coordinator.cachedParsedDocument?.tokens ?? [] where NSIntersectionRange(token.range, range).length > 0 {
            guard coordinator.foldLayout.hiddenRange(containing: token.range.location) == nil,
                  let label = Self.accessibilityLabel(for: token, in: source),
                  isRendered(token.range, in: storage) else { continue }
            replacements.append((NSIntersectionRange(token.range, range), label))
        }
        replacements.sort { $0.range.location < $1.range.location }
        var spoken = ""
        var cursor = range.location
        for replacement in replacements {
            let block = replacement.range
            guard NSMaxRange(block) > cursor else { continue }
            if block.location > cursor {
                spoken += source.substring(with: NSRange(location: cursor, length: block.location - cursor))
            }
            spoken += replacement.label
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
        case .imageLink, .imageEmbed:
            let description = imageDescription(for: token, in: source)
            return description.isEmpty ? "image" : "image: \(description)"
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

    /// An image's description: the alt text without its `|300|center` tokens,
    /// escapes decoded, or an embed's file name.
    static func imageDescription(for token: MarkdownToken, in source: NSString) -> String {
        if token.kind == .imageEmbed {
            return ImageEmbedReference(content: source.substring(with: token.contentRange))?.name
                ?? String(source.substring(with: token.range).dropFirst(3).prefix { $0 != "]" && $0 != "|" })
        }
        return ImageAltTokens.parse(source.substring(with: token.contentRange)).displayDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An image selected as a whole reads as its description, not its Markdown (doc 26 §11.4).
    override func accessibilitySelectedText() -> String? {
        if let coordinator = delegate as? NativeTextViewCoordinator, let image = coordinator.objectSelection,
           selectedRange() == image.token {
            return coordinator.imageDescription(image) ?? ""
        }
        return super.accessibilitySelectedText()
    }
}
