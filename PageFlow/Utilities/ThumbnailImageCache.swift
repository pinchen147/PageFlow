import AppKit
import PDFKit

/// Bounded thumbnail reuse that never extends a PDF document's lifetime.
@MainActor
final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    private final class Entry {
        weak var document: PDFDocument?
        let image: NSImage

        init(image: NSImage, document: PDFDocument) {
            self.image = image
            self.document = document
        }
    }

    private let cache = NSCache<NSString, Entry>()
    /// Each open document's keys, so its thumbnails can go when it closes.
    private var keys: [ObjectIdentifier: Set<String>] = [:]

    private init() {
        cache.countLimit = 400
        // Keep recent pages reusable without retaining hundreds of decoded
        // thumbnails after scrolling through a long document.
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func removeAll() {
        cache.removeAllObjects()
        keys.removeAll()
    }

    /// A closed document's thumbnails can't be found again: a lookup checks the
    /// document, and a new one misses. They would only hold memory until evicted.
    func removeImages(of document: PDFDocument) {
        for key in keys.removeValue(forKey: ObjectIdentifier(document)) ?? [] {
            cache.removeObject(forKey: key as NSString)
        }
    }

    func image(for key: String, document: PDFDocument) -> NSImage? {
        // ObjectIdentifier addresses can be reused after a document closes.
        // The weak owner distinguishes that new document without retaining the old one.
        guard let entry = cache.object(forKey: key as NSString), entry.document === document else { return nil }
        return entry.image
    }

    func insert(_ image: NSImage, for key: String, document: PDFDocument) {
        cache.setObject(Entry(image: image, document: document), forKey: key as NSString, cost: Self.byteCost(of: image))
        keys[ObjectIdentifier(document), default: []].insert(key)
    }

    /// Approximate decoded footprint in bytes (4 bytes per device pixel).
    private static func byteCost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }
}
