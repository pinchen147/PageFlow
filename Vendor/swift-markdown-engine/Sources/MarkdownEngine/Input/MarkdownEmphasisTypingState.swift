import Foundation

struct MarkdownEmphasisTraits: OptionSet, Equatable, Sendable {
    let rawValue: Int
    static let bold = Self(rawValue: 1)
    static let italic = Self(rawValue: 2)
    static let underline = Self(rawValue: 4)
    static let highlight = Self(rawValue: 8)
    static let strikethrough = Self(rawValue: 16)

    init(style: MarkdownInlineStyle) {
        switch style {
        case .bold: self = .bold
        case .italic: self = .italic
        case .underline: self = .underline
        case .highlight: self = .highlight
        case .strikethrough: self = .strikethrough
        default: self = []
        }
    }

    init(rawValue: Int) { self.rawValue = rawValue }
    init(kind: MarkdownTokenKind) {
        switch kind {
        case .bold: self = .bold
        case .italic: self = .italic
        case .boldItalic: self = [.bold, .italic]
        case .underline: self = .underline
        case .highlight: self = .highlight
        case .strikethrough: self = .strikethrough
        default: self = []
        }
    }
}

/// Surface-local intent. A disabled bit deliberately differs from inheriting a style.
struct MarkdownEmphasisTypingState: Equatable {
    private(set) var enabled: MarkdownEmphasisTraits = []
    private(set) var disabled: MarkdownEmphasisTraits = []

    func effectiveTraits(inheriting traits: MarkdownEmphasisTraits) -> MarkdownEmphasisTraits {
        traits.union(enabled).subtracting(disabled)
    }

    mutating func toggle(_ trait: MarkdownEmphasisTraits, inheriting traits: MarkdownEmphasisTraits) {
        if effectiveTraits(inheriting: traits).contains(trait) {
            enabled.subtract(trait)
            disabled.formUnion(trait)
        } else {
            disabled.subtract(trait)
            enabled.formUnion(trait)
        }
    }

    /// Committed typing keeps its effective styles even when trailing whitespace
    /// must sit outside the source wrappers to remain valid CommonMark.
    mutating func retainTypingTraits(_ traits: MarkdownEmphasisTraits) {
        enabled = traits
        disabled = MarkdownEmphasisTraits([.bold, .italic, .underline, .highlight, .strikethrough]).subtracting(traits)
    }

    /// Real navigation clears pending overrides and adopts the destination's context.
    mutating func adopt() {
        enabled = []
        disabled = []
    }
}
