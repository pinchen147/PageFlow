import AppKit

/// Presentation-only paragraph filtering. The text storage remains the source document.
final class MarkdownFoldLayout: NSObject, NSTextContentStorageDelegate {
    static let rowHeight: CGFloat = 28
    var hiddenRanges: [NSRange] = []
    var summaryHeadings: Set<Int> = []

    func hiddenRange(containing offset: Int) -> NSRange? {
        var low = 0, high = hiddenRanges.count
        while low < high {
            let middle = (low + high) / 2
            if hiddenRanges[middle].location <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0, offset < NSMaxRange(hiddenRanges[low - 1]) else { return nil }
        return hiddenRanges[low - 1]
    }

    func textContentManager(_ manager: NSTextContentManager, shouldEnumerate element: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        guard let range = element.elementRange else { return true }
        let offset = manager.offset(from: manager.documentRange.location, to: range.location)
        return hiddenRange(containing: offset) == nil
    }

    func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard summaryHeadings.contains(range.location), let source = storage.textStorage,
              range.length > 0, NSMaxRange(range) <= source.length else { return nil }
        let paragraph = NSMutableAttributedString(attributedString: source.attributedSubstring(from: range))
        let style = (paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacing += Self.rowHeight
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        return NSTextParagraph(attributedString: paragraph)
    }
}
