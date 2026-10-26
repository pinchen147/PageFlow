//
//  DocumentImageProvider.swift
//  PageFlow
//
//  Resolves `![alt](path)` images the way Obsidian and GitHub do: relative to
//  the note's own folder. Absolute paths and `file:` URLs are honoured; remote
//  URLs are never fetched (the engine then shows the dimmed source). Decoded
//  images (and misses) stay in a cache bounded by their pixel bytes, so a
//  restyle rarely touches the disk and a note full of screenshots can't hold
//  unbounded memory. The sandbox may deny a sibling file the user has not
//  opened; a folder the user allowed once and a file the user dropped are read
//  through the access remembered for them.
//

import AppKit
import ImageIO
import MarkdownEngine

final class DocumentImageProvider: EmbeddedImageProvider, @unchecked Sendable {
    private let documentURL: @Sendable () -> URL?
    /// A decode result, so a miss is cached too (NSCache holds objects only).
    private final class Decoded {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    /// Thread-safe; decoding happens outside it, so a slow image never blocks
    /// another lookup.
    private let cache = NSCache<NSString, Decoded>()

    init(documentURL: @escaping @Sendable () -> URL?) {
        self.documentURL = documentURL
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    func image(for request: EmbeddedImageRequest) -> NSImage? {
        guard let url = resolve(request.name) else { return nil }
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        // Direct first; then through the folder the user allowed (an image
        // beside the note, a saved paste); then through the grant a drop left.
        let image = Self.read(url)
            ?? FolderAccessStore.shared.withAccess(to: url) { Self.read(url) }
            ?? PastedImageStore.shared.withRememberedAccess(to: url, Self.read)
        let bytes = image?.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
        cache.setObject(Decoded(image), forKey: key, cost: max(1, bytes))
        return image
    }

    var baseFolderURL: URL? { documentURL()?.deletingLastPathComponent() }

    private func withImageAccess<T>(_ request: EmbeddedImageRequest, read: (URL) -> T?) -> T? {
        guard let url = resolve(request.name) else { return nil }
        return read(url) ?? FolderAccessStore.shared.withAccess(to: url) { read(url) }
            ?? PastedImageStore.shared.withRememberedAccess(to: url, read)
    }

    func fullResolutionImage(for request: EmbeddedImageRequest) -> NSImage? {
        withImageAccess(request) { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    func pixelSize(for request: EmbeddedImageRequest) -> CGSize? {
        withImageAccess(request) { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
    }

    /// Longest side, in pixels, an image is decoded at: twice the widest
    /// column the editor shows, so a Retina display still gets full density.
    /// A 12-megapixel screenshot decoded whole cost a visible pause on paste
    /// and a resample on every frame it scrolled through.
    static let maxDecodedPixels = 1_600

    /// Decodes `url` at no more than `maxDecodedPixels` on its longest side,
    /// honouring the file's orientation. Smaller images decode as they are.
    static func read(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodedPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// The note's folder: a Save As into another folder re-resolves every image.
    func fingerprint() -> AnyHashable {
        documentURL()?.deletingLastPathComponent().path ?? ""
    }

    /// The engine's decoded destination (no title, no `<…>`) as a local file,
    /// percent-escapes decoded. `nil` for anything remote.
    func resolve(_ destination: String) -> URL? {
        let reference = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return nil }
        if let url = URL(string: reference), let scheme = url.scheme?.lowercased() {
            return scheme == "file" ? url.standardizedFileURL : nil
        }
        let path = reference.removingPercentEncoding ?? reference
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let base = documentURL()?.deletingLastPathComponent() else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    }
}
