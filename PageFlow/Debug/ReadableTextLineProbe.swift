#if DEBUG
import AppKit

/// A fixed literal source line, sampled only from existing visible native layout.
@MainActor
struct ReadableTextLineProbe {
    let range: NSRange
    let sourceUTF16: [UInt16]
    let windowY: CGFloat

    static func capture(in textView: NSTextView, minimumLocation: Int = 0) -> Self? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let start = layout.textViewportLayoutController.viewportRange?.location else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        var result: Self?
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.maxY <= visible.minY { return true }
            if frame.minY >= visible.maxY { return false }
            guard fragment.state == .layoutAvailable, let elementRange = fragment.textElement?.elementRange else { return true }
            let elementStart = content.offset(from: content.documentRange.location, to: elementRange.location)
            for line in fragment.textLineFragments where line.characterRange.location != NSNotFound {
                let offset = elementStart + line.characterRange.location
                if offset >= minimumLocation, let sample = sample(at: offset, in: textView) {
                    result = sample
                    return false
                }
            }
            return true
        }
        return result
    }

    /// The same offset, line range and literal UTF16 must still be readable and fully visible.
    func resample(in textView: NSTextView, offsetDelta: Int = 0) -> Self? {
        let mapped = NSRange(location: range.location + offsetDelta, length: range.length)
        guard mapped.location >= 0, let current = Self.sample(at: mapped.location, in: textView),
              current.range == mapped, current.sourceUTF16 == sourceUTF16 else { return nil }
        return current
    }

    private static func sample(at offset: Int, in textView: NSTextView) -> Self? {
        guard offset >= 0, let storage = textView.textStorage,
              let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset),
              let fragment = layout.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false),
              let elementRange = fragment.textElement?.elementRange,
              line.characterRange.location != NSNotFound else { return nil }
        let elementStart = content.offset(from: content.documentRange.location, to: elementRange.location)
        let range = NSRange(location: elementStart + line.characterRange.location, length: line.characterRange.length)
        guard elementStart >= 0, range.location >= 0, range.length > 0,
              range.location <= storage.length, range.length <= storage.length - range.location else { return nil }
        let origin = textView.textContainerOrigin
        let frame = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + origin.x,
                                                    dy: fragment.layoutFragmentFrame.minY + origin.y)
        let visible = textView.visibleRect
        guard [frame.minY, frame.maxY, visible.minY, visible.maxY].allSatisfy(\.isFinite),
              frame.height >= 1, visible.height > 0,
              frame.minY >= visible.minY, frame.maxY <= visible.maxY else { return nil }
        var hasRaster = false
        var hasReadableFont = false
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            if attributes[NSAttributedString.Key("RenderedBlockImage")] is NSImage { hasRaster = true }
            if let font = attributes[.font] as? NSFont, font.pointSize.isFinite, font.pointSize > 1 {
                hasReadableFont = true
            }
        }
        guard !hasRaster, hasReadableFont else { return nil }
        let windowY = textView.convert(NSPoint(x: frame.minX, y: frame.minY), to: nil).y
        guard windowY.isFinite else { return nil }
        return Self(range: range, sourceUTF16: Array((storage.string as NSString).substring(with: range).utf16), windowY: windowY)
    }
}
#endif
