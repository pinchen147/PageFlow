import AppKit

/// Body and decoded cells share AppKit's word boundaries on canonical visible text.
/// The native adapters still own admission, source transactions and Undo.
enum MarkdownNativeWordFormatting {
    enum Resolution {
        case boundary
        /// A rejected source rewrite still consumes an interior command; it
        /// must not silently become a future-typing toggle.
        case word(MarkdownEmphasisEditPlan?)
    }

    static func resolve(style: MarkdownInlineStyle, sourceOffset: Int,
                     projection: MarkdownEmphasisProjection, navigator: NSTextView,
                     writingDirection: NSWritingDirection) -> Resolution {
        let visibleOffset = projection.visibleOffset(forSourceOffset: sourceOffset)
        navigator.string = projection.visibleText
        navigator.baseWritingDirection = writingDirection
        let word = navigator.selectionRange(
            forProposedRange: NSRange(location: visibleOffset, length: 0), granularity: .selectByWord)
        let visible = projection.visibleText as NSString
        guard word.location != NSNotFound, word.location < visibleOffset,
              visibleOffset < NSMaxRange(word), NSMaxRange(word) <= visible.length,
              MarkdownInlineFormatter.trimmedRange(word, in: visible) == word else { return .boundary }
        return .word(MarkdownEmphasisEditPlanner.formatting(style: style, visibleRange: word,
            caret: visibleOffset, projection: projection))
    }
}
