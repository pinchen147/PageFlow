//
//  SwiftMathDiskCacheTests.swift
//  MarkdownEngineLatexTests
//
//  A formula rendered once is served from the on-disk cache by a fresh
//  bridge (a new launch), with the same size and baseline.
//

import AppKit
import MarkdownEngine
import Testing
@testable import MarkdownEngineLatex

@Suite("SwiftMath disk cache")
struct SwiftMathDiskCacheTests {
    @MainActor
    @Test("a fresh bridge serves a formula rendered earlier from disk")
    func secondBridgeReadsDisk() throws {
        _ = NSApplication.shared
        // A formula no other test renders, so the first render is a real one
        // (or a hit from an earlier run of this test — either way the second
        // bridge must hit).
        let formula = #"\frac{\pi^{\(Int.random(in: 1000...9999))}}{\sqrt{2}}"#
            .replacingOccurrences(of: "\\(Int.random(in: 1000...9999))", with: String(Int.random(in: 1000...9999)))
        let first = SwiftMathBridge()
        let a = try #require(first.render(latex: formula, fontSize: 17, theme: .default))
        // The write is asynchronous; give it a moment.
        let deadline = Date().addingTimeInterval(2)
        var b: LatexRenderResult?
        var second = SwiftMathBridge()
        while Date() < deadline {
            second = SwiftMathBridge()
            b = second.render(latex: formula, fontSize: 17, theme: .default)
            if second.diskCacheHits == 1 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(second.diskCacheHits == 1, "the second bridge should have read the formula from disk")
        let result = try #require(b)
        #expect(abs(result.size.width - a.size.width) < 0.01 && abs(result.size.height - a.size.height) < 0.01)
        #expect(abs(result.baselineOffset - a.baselineOffset) < 0.01)
        let rep = result.image.representations.first as? NSBitmapImageRep
        #expect(rep != nil && (rep?.pixelsWide ?? 0) > 0)
    }
}
