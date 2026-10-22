import AppKit
import Testing
@testable import MarkdownEngine

/// the reference editor's table look (doc 24 §5.1, §5.10): the cell box, the regular-weight
/// header, the colors in both themes and the rhythm around a table.
@MainActor
@Suite("Table look", .serialized)
struct TableLookTests {
    private func layout(_ source: String, appearance: NSAppearance.Name = .darkAqua) throws -> MarkdownTableLayout {
        let model = try #require(MarkdownTableModel.parse(source))
        return MarkdownTableLayout(
            table: MarkdownStyler.parsedTable(from: model), font: .systemFont(ofSize: 16), theme: .default,
            codeBackground: .clear, latex: MarkdownEditorConfiguration.default.services.latex,
            appearance: try #require(NSAppearance(named: appearance))
        )
    }

    private func srgb(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
            + [Int((c.alphaComponent * 100).rounded())]
    }

    @Test("cells have 6 / 10 padding, 0.94 type on a 1.45 line, and a 34.8 pt one-line row")
    func cellBox() throws {
        let table = try layout("| A | B |\n| --- | --- |\n| one | two |")
        #expect(abs(table.cellFont.pointSize - 15.04) < 0.001)
        #expect(abs(table.lineHeight - 21.808) < 0.001)
        let header = table.cellRects[0][0]
        let body = table.cellRects[1][0]
        #expect(abs(header.height - 33.808) < 0.001)
        #expect(abs((body.minY - header.minY) - 34.808) < 0.001, "row pitch = line + 12 padding + 1 border")
        #expect(MarkdownTableLayout.horizontalPadding == 10 && MarkdownTableLayout.verticalPadding == 6)
        #expect(header.width + 1 >= MarkdownTableLayout.minimumColumnWidth, "column box, border included, is at least 48")
    }

    @Test("the header is regular weight in its own color; body cells use the body text color")
    func headerWeightAndColor() throws {
        let theme = MarkdownEditorTheme.default
        let latex = MarkdownEditorConfiguration.default.services.latex
        let header = MarkdownStyler.formattedCellString("Case", baseFont: .systemFont(ofSize: 15), header: true,
                                                        theme: theme, codeBackgroundColor: .clear, latex: latex)
        let body = MarkdownStyler.formattedCellString("one", baseFont: .systemFont(ofSize: 15), header: false,
                                                      theme: theme, codeBackgroundColor: .clear, latex: latex)
        let font = try #require(header.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(header.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === theme.tableHeaderText)
        #expect(body.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === theme.bodyText)
    }

    @Test("dark and light tokens resolve to the reference editor's values")
    func tokens() throws {
        let dark = try layout("| A |\n| --- |\n| 1 |", appearance: .darkAqua)
        let light = try layout("| A |\n| --- |\n| 1 |", appearance: .aqua)
        #expect(srgb(light.headerFill) == [0xF5, 0xF3, 0xED, 100])
        #expect(srgb(light.border) == [0xE8, 0xE5, 0xDC, 100])
        #expect(srgb(dark.headerFill) == [255, 255, 255, 4])
        #expect(srgb(dark.border) == [255, 255, 255, 10])
        var headerText: (dark: NSColor?, light: NSColor?)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            headerText.dark = MarkdownEditorTheme.default.tableHeaderText.usingColorSpace(.sRGB)
        }
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            headerText.light = MarkdownEditorTheme.default.tableHeaderText.usingColorSpace(.sRGB)
        }
        #expect(srgb(try #require(headerText.dark)) == [0xC3, 0xC2, 0xB7, 100])
        #expect(srgb(try #require(headerText.light)) == [0x52, 0x51, 0x4E, 100])
        #expect(MarkdownEditorTheme() == MarkdownEditorTheme.default, "default themes stay equal")
    }

    @Test("a table with no blank lines around it sits 25.6 below the text above and 19.6 above the text below")
    func rhythmWithoutSeparators() async throws {
        let source = "Para above\n| A | B |\n| --- | --- |\n| 1 | 2 |\nPara below is a paragraph"
        let editor = try MountedTableEditor(source: source)
        defer { editor.close() }
        await editor.settle()
        let gaps = try measuredGaps(editor, source: source)
        #expect(abs(gaps.above - 25.6) < 1, "measured \(gaps.above)")
        #expect(abs(gaps.below - 19.6) < 1, "measured \(gaps.below)")
    }

    @Test("blank separator lines keep their height and the table adds no spacing next to them")
    func rhythmWithSeparators() async throws {
        let tight = "Para above\n| A | B |\n| --- | --- |\n| 1 | 2 |\nPara below is a paragraph"
        let spaced = "Para above\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nPara below is a paragraph"
        let tightEditor = try MountedTableEditor(source: tight)
        defer { tightEditor.close() }
        await tightEditor.settle()
        let spacedEditor = try MountedTableEditor(source: spaced)
        defer { spacedEditor.close() }
        await spacedEditor.settle()
        let tightGaps = try measuredGaps(tightEditor, source: tight)
        let spacedGaps = try measuredGaps(spacedEditor, source: spaced)
        #expect(spacedGaps.above >= tightGaps.above - 1)
        #expect(spacedGaps.below >= tightGaps.below - 1)
        #expect(spacedGaps.above < tightGaps.above + 12, "a blank line does not stack extra table spacing")
    }

    /// From the text above to the table's top border, and from its bottom border to the text below.
    private func measuredGaps(_ editor: MountedTableEditor, source: String) throws -> (above: CGFloat, below: CGFloat) {
        let ns = source as NSString
        let table = try #require(editor.coordinator.parsedDocument(for: source).tokens.first { $0.kind == .table }).range
        let image = try #require(editor.main.tableImageRect(at: table.location))
        let above = try textBottom(editor, at: ns.range(of: "Para above").location)
        let below = try textTop(editor, at: ns.range(of: "Para below").location)
        return (image.minY - above, below - image.maxY)
    }

    private func fragment(_ editor: MountedTableEditor, at location: Int) throws -> NSTextLayoutFragment {
        let layout = try #require(editor.main.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let place = try #require(content.location(content.documentRange.location, offsetBy: location))
        return try #require(layout.textLayoutFragment(for: place))
    }

    private func textBottom(_ editor: MountedTableEditor, at location: Int) throws -> CGFloat {
        let fragment = try fragment(editor, at: location)
        let line = try #require(fragment.textLineFragments.last)
        return editor.main.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.maxY
    }

    private func textTop(_ editor: MountedTableEditor, at location: Int) throws -> CGFloat {
        let fragment = try fragment(editor, at: location)
        let line = try #require(fragment.textLineFragments.first)
        return editor.main.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
    }
}
