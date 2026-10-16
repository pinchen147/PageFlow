//
//  LatexRenderingTests.swift
//  MarkdownEngineTests
//
//  Pins inline LaTeX rendering eligibility independent of the real SwiftMath
//  bridge. The fake renderer is enough to assert that parsed formulas receive
//  image attributes when inactive.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("LaTeX rendering")
struct LatexRenderingTests {
    private struct StubLatexRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = CGSize(width: max(1, latex.count) * 4, height: 8)
            return LatexRenderResult(
                image: NSImage(size: size),
                size: size,
                baselineOffset: 2
            )
        }
    }

    private struct NilLatexRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
    }

    @Test("short inline formulas render, including leading-digit coefficients")
    func shortInlineFormulaImages() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: StubLatexRenderer())

        let attrs = MarkdownStyler.styleAttributes(
            text: "$a$ $3a$",
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: 8,
            activeTokenIndices: [],
            configuration: configuration
        )

        let renderedAnchors = attrs.filter { _, attributes in
            attributes[.renderedBlockImage] is NSImage
        }

        #expect(renderedAnchors.count == 2)
    }

    @Test("long identifier formulas render")
    func longIdentifierFormulaRenders() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: StubLatexRenderer())

        let attrs = MarkdownStyler.styleAttributes(
            text: "$fjdalkfjdslkajd$",
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: 17,
            activeTokenIndices: [],
            configuration: configuration
        )

        #expect(attrs.contains { _, attributes in
            attributes[.renderedBlockImage] is NSImage
        })
    }

    @Test("unrenderable formulas stay readable and suppress spelling")
    func unrenderableFormulaFallbackIsReadable() {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: NilLatexRenderer())

        let attrs = MarkdownStyler.styleAttributes(
            text: "$fjdalkfjdslkajd$",
            fontName: NSFont.systemFont(ofSize: 16).fontName,
            fontSize: 16,
            caretLocation: 17,
            activeTokenIndices: [],
            configuration: configuration
        )

        #expect(attrs.contains { range, attributes in
            range == NSRange(location: 0, length: 17)
                && attributes[.spellingState] as? Int == 0
        })
        #expect(!attrs.contains { _, attributes in
            attributes[.renderedBlockImage] is NSImage
        })
    }
}
