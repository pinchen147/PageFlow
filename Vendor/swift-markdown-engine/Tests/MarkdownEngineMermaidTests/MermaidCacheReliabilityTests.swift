import AppKit
import MarkdownEngine
import Testing
@testable import MarkdownEngineMermaid

@MainActor
@Suite("Mermaid rendering cache bounds")
struct MermaidCacheReliabilityTests {
    private let sourceA = "graph LR\n A --> B"
    private let sourceB = "graph LR\n C --> D"
    private let sourceC = "graph LR\n E --> F"
    private let generousCostLimit = 64 * 1_024 * 1_024

    private func makeBridge(countLimit: Int, costLimit: Int) -> MermaidBridge {
        _ = NSApplication.shared
        let bridge = MermaidBridge(renderScale: 2, cacheCountLimit: countLimit,
                                   cacheCostLimit: costLimit)
        bridge.appearanceOverride = NSAppearance(named: .aqua)
        return bridge
    }

    private func image(_ bridge: MermaidBridge, source: String, pixelScale: CGFloat = 2) throws -> NSImage {
        let result = try #require(bridge.render(
            source: source, language: "mermaid", maxWidth: 4000,
            fontSize: 16, theme: .default, pixelScale: pixelScale
        ))
        return result.image
    }

    private func bitmapCost(_ image: NSImage) throws -> Int {
        // TIFF exposes the actual high-density backing; an unhinted CGImage
        // lookup can silently return the screen's lower-density raster.
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let cost = bitmap.bytesPerRow * bitmap.pixelsHigh * bitmap.numberOfPlanes
        try #require(cost > 0)
        return cost
    }

    @Test("the entry limit evicts the least recently used raster")
    func countLimitKeepsRecentlyUsedImages() throws {
        let bridge = makeBridge(countLimit: 2, costLimit: generousCostLimit)
        let firstA = try image(bridge, source: sourceA)
        let firstB = try image(bridge, source: sourceB)
        #expect(try image(bridge, source: sourceA) === firstA)
        _ = try image(bridge, source: sourceC)

        #expect(try image(bridge, source: sourceA) === firstA,
                "a cache hit must keep A newer than B")
        #expect(try image(bridge, source: sourceB) !== firstB,
                "B must leave the two-entry cache")
    }

    @Test("the byte limit accounts for the real zoom-density raster")
    func byteLimitUsesBackingPixels() throws {
        let calibration = makeBridge(countLimit: 10, costLimit: generousCostLimit)
        let base = try image(calibration, source: sourceA)
        let dense = try image(calibration, source: sourceA, pixelScale: 4)
        let baseCost = try bitmapCost(base)
        let denseCost = try bitmapCost(dense)
        try #require(denseCost > baseCost * 3,
                     "the probe must carry substantially more pixels at 4x")
        try #require(abs(base.size.width - dense.size.width) < 1)
        // Either image fits, but both do not. The half-base margin also leaves
        // room for source keys and bitmap row-alignment differences.
        let budget = denseCost + baseCost / 2
        let bridge = makeBridge(countLimit: 10, costLimit: budget)
        let firstBase = try image(bridge, source: sourceA)
        let firstDense = try image(bridge, source: sourceA, pixelScale: 4)

        #expect(try image(bridge, source: sourceA, pixelScale: 4) === firstDense,
                "the dense raster must fit on its own")
        #expect(try image(bridge, source: sourceA) !== firstBase,
                "two point-identical density variants must exceed the byte budget")
    }

    @Test("an oversized diagram renders without evicting a useful cached raster")
    func oversizedImagesBypassCache() throws {
        let largeSource = """
        graph LR
            A["A deliberately long label makes this diagram much wider than the small cached graph"] --> B["Another long label keeps the backing raster well above the cache budget"]
        """
        let calibration = makeBridge(countLimit: 10, costLimit: generousCostLimit)
        let smallCost = try bitmapCost(image(calibration, source: sourceA))
        let largeCost = try bitmapCost(image(calibration, source: largeSource))
        let budget = smallCost * 2
        try #require(largeCost > budget * 2, "the large raster must exceed the budget with room to spare")
        let bridge = makeBridge(countLimit: 10, costLimit: budget)
        let small = try image(bridge, source: sourceA)
        let firstLarge = try image(bridge, source: largeSource)

        #expect(try image(bridge, source: sourceA) === small,
                "an uncacheable diagram must not flush a useful raster")
        #expect(try image(bridge, source: largeSource) !== firstLarge,
                "an oversized diagram must render successfully without being retained")
    }

    @Test("clearing the cache releases its byte budget for new rasters")
    func clearCacheResetsByteBudget() throws {
        let calibration = makeBridge(countLimit: 10, costLimit: generousCostLimit)
        let costA = try bitmapCost(image(calibration, source: sourceA))
        let costB = try bitmapCost(image(calibration, source: sourceB))
        let largestCost = max(costA, costB)
        try #require(min(costA, costB) > largestCost * 4 / 5,
                     "the probes must have similar backing costs")
        // Two rasters fit with margin. A stale pre-clear cost would evict one.
        let bridge = makeBridge(countLimit: 10, costLimit: largestCost * 5 / 2)
        let beforeClear = try image(bridge, source: sourceA)
        bridge.clearCache()
        let afterClear = try image(bridge, source: sourceA)
        let second = try image(bridge, source: sourceB)

        #expect(afterClear !== beforeClear, "clearing must discard the old image")
        #expect(try image(bridge, source: sourceA) === afterClear,
                "the cleared byte cost must not evict the new A raster")
        #expect(try image(bridge, source: sourceB) === second,
                "both new rasters must fit after clearing")
    }
}
