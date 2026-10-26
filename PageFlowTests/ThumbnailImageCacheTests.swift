import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct ThumbnailImageCacheTests {
    @Test("a thumbnail belongs to its live PDF document, even when keys collide")
    func liveDocumentsDoNotShareAKey() {
        let cache = ThumbnailImageCache.shared
        let key = UUID().uuidString
        let first = PDFDocument()
        let second = PDFDocument()
        let image = NSImage(size: NSSize(width: 20, height: 20))
        cache.insert(image, for: key, document: first)
        #expect(cache.image(for: key, document: first) === image)
        #expect(cache.image(for: key, document: second) == nil)
        #expect(cache.image(for: key, document: first) === image,
                "a rejected lookup must not invalidate the live owner's thumbnail")
    }

    @Test("retired documents release and their cached images cannot reach a new owner")
    func retiredOwnerCannotSupplyANewDocument() {
        let cache = ThumbnailImageCache.shared
        let key = UUID().uuidString
        let oldImage = NSImage(size: NSSize(width: 20, height: 20))
        weak var retired: PDFDocument?
        autoreleasepool {
            let old = PDFDocument()
            retired = old
            cache.insert(oldImage, for: key, document: old)
            #expect(cache.image(for: key, document: old) === oldImage)
        }
        #expect(retired == nil, "the thumbnail cache must not keep its PDF document alive")
        let current = PDFDocument()
        // A fresh process probe demonstrated actual PDF address reuse. Supply
        // that collision directly here so this regression does not depend on
        // allocator scheduling or on a particular OS reusing an address.
        #expect(cache.image(for: key, document: current) == nil)
        let newImage = NSImage(size: NSSize(width: 30, height: 30))
        cache.insert(newImage, for: key, document: current)
        #expect(cache.image(for: key, document: current) === newImage)
    }
}
