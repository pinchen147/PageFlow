import Foundation
import Testing
@testable import MarkdownEngine

/// the reference editor's rail stacking (doc 25 §4.3).
@Suite("Comment rail layout")
struct CommentRailLayoutTests {
    private func slot(_ id: String, _ y: CGFloat, _ height: CGFloat = 56, created: TimeInterval = 0) -> CommentRailLayout.Slot {
        .init(id: id, y: y, height: height, created: Date(timeIntervalSince1970: created))
    }

    @Test("without a pivot, cards sit on their anchors and push down 8 apart")
    func walksDown() {
        let result = CommentRailLayout.solve([slot("a", 100), slot("b", 120), slot("c", 400)], pivot: nil, bottom: 10_000)
        #expect(result.tops == ["a": 100, "b": 164, "c": 400])
        #expect(result.overhang == 0)
    }

    @Test("ties on one line keep creation order")
    func creationOrder() {
        let result = CommentRailLayout.solve([slot("late", 100, created: 2), slot("early", 100, created: 1)], pivot: nil, bottom: 10_000)
        #expect(result.tops == ["early": 100, "late": 164])
    }

    @Test("the pivot stays on its anchor; cards above it move up, below it move down")
    func pivotPins() {
        let result = CommentRailLayout.solve([slot("a", 100), slot("b", 120), slot("c", 140)], pivot: "b", bottom: 10_000)
        #expect(result.tops["b"] == 120)
        #expect(result.tops["a"] == CGFloat(56))
        #expect(result.tops["c"] == CGFloat(184))
    }

    @Test("cards above the pivot that do not collide keep their anchors")
    func pivotLeavesRoom() {
        let result = CommentRailLayout.solve([slot("a", 0), slot("b", 300)], pivot: "b", bottom: 10_000)
        #expect(result.tops == ["a": 0, "b": 300])
    }

    @Test("the stack is pulled up to end above the bottom, at most 400 above an anchor")
    func bandClamp() {
        let near = CommentRailLayout.solve([slot("a", 950, 100)], pivot: nil, bottom: 1000)
        #expect(near.tops["a"] == 900)
        #expect(near.overhang == 0)
        let tall = CommentRailLayout.solve([slot("a", 950, 600)], pivot: nil, bottom: 1000)
        #expect(tall.tops["a"] == 550)
        #expect(tall.overhang == 150)
    }
}
