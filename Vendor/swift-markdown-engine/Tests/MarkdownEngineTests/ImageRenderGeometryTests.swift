//
//  ImageRenderGeometryTests.swift
//  MarkdownEngineTests
//
//  Where an image's tokens put it (doc 26 §2.7): alignment in the column, an
//  explicit width without the height cap, the 40 pt minimum, the empty-alt
//  anchor, and `![[…]]` embeds.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Image render geometry", .serialized)
struct ImageRenderGeometryTests {
    private static let column = MountedImageEditor.columnWidth
    private static let images = [
        "wide.png": TestImages.solid(CGSize(width: 1_344, height: 672)),
        "portrait.png": TestImages.solid(CGSize(width: 1_170, height: 2_532)),
    ]

    private func mounted(_ source: String) async throws -> MountedImageEditor {
        let editor = try MountedImageEditor(source: source, images: Self.images)
        await editor.settle()
        return editor
    }

    @Test("left / center / right put a 336 pt image at x 0 / 168 / 336 of a 672 column")
    func alignment() async throws {
        let editor = try await mounted("""
        Intro.

        ![L|336](wide.png)

        ![C|center|336](wide.png)

        ![R|right|336](wide.png)

        End.
        """)
        defer { editor.close() }
        for (marker, x) in [("![L", 0.0), ("![C", 168.0), ("![R", 336.0)] {
            let frame = try editor.imageFrame(onLineOf: marker)
            #expect(abs(frame.width - 336) < 0.01 && abs(frame.height - 168) < 0.01, "\(marker): \(frame)")
            #expect(abs(frame.minX - x) < 0.5, "\(marker) drawn at \(frame.minX), expected \(x)")
            let line = try editor.anchorLine(onLineOf: marker)
            #expect(abs(line.minX - frame.minX) < 0.5, "\(marker): the anchor glyph sits under the image")
        }
    }

    @Test("an explicit width on a 1170 × 2532 screenshot is honoured past the 480 pt height cap")
    func explicitWidthIgnoresHeightCap() async throws {
        let editor = try await mounted("![Phone|300](portrait.png)\n\n![Capped](portrait.png)\n\nEnd.")
        defer { editor.close() }
        let sized = try editor.imageFrame(onLineOf: "![Phone")
        #expect(abs(sized.width - 300) < 0.01)
        #expect(sized.height > 480 && abs(sized.height - 300 * 2_532 / 1_170) < 0.01)
        let capped = try editor.imageFrame(onLineOf: "![Capped")
        #expect(abs(capped.height - 480) < 0.01, "no token: the height cap stands")
    }

    @Test("a width token of 30 renders 40; one past the column renders the column")
    func widthClamps() async throws {
        let editor = try await mounted("![Tiny|30](wide.png)\n\n![Huge|5000](wide.png)\n\nEnd.")
        defer { editor.close() }
        #expect(abs(try editor.imageFrame(onLineOf: "![Tiny").width - 40) < 0.01)
        #expect(abs(try editor.imageFrame(onLineOf: "![Huge").width - Self.column) < 0.01)
    }

    @Test("`![](x)` reserves the image's width; an empty description aligns like any other")
    func emptyAlt() async throws {
        let editor = try await mounted("""
        Intro.

        ![](wide.png)

        ![|center|336](wide.png)

        ![|right|336](wide.png)

        End.
        """)
        defer { editor.close() }
        let bare = try editor.imageFrame(onLineOf: "![](")
        #expect(abs(bare.width - Self.column) < 0.01 && abs(bare.minX) < 0.5)
        let bareLine = try editor.anchorLine(onLineOf: "![](")
        #expect(abs(bareLine.width - Self.column) < 1, "the anchor's advance is the image width: \(bareLine.width)")
        let anchor = try editor.imageAnchor(onLineOf: "![](")
        #expect((editor.main.string as NSString).substring(with: NSRange(location: anchor, length: 1)) == "!")

        for (marker, x) in [("![|center", 168.0), ("![|right", 336.0)] {
            let frame = try editor.imageFrame(onLineOf: marker)
            #expect(abs(frame.minX - x) < 0.5, "\(marker) drawn at \(frame.minX), expected \(x)")
            let line = try editor.anchorLine(onLineOf: marker)
            #expect(abs(line.minX - x) < 0.5, "\(marker): anchor glyph at \(line.minX)")
        }
    }

    @Test("`![[…|300|center]]` is 300 wide and centred")
    func embedTokens() async throws {
        let editor = try await mounted("Intro.\n\n![[wide.png|300|center]]\n\nEnd.")
        defer { editor.close() }
        let frame = try editor.imageFrame(onLineOf: "![[wide")
        #expect(abs(frame.width - 300) < 0.01 && abs(frame.height - 150) < 0.01)
        #expect(abs(frame.minX - (Self.column - 300) / 2) < 0.5, "drawn at \(frame.minX)")
    }

    @Test("a revealed image keeps its alignment under its source line")
    func revealedKeepsAlignment() async throws {
        let source = "Intro.\n\n![R|right|336](wide.png)\n\nEnd."
        let editor = try await mounted(source)
        defer { editor.close() }
        // No user path reveals a rendered image any more (doc 26 §3): a caret in
        // it selects the image. The reveal stays for Edit image source (Q4), so
        // the caret goes in past the selection net.
        editor.coordinator.isSettingObjectSelection = true
        editor.main.setSelectedRange(NSRange(location: (source as NSString).range(of: "![R").location + 3, length: 0))
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editor.main))
        editor.coordinator.isSettingObjectSelection = false
        await editor.settle()
        let storage = try #require(editor.main.textStorage)
        let token = (source as NSString).range(of: "![R|right|336](wide.png)")
        #expect(storage.attribute(.latexBlockOffsetY, at: token.location, effectiveRange: nil) != nil, "source revealed")
        let frame = try editor.imageFrame(onLineOf: "![R")
        #expect(abs(frame.minX - 336) < 0.5, "drawn at \(frame.minX)")
    }

    @Test("rendering every token form writes nothing back to the note")
    func renderingNeverRewrites() async throws {
        let source = #"""
        ![Left](wide.png)

        ![Centred|CENTER|420](wide.png)

        ![a|300|420|left|crop=0,0,1,1](wide.png)

        ![Q3 \| 2024|crop=0.12,0.05,0.80,0.90|420](wide.png)

        ![Unknown|foo| 300 ](wide.png)

        ![](wide.png)

        ![[wide.png|640x480|right]]

        ![Missing|center](missing.png)
        """#
        let editor = try await mounted(source)
        defer { editor.close() }
        #expect(editor.state.text == source)
        #expect(editor.main.string == source)
        #expect(editor.state.undo.canUndo == false)
    }

    @Test("the collapsed anchor carries the block's kind and its anchor-relative source range")
    func anchorAttributes() async throws {
        let source = "Intro.\n\n![C|center|crop=0,0,0.25,0.5|336](wide.png)\n\nEnd."
        let editor = try await mounted(source)
        defer { editor.close() }
        let anchor = try editor.imageAnchor(onLineOf: "![C")
        let storage = try #require(editor.main.textStorage)
        func value(_ key: NSAttributedString.Key) -> Any? { storage.attribute(key, at: anchor, effectiveRange: nil) }
        #expect(value(.markdownBlockKind) as? String == MarkdownBlockKind.image.rawValue)
        let range = try #require(value(.markdownBlockSourceRange) as? NSValue)
        #expect(AnchorRelativeRange.decode(range, anchorLocation: anchor)
            == (source as NSString).range(of: "![C|center|crop=0,0,0.25,0.5|336](wide.png)"))
        #expect((value(.blockImageCrop) as? NSValue)?.rectValue == CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
        #expect(value(.blockImageCornerRadius) as? CGFloat == 4)
        // The kept part sets the aspect: a quarter of the width and half the height of a 2:1 image is 1:1.
        let frame = try editor.imageFrame(onLineOf: "![C")
        #expect(abs(frame.width - 336) < 0.01 && abs(frame.height - 336) < 0.01)
    }
}
