//
//  MathTextParserTests.swift
//  PageFlowTests
//
//  The memoized math parse: repeated parses are stable (cache hit == fresh
//  compute), the nil fast-path is cached too, and distinct inputs are never
//  conflated by the cache.
//

import Testing
@testable import PageFlow

struct MathTextParserTests {

    @Test
    func repeatedParseOfMathTextReturnsEqualSegments() {
        let text = "area $a^2$ and $$b = c$$ done"

        let first = MathTextParser.parse(text)
        let second = MathTextParser.parse(text)  // served from the cache

        #expect(first == [
            .plain("area "),
            .inlineMath("a^2"),
            .plain(" and "),
            .displayMath("b = c"),
            .plain(" done"),
        ])
        #expect(second == first)
    }

    @Test
    func repeatedParseOfPlainTextReturnsNilBothTimes() {
        let text = "no math in here"

        #expect(MathTextParser.parse(text) == nil)
        #expect(MathTextParser.parse(text) == nil)  // cached nil stays nil
    }

    @Test
    func distinctInputsAreNotConflated() {
        #expect(MathTextParser.parse("price is $a$") == [.plain("price is "), .inlineMath("a")])
        #expect(MathTextParser.parse("price is $b$") == [.plain("price is "), .inlineMath("b")])
    }
}
