//
//  HighlighterSwiftBridge.swift
//  MarkdownEngineCodeBlocks
//
//  Ready-made SyntaxHighlighter conformance backed by HighlighterSwift.
//
//  Every colour it hands out is DYNAMIC: a block is highlighted once with the
//  light theme and once with the dark theme, and each run carries an NSColor
//  that resolves against the appearance of the view drawing it. The editor
//  therefore never asks which mode it is in (the key window, the app and a
//  forced editor scheme all disagreed at times), and a mode flip repaints
//  without a restyle — the same way every other NSColor in the app behaves.
//

import AppKit
import Foundation
import Highlighter
import MarkdownEngine

/// Drop-in ``SyntaxHighlighter`` backed by HighlighterSwift.
///
/// Defaults match the Nodes app's look: opaque light/dark code-block
/// backgrounds and an `SF Mono → Menlo → system monospace` font chain.
public final class HighlighterSwiftBridge: SyntaxHighlighter, @unchecked Sendable {
    private let lightHighlighter: Highlighter?
    private let darkHighlighter: Highlighter?
    private let background: NSColor
    private let preferredFontNames: [String]

    /// HighlighterSwift's JavaScriptCore bridge is expensive — cache by (language, code).
    private let highlightCache = NSCache<NSString, NSAttributedString>()
    private let failedCache = NSCache<NSString, NSNumber>()
    private var unsupportedLanguages: Set<String> = []

    /// - Parameters:
    ///   - lightTheme: HighlighterSwift theme name resolved in light mode.
    ///   - darkTheme: HighlighterSwift theme name resolved in dark mode.
    ///   - lightBackground: Code-block background in light mode (`nil` = clear).
    ///   - darkBackground: Code-block background in dark mode (`nil` = clear).
    ///   - preferredFontNames: PostScript font names tried in order before
    ///     falling back to the system monospace font.
    public init(
        lightTheme: String = "atom-one-light",
        darkTheme: String = "atom-one-dark",
        lightBackground: NSColor? = NSColor(calibratedWhite: 0.95, alpha: 1.0),
        darkBackground: NSColor? = NSColor(calibratedWhite: 0.13, alpha: 1.0),
        preferredFontNames: [String] = ["SF Mono", "Menlo"]
    ) {
        self.lightHighlighter = Self.makeHighlighter(theme: lightTheme)
        self.darkHighlighter = Self.makeHighlighter(theme: darkTheme)
        self.background = Self.dynamic(light: lightBackground ?? .clear, dark: darkBackground ?? .clear)
        self.preferredFontNames = preferredFontNames
        highlightCache.countLimit = 256
        highlightCache.totalCostLimit = 2_000_000
        failedCache.countLimit = 256
        failedCache.totalCostLimit = 2_000_000
    }

    /// Drops the internal highlight cache.
    public func clearCache() {
        highlightCache.removeAllObjects()
        failedCache.removeAllObjects()
    }

    // MARK: - SyntaxHighlighter

    /// Nothing to re-render on a mode flip: every colour resolves at draw time.
    public var appearanceDidChangeNotification: Notification.Name? { nil }

    public func codeFont(size: CGFloat) -> NSFont {
        for name in preferredFontNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor { background }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        guard let lightHighlighter else { return nil }
        // Colours only for a language the fence names and highlight.js knows.
        // Never auto-detect: it runs every grammar over the block (tens of
        // milliseconds per keystroke while the caret is inside) and paints an
        // unlabeled or `mermaid` block in a random language's colours.
        guard let language = language?.lowercased().trimmingCharacters(in: .whitespaces),
              !language.isEmpty, !unsupportedLanguages.contains(language) else { return nil }
        // NSString compares literal source units; Swift String hashing treats
        // canonically equivalent spellings as equal even when their ranges differ.
        let cacheKey = (language + "\u{0}" + code) as NSString

        if let cached = highlightCache.object(forKey: cacheKey) { return cached }
        if failedCache.object(forKey: cacheKey) != nil { return nil }

        guard let light = lightHighlighter.highlight(code, as: language) else {
            // Unknown to highlight.js: plain code styling from now on, no retry.
            unsupportedLanguages.insert(language)
            failedCache.setObject(NSNumber(value: true), forKey: cacheKey, cost: code.utf16.count)
            return nil
        }
        let dark = darkHighlighter?.highlight(code, as: language) ?? light
        let result = Self.dynamicColours(light: light, dark: dark)
        highlightCache.setObject(result, forKey: cacheKey, cost: code.utf16.count)
        return result
    }

    // MARK: - Dynamic colours

    /// The light rendering with every foreground colour replaced by one that
    /// resolves to the dark rendering's colour at the same place under a dark
    /// appearance. Both renderings tokenize identically (same grammar; the
    /// theme only maps token classes to colours), so sampling the dark colour
    /// at each light run's start is exact.
    private static func dynamicColours(light: NSAttributedString, dark: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: light)
        let full = NSRange(location: 0, length: light.length)
        light.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let lightColour = value as? NSColor else { return }
            let darkColour = range.location < dark.length
                ? (dark.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor) ?? lightColour
                : lightColour
            result.addAttribute(.foregroundColor, value: dynamic(light: lightColour, dark: darkColour), range: range)
        }
        return result
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func makeHighlighter(theme: String) -> Highlighter? {
        guard let highlighter = Highlighter() else { return nil }
        _ = highlighter.setTheme(theme)
        return highlighter
    }
}
