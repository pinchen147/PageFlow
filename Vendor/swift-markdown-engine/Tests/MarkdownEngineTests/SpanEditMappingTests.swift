//
//  SpanEditMappingTests.swift
//  MarkdownEngineTests
//
//  How a character offset follows a whole-span format edit: the viewport
//  pin must measure the same paragraph before and after.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Span-edit anchor mapping")
struct SpanEditMappingTests {
    @Test("a location maps to the start of the same paragraph by index; outside the span it shifts or stays")
    func paragraphIndexMapping() {
        let old = "alpha\nbeta gamma\ndelta\n"
        let new = "**alpha**\n**beta gamma**\n**delta**\n"
        let map = NativeTextViewCoordinator.paragraphPreservingMap(from: old, to: new, spanStart: 10)
        #expect(map(3) == 3, "before the span")
        #expect(map(10) == 10, "the span start")
        #expect(map(10 + 8) == 10 + 10, "inside 'beta gamma' → the start of the bolded second paragraph")
        #expect(map(10 + 20) == 10 + 25, "inside 'delta' → the start of the bolded third paragraph")
        #expect(map(10 + old.utf16.count + 5) == 10 + new.utf16.count + 5, "after the span shifts by the length change")
    }

    @Test("the inverse map takes the formatted text back to the same paragraph")
    func inverseMapping() {
        let old = "**alpha**\n**beta gamma**\n**delta**\n"
        let new = "alpha\nbeta gamma\ndelta\n"
        let map = NativeTextViewCoordinator.paragraphPreservingMap(from: old, to: new, spanStart: 0)
        #expect(map(12) == 6, "inside the bolded second paragraph → the start of 'beta gamma'")
        #expect(map(30) == 17, "inside the bolded third paragraph → the start of 'delta'")
    }
}
