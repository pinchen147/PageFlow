//
//  FlattenedRunsTests.swift
//  MarkdownEngineTests
//
//  The flattened runs a whole-note rebuild applies must give every character
//  exactly the attributes the per-key addAttribute loop gave it.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Flattened styled runs")
struct FlattenedRunsTests {
    private static let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .kern, .underlineStyle, .link]

    private func randomRanges(length: Int, count: Int, seed: UInt64) -> [StyledRange] {
        var state = seed
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        return (0..<count).map { i in
            let start = next() % length
            let len = 1 + next() % max(1, min(40, length - start))
            var attrs: [NSAttributedString.Key: Any] = [:]
            let keyCount = 1 + next() % 3
            for _ in 0..<keyCount {
                let key = Self.keys[next() % Self.keys.count]
                attrs[key] = "\(key.rawValue)-\(i)-\(next() % 7)"
            }
            return (NSRange(location: start, length: len), attrs)
        }
    }

    @Test("every character ends with the attributes the addAttribute loop gives it", arguments: [1 as UInt64, 7, 42, 2026])
    func matchesNaiveLoop(seed: UInt64) {
        let length = 600
        let text = String(repeating: "x", count: length)
        let base: [NSAttributedString.Key: Any] = [.font: "base-font", .foregroundColor: "base-color"]
        let ranges = randomRanges(length: length, count: 120, seed: seed)

        let naive = NSMutableAttributedString(string: text, attributes: base)
        for (range, attrs) in ranges {
            for (key, value) in attrs { naive.addAttribute(key, value: value, range: range) }
        }
        let flattened = NSMutableAttributedString(string: text, attributes: base)
        var previousEnd = 0
        for run in TextStylingService.flattenedRuns(ranges, base: base, length: length) {
            #expect(run.range.location >= previousEnd, "runs are ordered and disjoint")
            previousEnd = NSMaxRange(run.range)
            flattened.setAttributes(run.attributes, range: run.range)
        }
        for position in 0..<length {
            let a = naive.attributes(at: position, effectiveRange: nil)
            let b = flattened.attributes(at: position, effectiveRange: nil)
            #expect(a.count == b.count, "attribute count at \(position)")
            for (key, value) in a {
                #expect((b[key] as? String) == (value as? String), "\(key.rawValue) at \(position)")
            }
        }
    }

    @Test("no styled ranges gives no runs; a range past the end is clipped")
    func edges() {
        #expect(TextStylingService.flattenedRuns([], base: [:], length: 10).isEmpty)
        let runs = TextStylingService.flattenedRuns([(NSRange(location: 8, length: 10), [.kern: 1])], base: [:], length: 10)
        #expect(runs.count == 1 && runs[0].range == NSRange(location: 8, length: 2))
    }
}
