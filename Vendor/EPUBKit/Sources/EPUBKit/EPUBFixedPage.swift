import AppKit
import Foundation

/// A pre-paginated page in its own coordinate system (`size`, CSS pixels, y
/// down): what is painted, back to front, and where its text blocks sit. The
/// reader scales it to its page. `text` has the chapter's characters at the
/// chapter's offsets, so Find, highlights and the saved place need no mapping.
public struct EPUBFixedPage: @unchecked Sendable {
    /// A painted image or colour.
    public struct Layer: @unchecked Sendable {
        public let frame: CGRect
        /// Where a background image's overflow is cut off.
        let clip: CGRect?
        let imagePath: String?
        let color: NSColor?
        /// The image's one character in the chapter, for double-click zoom.
        public let slot: Int?
    }

    /// A run of the chapter's text, set at `frame.width` from `frame.origin`.
    public struct TextBlock: Equatable, Sendable {
        public let range: NSRange
        public let frame: CGRect
    }

    public let size: CGSize
    /// The page's paper: its own colour, else white, whatever the reader's theme.
    public let background: NSColor
    public let layers: [Layer]
    public let blocks: [TextBlock]
    /// The chapter's text in the publisher's fonts and colours.
    public let text: NSAttributedString
    let images: EPUBImageStore
    /// Text in the chapter the page hides, as the book's CSS asks.
    var hidden: [NSRange] = []

    /// The page, scaled to fit inside `available` and centred.
    public func frame(in available: CGSize) -> CGRect {
        let scale = min(available.width / size.width, available.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (available.width - fitted.width) / 2, y: (available.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Paints the paper and layers into `rect` of a flipped view.
    /// `pixelsPerPoint` is device pixels per page unit, which picks each
    /// image's decode size so it stays sharp at any zoom.
    @MainActor
    public func draw(in rect: CGRect, pixelsPerPoint: CGFloat) {
        background.setFill()
        rect.fill()
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / size.width)
        transform.concat()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).addClip()
        for layer in layers {
            if let color = layer.color {
                color.setFill()
                layer.frame.fill(using: .sourceOver)
            } else if let path = layer.imagePath {
                NSGraphicsContext.saveGraphicsState()
                if let clip = layer.clip { NSBezierPath(rect: clip).addClip() }
                draw(path, in: layer.frame, pixelsPerPoint: pixelsPerPoint)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    @MainActor
    private func draw(_ path: String, in frame: CGRect, pixelsPerPoint: CGFloat) {
        let longSide = Int((max(frame.width, frame.height) * pixelsPerPoint).rounded(.up))
        let image = EPUBImageCell.drawsThumbnails ? images.thumbnailImage(at: path)
            : images.pageImage(at: path, longSide: longSide)
        guard let image else {
            // Undecodable: a quiet frame where the image would be.
            NSColor.black.withAlphaComponent(0.15).setFill()
            frame.fill(using: .sourceOver)
            return
        }
        NSImage(cgImage: image, size: frame.size).draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// The first visible text outside every block, other than what the page
    /// holds apart: images (their one character) and text it was told to hide.
    /// Nil when the page shows all of it. A self-check for the corpus run.
    public func unplacedText(in chapter: NSString) -> String? {
        var cursor = 0
        for range in (blocks.map(\.range) + hidden).sorted(by: { $0.location < $1.location }) {
            if let lost = visible(in: NSRange(location: cursor, length: max(0, range.location - cursor)), of: chapter) { return lost }
            cursor = max(cursor, NSMaxRange(range))
        }
        return visible(in: NSRange(location: cursor, length: max(0, chapter.length - cursor)), of: chapter)
    }

    private func visible(in range: NSRange, of chapter: NSString) -> String? {
        guard range.length > 0, NSMaxRange(range) <= chapter.length else { return nil }
        let text = chapter.substring(with: range).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FFFC}")))
        return text.isEmpty ? nil : String(text.prefix(40))
    }

    /// Starts decoding the page's images, so it draws them at once.
    public func prefetch(pixelsPerPoint: CGFloat) {
        for layer in layers {
            guard let path = layer.imagePath else { continue }
            images.prefetchPageImage(at: path, longSide: longSide(of: layer, pixelsPerPoint: pixelsPerPoint))
        }
    }

    /// Decodes the page's images here and now, off the main thread, so it
    /// never decodes them while it draws.
    public func decodeImages(pixelsPerPoint: CGFloat) {
        for layer in layers {
            guard let path = layer.imagePath else { continue }
            _ = images.pageImage(at: path, longSide: longSide(of: layer, pixelsPerPoint: pixelsPerPoint))
        }
    }

    private func longSide(of layer: Layer, pixelsPerPoint: CGFloat) -> Int {
        Int((max(layer.frame.width, layer.frame.height) * pixelsPerPoint).rounded(.up))
    }
}
