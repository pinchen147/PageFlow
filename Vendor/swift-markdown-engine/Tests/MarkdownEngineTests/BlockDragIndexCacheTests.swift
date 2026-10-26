import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Prepared block drag indexes")
struct BlockDragIndexCacheTests {
    private let revision = BlockDragIndexCache.Revision(source: 4, document: 2)

    @Test("reads stay unavailable until background normalization finishes")
    func readyOnly() async throws {
        let cache = BlockDragIndexCache()
        let source = "- Item\n  Continued\n\n  Child\n\nTail"
        let snapshot = BlockParser.snapshot(parsing: source as NSString)
        var published = 0
        cache.prepare(snapshot: snapshot, revision: revision, isCurrent: { true }, onReady: { published += 1 })
        #expect(cache.blocks(for: revision) == nil)
        await cache.task?.value
        let blocks = try #require(cache.blocks(for: revision))
        #expect(blocks.first?.range == NSRange(location: 0, length: (source as NSString).range(of: "\n\nTail").location + 1))
        #expect(published == 1)
        #expect(cache.blocks(for: .init(source: 5, document: 2)) == nil)
        #expect(cache.blocks(for: .init(source: 4, document: 3)) == nil)
    }

    @Test("a source change during preparation rejects the completed index")
    func staleCompletion() async {
        let cache = BlockDragIndexCache()
        var current = true
        var published = false
        cache.prepare(snapshot: BlockParser.snapshot(parsing: "Old"), revision: revision,
                      isCurrent: { current }, onReady: { published = true })
        current = false
        await cache.task?.value
        #expect(cache.blocks(for: revision) == nil)
        #expect(!published)
        #expect(cache.task == nil)
    }

    @Test("a replacement receipt wins even when its revision is unchanged")
    func supersededReceipt() async throws {
        let cache = BlockDragIndexCache()
        var oldPublished = false
        cache.prepare(snapshot: BlockParser.snapshot(parsing: "Old"), revision: revision,
                      isCurrent: { true }, onReady: { oldPublished = true })
        let oldTask = cache.task
        let replacement = BlockParser.snapshot(parsing: "# Replacement")
        cache.prepare(snapshot: replacement, revision: revision, isCurrent: { true }, onReady: {})
        await oldTask?.value
        await cache.task?.value
        #expect(!oldPublished)
        #expect(try #require(cache.blocks(for: revision)) == replacement.blocks)
    }

    @Test("document teardown cancels pending work and forbids publication")
    func cancelledPreparation() async {
        let cache = BlockDragIndexCache()
        var published = false
        cache.prepare(snapshot: BlockParser.snapshot(parsing: "- Item\n  Child"), revision: revision,
                      isCurrent: { true }, onReady: { published = true })
        let pending = cache.task
        cache.cancel()
        await pending?.value
        #expect(cache.task == nil)
        #expect(cache.blocks(for: revision) == nil)
        #expect(!published)
    }

    @Test("teardown clears an already prepared index")
    func cancelledReadyIndex() async throws {
        let cache = BlockDragIndexCache()
        cache.prepare(snapshot: BlockParser.snapshot(parsing: "Ready"), revision: revision,
                      isCurrent: { true }, onReady: {})
        await cache.task?.value
        #expect(cache.blocks(for: revision) != nil)
        cache.cancel()
        #expect(cache.blocks(for: revision) == nil)
    }
}
