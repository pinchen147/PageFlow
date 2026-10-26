import Foundation

/// Session-only fold choices carried by a source edit and its inverse.
struct MarkdownFoldTransfer {
    let regions: [MarkdownFoldRegion]
    let collapsed: Set<Int>

    static let empty = MarkdownFoldTransfer(regions: [], collapsed: [])

    var headingIndices: [Int] {
        regions.indices.filter { collapsed.contains(regions[$0].heading.location) }
    }

    init(regions: [MarkdownFoldRegion], collapsed: Set<Int>) {
        self.regions = regions
        self.collapsed = collapsed
    }

    init(source: NSString, headingIndices: [Int]) {
        let parsedRegions = MarkdownFoldIndex(source: source,
            blocks: BlockParser.parse(source as String, memoizing: false)).regions
        regions = parsedRegions
        collapsed = Set(headingIndices.compactMap { parsedRegions.indices.contains($0) ? parsedRegions[$0].heading.location : nil })
    }

    func shifted(by delta: Int) -> MarkdownFoldTransfer {
        MarkdownFoldTransfer(regions: regions.map {
            MarkdownFoldRegion(heading: NSRange(location: $0.heading.location + delta, length: $0.heading.length),
                body: NSRange(location: $0.body.location + delta, length: $0.body.length),
                level: $0.level, hiddenBlockCount: $0.hiddenBlockCount)
        }, collapsed: Set(collapsed.map { $0 + delta }))
    }
}
