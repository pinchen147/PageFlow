import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table image cache source fidelity", .serialized)
struct TableImageCacheReliabilityTests {
    private final class Palette { var ink = NSColor.red }

    private struct WidthRenderer: LatexRenderer {
        let width: CGFloat
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = NSSize(width: width, height: 20)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 0)
        }
    }

    private func image(_ source: String, configuration: MarkdownEditorConfiguration = .default) throws -> NSImage {
        _ = NSApplication.shared
        let table = try #require(MarkdownTokenizer.parseTokensViaAST(in: source).first { $0.kind == .table })
        let appearance = try #require(NSAppearance(named: .aqua))
        var attributes: [StyledRange] = []
        appearance.performAsCurrentDrawingAppearance {
            attributes = MarkdownStyler.styleAttributes(
                text: source, fontName: "Helvetica", fontSize: 14,
                caretLocation: -1, activeTokenIndices: [], configuration: configuration
            )
        }
        let blockImage = attributes.first {
            $0.attributes[.latexIsBlock] as? Bool == true
                && NSIntersectionRange($0.range, table.range).length > 0
                && $0.attributes[.renderedBlockImage] is NSImage
        }
        return try #require(blockImage?.attributes[.renderedBlockImage] as? NSImage)
    }

    private func redBlueTint(_ image: NSImage) throws -> CGFloat {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        var tint: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                tint += (color.redComponent - color.blueComponent) * color.alphaComponent
            }
        }
        return tint
    }

    @Test("unchanged table source reuses its rendered pixels")
    func unchangedSourceReusesImage() throws {
        let source = "| Unique warm cache | B |\n|---|---|\n| **bold** and `code` | body |"
        let first = try image(source)
        #expect(try image(source) === first)
    }

    @Test("canonical-equivalent table text keeps separate literal cache identity")
    func literalSourceIdentity() throws {
        let first = try image("| café | B |\n|---|---|\n| body | other |")
        let second = try image("| cafe\u{301} | B |\n|---|---|\n| body | other |")
        #expect(first !== second)
    }

    @Test("resolved dynamic ink changes invalidate table pixels")
    func resolvedColorsInvalidateImage() throws {
        let palette = Palette()
        var configuration = MarkdownEditorConfiguration.default
        configuration.theme.tableBorder = NSColor(name: "table-cache-ink", dynamicProvider: { _ in palette.ink })
        let source = "| Dynamic ink | B |\n|---|---|\n| body | other |"
        let red = try image(source, configuration: configuration)
        #expect(try redBlueTint(red) > 0)
        palette.ink = .blue
        let blue = try image(source, configuration: configuration)
        #expect(red !== blue)
        #expect(try redBlueTint(blue) < 0)
    }

    @Test("stateful value renderers cannot reuse stale math table pixels")
    func mathProviderChangesTableWidth() throws {
        let source = "| Math | Other |\n|---|---|\n| $x$ | body |"
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.latex = WidthRenderer(width: 40)
        let first = try image(source, configuration: configuration)
        configuration.services.latex = WidthRenderer(width: 80)
        let second = try image(source, configuration: configuration)
        #expect(second.size.width == first.size.width + 40)
    }

    @Test("rendered table revisions release old pixels within the image budget")
    func editedVersionsDoNotAccumulate() throws {
        weak var first: NSImage?
        try autoreleasepool { first = try image("| Budget old revision | B |\n|---|---|\n| body | other |") }
        for revision in 0..<16 {
            let cell = String(repeating: "wide content ", count: 10) + String(revision)
            let source = "| Budget revision \(revision) | B |\n|---|---|\n" + String(repeating: "| \(cell) | other |\n", count: 50)
            try autoreleasepool { _ = try image(source) }
        }
        #expect(first == nil)
    }
}
