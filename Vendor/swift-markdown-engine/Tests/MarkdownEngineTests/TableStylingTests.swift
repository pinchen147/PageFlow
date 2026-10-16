//
//  TableStylingTests.swift
//  MarkdownEngineTests
//
//  Table overlay styling coverage.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table styling")
struct TableStylingTests {
    private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

    @Test(arguments: [
        "A | B\n--- | ---\none\\|uno | two",
        "| A |\n| --- |\n| one\\|uno |"
    ])
    func narrowTableRendersInlineWithoutOverlay(text: String) throws {
        _ = NSApplication.shared
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )

        // Plain inline rendering: a narrow table collapses to a rendered image in
        // its own paragraph (no scrollable overlay → it can't drift onto the
        // following text). The live-preview overlay/grid is wide-only now.
        let image = try #require(attrs.compactMap { $0.attributes[.renderedBlockImage] as? NSImage }.first)
        #expect(image.size.width > 0 && image.size.height > 0)
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(pixels.width > 0 && pixels.height > 0)
        #expect(!attrs.contains { $0.attributes[.scrollableBlockSourceID] is Int })
    }

    @Test func invalidDelimiterDoesNotEmitOverlayAttributes() {
        let text = """
        A | B
        : | ---
        """
        let attrs = MarkdownStyler.styleAttributes(
            text: text,
            fontName: fontName,
            fontSize: 14,
            caretLocation: -1,
            activeTokenIndices: [],
            configuration: .default
        )

        #expect(!attrs.contains { $0.attributes[.scrollableBlockSourceID] is Int })
    }
}
