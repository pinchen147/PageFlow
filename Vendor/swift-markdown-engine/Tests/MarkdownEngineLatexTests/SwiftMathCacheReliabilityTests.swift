import AppKit
import MarkdownEngine
import Testing
@testable import MarkdownEngineLatex

@MainActor
@Suite("SwiftMath rendering cache fidelity", .serialized)
struct SwiftMathCacheReliabilityTests {
    private func render(_ bridge: SwiftMathBridge, theme: MarkdownEditorTheme, appearance: NSAppearance.Name) throws -> LatexRenderResult {
        _ = NSApplication.shared
        let drawingAppearance = try #require(NSAppearance(named: appearance))
        var result: LatexRenderResult?
        drawingAppearance.performAsCurrentDrawingAppearance {
            result = bridge.render(latex: "x", fontSize: 18, theme: theme)
        }
        return try #require(result)
    }

    @Test("alpha changes produce separate formula pixels")
    func alphaInvalidatesCache() throws {
        let bridge = SwiftMathBridge()
        var theme = MarkdownEditorTheme.default
        theme.latexLightModeText = .red.withAlphaComponent(0.25)
        let translucent = try render(bridge, theme: theme, appearance: .aqua)
        theme.latexLightModeText = .red.withAlphaComponent(0.75)
        let opaque = try render(bridge, theme: theme, appearance: .aqua)
        #expect(translucent.image !== opaque.image)
    }

    @Test("the drawing appearance selects formula ink independently of the app")
    func currentDrawingAppearanceSelectsInk() throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        NSApp.appearance = NSAppearance(named: .aqua)
        let bridge = SwiftMathBridge()
        var theme = MarkdownEditorTheme.default
        theme.latexLightModeText = .red
        theme.latexDarkModeText = .blue
        let light = try render(bridge, theme: theme, appearance: .aqua)
        let dark = try render(bridge, theme: theme, appearance: .darkAqua)
        #expect(light.image !== dark.image)
        bridge.appearanceOverride = NSAppearance(named: .aqua)
        let overridden = try render(bridge, theme: theme, appearance: .darkAqua)
        #expect(overridden.image === light.image)
    }

    @Test("edited formulas release old images while later formulas stay renderable")
    func formulaCacheReleasesOldPixels() throws {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        weak var first: NSImage?
        autoreleasepool { first = bridge.render(latex: "z", fontSize: 18, theme: .default)?.image }
        #expect(first != nil)
        for revision in 0..<300 {
            autoreleasepool { _ = bridge.render(latex: "x_{\(revision)}", fontSize: 18, theme: .default) }
        }
        #expect(first == nil)
        #expect(bridge.render(latex: "x_{299}", fontSize: 18, theme: .default) != nil)
    }
}
