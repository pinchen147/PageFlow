//
//  MermaidOrientationTests.swift
//  MarkdownEngineMermaidTests
//
//  Guards the diagram's vertical orientation. BeautifulMermaid 1.0.4's macOS
//  raster path returns an upside-down image; MermaidBridge flips it back. This
//  test is library-behavior-agnostic: it asserts the *bridge output* is
//  right-side-up, so it catches BOTH the original upside-down bug AND a future
//  double-flip if a dependency bump fixes the library's raster path.
//

import AppKit
import Testing
@testable import MarkdownEngineMermaid

@MainActor
@Suite("Mermaid orientation")
struct MermaidOrientationTests {

    /// The x-extent (max x − min x) of drawn (non-transparent) pixels within
    /// `rows`, sampled top-left-origin so "top of the visual image" = low y.
    private func inkWidth(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Int {
        var minX = Int.max, maxX = -1
        var y = rows.lowerBound
        while y < rows.upperBound {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.2 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
                x += 2
            }
            y += 2
        }
        return maxX >= minX ? maxX - minX : 0
    }

    @Test("a top-to-bottom flowchart renders right-side-up (wide top node above the narrow bottom node)")
    func rightSideUp() throws {
        _ = NSApplication.shared
        // A deliberately WIDE top node and NARROW bottom node: right-side-up ⇒ the
        // top rows carry more horizontal ink than the bottom rows.
        let src = """
        flowchart TB
            TOP["a deliberately very wide top node label goes here"] --> BOT["x"]
        """
        let result = try #require(MermaidBridge().render(source: src, language: "mermaid",
                                                         maxWidth: 4000, fontSize: 16, theme: .default))
        let tiff = try #require(result.image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let h = rep.pixelsHigh
        let topWidth = inkWidth(rep, rows: 0 ..< (h / 4))
        let bottomWidth = inkWidth(rep, rows: (3 * h / 4) ..< h)
        #expect(topWidth > 0 && bottomWidth > 0, "both nodes must draw ink")
        #expect(topWidth > bottomWidth,
                "wide TOP node must sit above narrow BOTTOM node — top ink \(topWidth) vs bottom \(bottomWidth) (upside-down ⇒ reversed)")
    }
}
