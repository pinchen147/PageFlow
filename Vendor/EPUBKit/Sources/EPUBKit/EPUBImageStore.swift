import AppKit
import CryptoKit
import Foundation
import os
import ImageIO
import UniformTypeIdentifiers

/// Decodes a book's images ahead of display, two at a time in the background,
/// into a cost-bounded cache that evicts under pressure. A page drawn before
/// its prefetch finished waits for that one decode, or decodes the image
/// itself; it never waits behind other queued prefetches. Rail thumbnails
/// use small decodes of their own, so they never evict the reader's images.
final class EPUBImageStore: @unchecked Sendable {
    /// Display-resolution decode: 720 pt at 2x.
    private static let maxPixelSize = 1_440
    private static let thumbnailPixelSize = 320
    /// The decode sizes fixed pages use: page turns and zoom reuse them.
    private static let pageSizes = [maxPixelSize, 2_880, 5_760, 8_192]
    private let cache = NSCache<NSString, CGImage>()
    private let thumbnailCache = NSCache<NSString, CGImage>()
    private let prefetchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "EPUBKit.images"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let lock = NSLock()
    /// Held while the book's file is read: a big photo takes long enough that
    /// `lock`, which the main thread takes to queue a decode, can't wait for it.
    let archiveLock = NSLock()
    // Guarded by `archiveLock`.
    private var reader: ArchiveReader?
    // Guarded by `lock`.
    private var source: URL
    /// The clone read in place of `source`, when one could be made.
    private var snapshot: EPUBFileSnapshot?
    /// Paths that failed to decode; never retried for this book.
    private var failed: Set<String> = []
    private var decoding: [String: Decode] = [:]
    /// Inline `<svg>` documents, by the key their chapter gave them.
    private var inlineDocuments: [String: Data] = [:]

    /// One decode of one path; whoever starts it first does the work.
    private final class Decode {
        let done = DispatchGroup()
        var isStarted = false
        init() { done.enter() }
    }

    init(sourceURL: URL) {
        source = sourceURL
        snapshot = EPUBFileSnapshot.acquire(of: sourceURL)
        cache.totalCostLimit = 192 * 1024 * 1024
        thumbnailCache.totalCostLimit = 32 * 1024 * 1024
    }

    /// The file the book's chapters and images are read from: its clone, or,
    /// with none or with the clone gone (the system may purge caches), the file.
    var sourceURL: URL { lock.withLock { readableSource } }

    private var readableSource: URL {
        if let clone = snapshot?.url, FileManager.default.fileExists(atPath: clone.path) { return clone }
        return source
    }

    var hasSnapshot: Bool { lock.withLock { snapshot != nil } }

    /// The book is closed: the clone goes now rather than with the last chapter
    /// holding on to this store. Anything still reading falls back on the file.
    func closeSnapshot() {
        let closing = lock.withLock {
            defer { snapshot = nil }
            return snapshot
        }
        closeReader()
        closing?.release()
    }

    private func closeReader() {
        archiveLock.withLock { reader = nil }
    }

    /// The book's file is now `url`, a copy of the same bytes (Save As): what
    /// was read stays good, and everything from now on reads from there.
    func relocate(to url: URL) {
        let new = EPUBFileSnapshot.acquire(of: url)
        let old = lock.withLock {
            defer {
                snapshot = new
                source = url
            }
            return snapshot
        }
        closeReader()
        old?.release()
    }

    /// Drops every decoded image; they decode again when next asked for.
    func removeDecodedImages() {
        cache.removeAllObjects()
        thumbnailCache.removeAllObjects()
    }

    /// Keeps an inline `<svg>` so it decodes like an archive image at `key`.
    func registerInline(_ data: Data, key: String) {
        lock.withLock { inlineDocuments[key] = data }
    }

    /// Whether the display image is in memory now.
    func hasDecodedImage(at path: String) -> Bool { cache.object(forKey: path as NSString) != nil }

    /// Queues a background decode, unless the image is cached or under way.
    func prefetchImage(at path: String) {
        guard cache.object(forKey: path as NSString) == nil else { return }
        let decode: Decode? = lock.withLock {
            guard decoding[path] == nil, !failed.contains(path) else { return nil }
            let decode = Decode()
            decoding[path] = decode
            return decode
        }
        guard let decode else { return }
        prefetchQueue.addOperation { [self] in
            let claimed = lock.withLock {
                guard !decode.isStarted else { return false }
                decode.isStarted = true
                return true
            }
            if claimed { finish(decode, of: path) }
        }
    }

    /// The display image, decoding it now when no prefetch got there first.
    func image(at path: String) -> CGImage? {
        if let image = cache.object(forKey: path as NSString) { return image }
        enum Plan { case unavailable, wait(Decode), decode(Decode) }
        let plan: Plan = lock.withLock {
            if failed.contains(path) { return .unavailable }
            if let decode = decoding[path] {
                if decode.isStarted { return .wait(decode) }
                // Queued but not started: take it over rather than wait behind the queue.
                decode.isStarted = true
                return .decode(decode)
            }
            let decode = Decode()
            decode.isStarted = true
            decoding[path] = decode
            return .decode(decode)
        }
        switch plan {
        case .unavailable:
            return nil
        case .wait(let decode):
            decode.done.wait()
            return cache.object(forKey: path as NSString)
        case .decode(let decode):
            return finish(decode, of: path)
        }
    }

    /// A small decode for rail thumbnails, kept apart from the display cache.
    func thumbnailImage(at path: String) -> CGImage? {
        if let image = thumbnailCache.object(forKey: path as NSString) { return image }
        guard !lock.withLock({ failed.contains(path) }), let data = data(at: path),
              let image = Self.decode(data, maxPixelSize: Self.thumbnailPixelSize) else { return nil }
        thumbnailCache.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    /// A fixed page's image, decoded for the pixels it covers: display
    /// resolution when that serves, else the next size up, cached like the rest
    /// and, for a raster, never past its own pixels (and the 40 MP ceiling
    /// it was admitted under). A drawing renders at any size.
    func pageImage(at path: String, longSide: Int) -> CGImage? {
        let tier = Self.pageSizes.first { $0 >= longSide } ?? Self.pageSizes.last ?? longSide
        guard tier > Self.maxPixelSize || Self.isVector(path) else { return image(at: path) }
        let key = "\(path)@\(tier)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard !lock.withLock({ failed.contains(path) }), let data = data(at: path) else { return nil }
        guard let image = Self.decode(data, maxPixelSize: tier, fillsSize: true) else {
            // A corrupt file isn't decoded again on every draw.
            lock.withLock { _ = failed.insert(path) }
            return nil
        }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Queues ``pageImage(at:longSide:)`` in the background.
    func prefetchPageImage(at path: String, longSide: Int) {
        let tier = Self.pageSizes.first { $0 >= longSide } ?? Self.pageSizes.last ?? longSide
        guard tier > Self.maxPixelSize || Self.isVector(path) else {
            prefetchImage(at: path)
            return
        }
        guard cache.object(forKey: "\(path)@\(tier)" as NSString) == nil else { return }
        prefetchQueue.addOperation { [self] in _ = pageImage(at: path, longSide: longSide) }
    }

    private static func isVector(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".svg") || path.contains("#svg-")
    }

    /// A large decode for the zoom panel, never cached: up to `maxPixelSize`
    /// on the long side, within the 40 MP ceiling.
    func zoomImage(at path: String, maxPixelSize: Int) -> CGImage? {
        guard !lock.withLock({ failed.contains(path) }), let data = data(at: path) else { return nil }
        return Self.decode(data, maxPixelSize: maxPixelSize)
    }

    @discardableResult
    private func finish(_ decode: Decode, of path: String) -> CGImage? {
        let image = data(at: path).flatMap { Self.decode($0, maxPixelSize: Self.maxPixelSize) }
        if let image {
            cache.setObject(image, forKey: path as NSString, cost: image.bytesPerRow * image.height)
        }
        lock.withLock {
            decoding[path] = nil
            if image == nil { failed.insert(path) }
        }
        decode.done.leave()
        return image
    }

    /// The archive is read under its own lock; decoding happens outside it.
    private func data(at path: String) -> Data? {
        if let inline = lock.withLock({ inlineDocuments[path] }) { return inline }
        return archiveLock.withLock {
            if reader == nil {
                // Re-decoding after eviction re-reads entries, so the cumulative
                // expansion cap doesn't apply here; each entry keeps its own limit.
                reader = try? ArchiveReader(url: sourceURL, expandedLimit: .max)
            }
            guard let data = try? reader?.read(path, limit: 32 * 1024 * 1024) else { return nil }
            guard EPUBSVG.isSVG(data) else { return data }
            return EPUBSVG.embeddingRasters(in: data, directory: (path as NSString).deletingLastPathComponent) {
                try? self.reader?.read($0, limit: EPUBSVG.byteLimit)
            }
        }
    }

    private static func decode(_ data: Data, maxPixelSize: Int, fillsSize: Bool = false) -> CGImage? {
        if EPUBSVG.isSVG(data) { return EPUBSVG.rasterize(data, maxPixelSize: maxPixelSize, fillsSize: fillsSize) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// Fixed attachments can be measured by a chapter's background TextKit stack.
/// Match the native zero-baseline cell using only its size and the line geometry.
class EPUBFixedAttachmentCell: NSTextAttachmentCell {
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let size = cellSize()
        let vertical = textContainer.layoutOrientation == .vertical
        var width = vertical ? size.height : size.width
        let height = vertical ? size.width : size.height
        let available = lineFrag.width - 2 * textContainer.lineFragmentPadding
        if lineFrag.width > 0 {
            width = min(width, available > 0 ? available : lineFrag.width)
        }
        return NSRect(x: 0, y: vertical ? floor(-size.width / 2) : 0,
                      width: max(1, floor(width)), height: max(1, floor(height)))
    }
}

/// A TextKit 1 attachment cell of fixed size that draws its book image.
final class EPUBImageCell: EPUBFixedAttachmentCell {
    /// Set while rail thumbnails draw (``EPUBImageRendering/thumbnails(_:)``).
    @MainActor static var drawsThumbnails = false
    private let store: EPUBImageStore
    private let path: String
    private let size: NSSize
    /// Set when the image follows the size of the text it sits in.
    private let textSizing: TextSizing?
    /// How large text-sized images can grow: the most a page holds.
    private let pageBounds: CGSize

    /// How an image in running text takes its size from that text.
    enum TextSizing {
        /// A letter drawn as an image: as tall as the font's line box, sitting in it.
        case line
        /// So many ems tall, on the baseline.
        case ems(CGFloat)
    }

    /// `size` is the size at the text's size when rendered, its shape always.
    @MainActor init(store: EPUBImageStore, path: String, size: NSSize, textSizing: TextSizing? = nil,
         pageBounds: CGSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)) {
        self.store = store
        self.path = path
        self.size = size
        self.textSizing = textSizing
        self.pageBounds = pageBounds
        super.init(imageCell: nil)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { size }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let textSizing, size.height > 0, let storage = textContainer.layoutManager?.textStorage,
              charIndex < storage.length,
              let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont else {
            return super.cellFrame(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position,
                                   characterIndex: charIndex)
        }
        var height: CGFloat
        var bottom: CGFloat
        switch textSizing {
        case .line:
            height = font.ascender - font.descender
            bottom = font.descender
        case .ems(let ems):
            height = ems * font.pointSize
            bottom = 0
        }
        var width = height * size.width / size.height
        let pageFit = min(1, pageBounds.width / width, pageBounds.height / height)
        width *= pageFit
        height *= pageFit
        bottom *= pageFit
        if textContainer.layoutOrientation == .vertical {
            // Upright: as tall along the line as the image is, as wide across.
            return NSRect(x: 0, y: -width / 2, width: height, height: width)
        }
        if lineFrag.width > 1, width > lineFrag.width {
            let fit = lineFrag.width / width
            width *= fit
            height *= fit
            bottom *= fit
        }
        return NSRect(x: 0, y: bottom, width: width, height: height)
    }

    func prefetch() { store.prefetchImage(at: path) }

    /// The image at display resolution; nil when it can't be decoded.
    var displayImage: CGImage? { store.image(at: path) }

    var isDecoded: Bool { store.hasDecodedImage(at: path) }

    /// The image decoded large for zooming into.
    func zoomImage(maxPixelSize: Int) -> CGImage? { store.zoomImage(at: path, maxPixelSize: maxPixelSize) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let color = layoutManager.pageTextColor(at: charIndex)
        guard layoutManager.isLaidOutVertically else { return draw(cellFrame, textColor: color) }
        drawUpright(in: cellFrame) { draw($0, textColor: color) }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, textColor: nil)
    }

    private func draw(_ cellFrame: NSRect, textColor: NSColor?) {
        let image = Self.drawsThumbnails ? store.thumbnailImage(at: path) : displayImage
        guard let image else {
            // Undecodable: a quiet frame where the image would be, in the
            // page's own text colour so it suits every theme.
            (textColor?.withAlphaComponent(0.15) ?? .quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: cellFrame, xRadius: 4, yRadius: 4).fill()
            return
        }
        NSImage(cgImage: image, size: size).draw(
            in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }
}

/// A missing or refused image: its alt text in a one-character slot, so
/// offsets stay identical to the search render. Drawn in the page's text
/// colour, dimmed, so it follows the reader's theme.
final class EPUBAltTextCell: EPUBFixedAttachmentCell {
    let label: String
    private let size: NSSize
    private static let font = NSFont.systemFont(ofSize: 13)

    @MainActor init(label: String) {
        self.label = label
        let measured = (label as NSString).size(withAttributes: [.font: Self.font])
        size = NSSize(width: ceil(measured.width), height: ceil(measured.height))
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func cellSize() -> NSSize { size }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        let color = layoutManager.pageTextColor(at: charIndex)
        guard layoutManager.isLaidOutVertically else { return draw(cellFrame, textColor: color) }
        drawUpright(in: cellFrame) { draw($0, textColor: color) }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, textColor: nil)
    }

    private func draw(_ cellFrame: NSRect, textColor: NSColor?) {
        (label as NSString).draw(in: cellFrame, withAttributes: [
            .font: Self.font,
            .foregroundColor: textColor?.withAlphaComponent(0.55) ?? NSColor.secondaryLabelColor
        ])
    }
}

extension NSLayoutManager {
    /// The themed text colour the reader gave this attachment's character.
    func pageTextColor(at index: Int) -> NSColor? {
        guard let storage = textStorage, index < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }
}

/// How the app prepares and draws a chapter's book images.
public enum EPUBImageRendering {
    /// Runs `body` with book images drawn from small thumbnail decodes.
    @MainActor
    public static func thumbnails<T>(_ body: () throws -> T) rethrows -> T {
        EPUBImageCell.drawsThumbnails = true
        defer { EPUBImageCell.drawsThumbnails = false }
        return try body()
    }
}

public extension NSAttributedString {
    /// Starts decoding the book images in `range`, so its page draws them at once.
    @MainActor
    func prefetchEPUBImages(in range: NSRange) {
        guard NSMaxRange(range) <= length else { return }
        enumerateAttribute(.attachment, in: range) { value, _, _ in
            ((value as? NSTextAttachment)?.attachmentCell as? EPUBImageCell)?.prefetch()
        }
    }

    /// Decodes the book images in `range` here and now, off the main thread,
    /// so a page that lands afterwards never decodes them while it draws.
    func decodeEPUBImages(in range: NSRange) {
        guard NSMaxRange(range) <= length else { return }
        enumerateAttribute(.attachment, in: range) { value, _, _ in
            _ = ((value as? NSTextAttachment)?.attachmentCell as? EPUBImageCell)?.displayImage
        }
    }
}

/// SVG, which ImageIO can't read, drawn through NSImage instead.
enum EPUBSVG {
    /// Larger SVG documents are refused rather than parsed.
    static let byteLimit = 8 * 1024 * 1024

    static func isSVG(_ data: Data) -> Bool {
        guard data.count <= byteLimit else { return false }
        let head = String(decoding: data.prefix(4_096), as: UTF8.self)
        return head.contains("<svg")
    }

    /// The document's size in points, from its width and height or viewBox.
    static func size(of data: Data) -> NSSize? {
        guard isSVG(data), let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return nil }
        return size
    }

    /// The document with each `<image>` that points into the book embedded
    /// as a data URI, so the document carries its rasters to `rasterize`
    /// (the system's SVG renderer can't resolve archive paths).
    static func embeddingRasters(in data: Data, directory: String, read: (String) -> Data?) -> Data {
        let document = String(decoding: data, as: UTF8.self)
        guard document.contains("image"), let pattern = try? NSRegularExpression(
            pattern: #"(<(?:[A-Za-z_][\w.-]*:)?image\b[^>]*?\s(?:xlink:)?href\s*=\s*)(["'])([^"']*)\2"#)
        else { return data }
        let source = document as NSString
        var result = ""
        var cursor = 0
        var size = data.count
        for match in pattern.matches(in: document, range: NSRange(location: 0, length: source.length)) {
            let href = source.substring(with: match.range(at: 3))
            guard URL(string: href)?.scheme == nil,
                  let path = ArchivePath.normalized(href.removingFragment, relativeTo: directory),
                  let raster = read(path), let mime = mimeType(of: raster) else { continue }
            let encoded = raster.base64EncodedString()
            guard size + encoded.utf8.count <= byteLimit else { continue }
            size += encoded.utf8.count
            result += source.substring(with: NSRange(location: cursor, length: match.range(at: 3).location - cursor))
            result += "data:\(mime);base64,\(encoded)"
            cursor = NSMaxRange(match.range(at: 3))
        }
        guard cursor > 0 else { return data }
        result += source.substring(from: cursor)
        return Data(result.utf8)
    }

    private static func withoutImages(_ data: Data) -> Data {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<((?:[A-Za-z_][\w.-]*:)?image)\b[^>]*?(?:/>|>.*?</\1\s*>)"#, options: .dotMatchesLineSeparators)
        else { return data }
        let document = String(decoding: data, as: UTF8.self)
        return Data(pattern.stringByReplacingMatches(in: document, range: NSRange(location: 0, length: (document as NSString).length),
                                                     withTemplate: "").utf8)
    }

    /// Each embedded raster and its box in the document's points, y down.
    /// Empty when any can't be placed here (a transform on it or its groups),
    /// leaving them all to the system renderer. Nil when one is over the image
    /// size ceiling, so the drawing is refused.
    static func embeddedRasters(in data: Data, size: NSSize) -> [(image: CGImage, rect: CGRect)]? {
        guard data.range(of: Data(";base64,".utf8)) != nil,
              let document = try? XMLDocumentParser.parse(data), let root = document.root else { return [] }
        func number(_ node: XMLNode, _ name: String) -> CGFloat? {
            node.attribute(named: name).flatMap { Double($0.trimmingCharacters(in: .letters.union(.whitespaces))) }
                .map { CGFloat($0) }
        }
        // The viewBox maps user units to points: scaled to fit, centred.
        var scale: CGFloat = 1
        var offset = CGPoint.zero
        let box = (root.attribute(named: "viewBox") ?? "").split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Double($0) }.map { CGFloat($0) }
        if box.count == 4, box[2] > 0, box[3] > 0 {
            scale = min(size.width / box[2], size.height / box[3])
            offset = CGPoint(x: (size.width - box[2] * scale) / 2 - box[0] * scale,
                             y: (size.height - box[3] * scale) / 2 - box[1] * scale)
        }
        var placed: [(CGImage, CGRect)] = []
        for node in root.descendants(named: "image") {
            var ancestor = node.parent
            var transformed = node.attribute(named: "transform") != nil
            while let group = ancestor, group !== root {
                if group.attribute(named: "transform") != nil || group.localName == "svg" { transformed = true }
                ancestor = group.parent
            }
            guard let href = node.attribute(named: "href"), href.hasPrefix("data:"),
                  let comma = href.firstIndex(of: ","),
                  let bytes = Data(base64Encoded: String(href[href.index(after: comma)...])) else { return [] }
            guard XHTMLRenderer.acceptedPixelSize(bytes) != nil else { return nil }
            guard !transformed, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            let width = number(node, "width") ?? CGFloat(image.width)
            let height = number(node, "height") ?? CGFloat(image.height)
            let rect = CGRect(x: offset.x + (number(node, "x") ?? 0) * scale, y: offset.y + (number(node, "y") ?? 0) * scale,
                              width: width * scale, height: height * scale)
            placed.append((image, rect))
        }
        return placed
    }

    private static func mimeType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        return UTType(type)?.preferredMIMEType
    }

    /// Draws the document at up to twice its size, its longer side capped
    /// at `maxPixelSize`; with `fillsSize`, at `maxPixelSize` whatever its
    /// size. Safe off the main thread.
    static func rasterize(_ data: Data, maxPixelSize: Int, fillsSize: Bool = false) -> CGImage? {
        guard let size = size(of: data) else { return nil }
        // The system renderer misdraws <image>: the rasters are drawn here
        // instead, under the shapes, and left out of what it draws.
        guard let rasters = embeddedRasters(in: data, size: size) else { return nil }
        guard let image = NSImage(data: rasters.isEmpty ? data : withoutImages(data)) else { return nil }
        let fitted = CGFloat(maxPixelSize) / max(size.width, size.height)
        // The same ceiling as a raster, however far a drawing is zoomed (a
        // hair under, as sides round to whole pixels).
        let ceiling = (39_900_000 / max(1, size.width * size.height)).squareRoot()
        let scale = min(ceiling, fillsSize ? fitted : min(2, fitted))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if !rasters.isEmpty {
            context.saveGState()
            context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
            for raster in rasters {
                context.draw(raster.image, in: CGRect(x: raster.rect.minX, y: size.height - raster.rect.maxY,
                                                      width: raster.rect.width, height: raster.rect.height))
            }
            context.restoreGState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// A copy-on-write clone of a book's file, read in its place so that moving or
/// deleting the file doesn't cost an open book its unread chapters. It takes no
/// room while the file stays as it was; once the file is gone it holds the book
/// until closed. One per version of a file, however many times it is open, and
/// gone with its last user, at quit, or at the next launch after a crash.
///
/// Cloning fails on another volume than the caches', and may on a file not yet
/// downloaded or one the sandbox won't read. That is logged, nothing is left
/// behind, and the book reads the file itself: it then can't survive a move.
final class EPUBFileSnapshot: @unchecked Sendable {
    let url: URL
    private let keeper: EPUBSnapshotKeeper
    private var isReleased = false

    private static let lock = NSLock()
    private static let log = Logger(subsystem: "com.raccoontechnologies.PageFlow", category: "EPUBFileSnapshot")

    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("EPUBBookSnapshots", isDirectory: true)

    private init(url: URL, keeper: EPUBSnapshotKeeper) {
        self.url = url
        self.keeper = keeper
    }

    /// The clone of this version of a file, made if need be; nil if it can't be.
    /// Every book clones through `keeper`'s default: a test passes one of its own
    /// to see only what it made.
    static func acquire(of file: URL, keptBy keeper: EPUBSnapshotKeeper = .shared) -> EPUBFileSnapshot? {
        guard let name = name(of: file) else {
            log.notice("No snapshot of a book: its file can't be read")
            return nil
        }
        return lock.withLock {
            guard let folder = keeper.folder() else {
                log.error("No snapshot of a book: no folder of its own")
                return nil
            }
            let clone = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: clone.path), !makeClone(of: file, at: clone) {
                return nil
            }
            keeper.users[name, default: 0] += 1
            return EPUBFileSnapshot(url: clone, keeper: keeper)
        }
    }

    /// Named for what the file is now: a later version is another clone.
    private static func name(of file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let parts = "\(file.standardizedFileURL.path)|\(number)|\(size)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
        return digest + ".epub"
    }

    /// All or nothing: a clone only ever appears under its final name whole.
    private static func makeClone(of file: URL, at clone: URL) -> Bool {
        let partial = clone.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).partial")
        let status = file.withUnsafeFileSystemRepresentation { source in
            partial.withUnsafeFileSystemRepresentation { destination -> Int32 in
                guard let source, let destination else { return EINVAL }
                return clonefile(source, destination, 0) == 0 ? 0 : errno
            }
        }
        guard status == 0 else {
            log.notice("No snapshot of a book, reading its file itself: errno \(status, privacy: .public)")
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        do {
            try FileManager.default.moveItem(at: partial, to: clone)
            return true
        } catch {
            log.error("No snapshot of a book: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: partial)
            return false
        }
    }

    /// This book is done with it; the last one out deletes it.
    func release() {
        Self.lock.withLock {
            guard !isReleased else { return }
            isReleased = true
            let name = url.lastPathComponent
            keeper.users[name, default: 1] -= 1
            guard keeper.users[name] == 0 else { return }
            keeper.users[name] = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit { release() }

    /// What a quit or crash left: at launch, before any book opens.
    static func removeLeftovers(of keeper: EPUBSnapshotKeeper = .shared) {
        lock.withLock { keeper.removeLeftovers() }
    }

    /// As the app quits: this copy's clones, and whatever else nobody runs.
    static func removeOwnAndLeftovers(of keeper: EPUBSnapshotKeeper = .shared) {
        lock.withLock { keeper.removeOwnAndLeftovers() }
    }
}

/// One running copy of the app's clones, in a folder of its own beside a lock file
/// it holds for as long as it runs. Two copies of the app share the caches folder,
/// and neither knows what the other is reading: a sweep that took every clone it
/// wasn't using cost the other copy's books their protection against a move. The
/// system lets a lock go when its process ends, however it ends, so a lock nobody
/// holds is what a quit or crash left, and process IDs, which get reused, don't come
/// into it. Everything here runs under `EPUBFileSnapshot`'s lock.
final class EPUBSnapshotKeeper: @unchecked Sendable {
    static let shared = EPUBSnapshotKeeper(root: EPUBFileSnapshot.directory)
    private static let lockExtension = "lock"

    private let root: URL
    /// How many open books read each clone, by file name.
    fileprivate var users: [String: Int] = [:]
    /// This copy's folder and the held lock that says it is running.
    private var held: (folder: URL, lockFile: URL, descriptor: Int32)?

    init(root: URL) {
        self.root = root
    }

    deinit {
        if let held { close(held.descriptor) }
    }

    /// This copy's folder, made the first time it's needed and again if the system purged
    /// it with the caches. The lock comes first, taken in the same call that creates it,
    /// so another copy never sees the folder without one.
    fileprivate func folder() -> URL? {
        if let held {
            if FileManager.default.fileExists(atPath: held.folder.path),
               FileManager.default.fileExists(atPath: held.lockFile.path) { return held.folder }
            // Half gone, another copy would take the rest: start over.
            try? FileManager.default.removeItem(at: held.folder)
            try? FileManager.default.removeItem(at: held.lockFile)
            close(held.descriptor)
            self.held = nil
        }
        let name = UUID().uuidString
        let lockFile = root.appendingPathComponent(name).appendingPathExtension(Self.lockExtension)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)) != nil else { return nil }
        let descriptor = open(lockFile.path, O_CREAT | O_EXCL | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            close(descriptor)
            try? FileManager.default.removeItem(at: lockFile)
            return nil
        }
        held = (folder, lockFile, descriptor)
        return folder
    }

    /// The folders no running copy holds, and anything no lock speaks for: clones
    /// from before each copy had its own folder.
    fileprivate func removeLeftovers() {
        sweep(listing: (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    func sweep(listing names: [String]) {
        let fileManager = FileManager.default
        let own = held?.folder.lastPathComponent
        for name in names where (name as NSString).pathExtension == Self.lockExtension {
            let folderName = (name as NSString).deletingPathExtension
            guard folderName != own else { continue }
            let path = root.appendingPathComponent(name).path
            let descriptor = open(path, O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
            // Held: a running copy's. Any other failure: leave it for a later sweep.
            guard descriptor >= 0 else { continue }
            try? fileManager.removeItem(at: root.appendingPathComponent(folderName, isDirectory: true))
            try? fileManager.removeItem(atPath: path)
            close(descriptor)
        }
        // A listing isn't atomic: it can show a launching copy's folder and not its older
        // lock, so the lock is looked for on its own.
        for name in names where (name as NSString).pathExtension != Self.lockExtension && name != own
            && !fileManager.fileExists(atPath: root.appendingPathComponent(name + "." + Self.lockExtension).path) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    fileprivate func removeOwnAndLeftovers() {
        if let held {
            try? FileManager.default.removeItem(at: held.folder)
            try? FileManager.default.removeItem(at: held.lockFile)
            close(held.descriptor)
            self.held = nil
        }
        users.removeAll()
        removeLeftovers()
    }
}
