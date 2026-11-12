import Foundation

/// Committed Markdown and immutable-load provenance for byte-preserving host saves.
public struct SemanticMarkdownExportResult {
    public enum Piece: Equatable, Sendable {
        /// Offsets always address the document's immutable load-origin UTF-16.
        case original(NSRange)
        case generated(String)

        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.original(let a), .original(let b)): return a == b
            case (.generated(let a), .generated(let b)): return a.utf16.elementsEqual(b.utf16)
            default: return false
            }
        }
    }

    public let originSource: String
    public let source: String
    public let pieces: [Piece]
    /// Source coordinates describe this exported revision, not the immutable origin.
    let sourceMap: SemanticSourceMap
    let blockRanges: [UUID: NSRange]
    let cellRanges: [UUID: NSRange]
}
