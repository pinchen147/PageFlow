import Foundation

/// An immutable canonical heading, valid only for the editor revision that published it.
public struct MarkdownSectionTarget: Hashable, Sendable {
    /// The heading's zero-based document order, including duplicate and empty headings.
    public let rank: Int
    /// The canonical ATX heading level, from 1 through 6.
    public let level: Int
    /// A bounded plain-text heading label.
    public let title: String
    let editor: UUID
    let document: Int
    let source: Int
    let anchor: Int
}

/// Canonical targets and sections with content intersecting the native viewport.
public struct MarkdownSectionNavigationSnapshot: Equatable, Sendable {
    /// All canonical headings in source order.
    public let targets: [MarkdownSectionTarget]
    /// Ranks whose actual laid-out content is visible, excluding folded source.
    public let visibleRanks: Set<Int>
}

/// Bounded source text for a section's transient preview.
public struct MarkdownSectionPreview: Equatable, Sendable {
    /// The same bounded label carried by the target.
    public let title: String
    /// Plain text read from at most 2,048 UTF-16 source units after its heading.
    public let body: String
}
