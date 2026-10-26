import AppKit
import Testing
import MarkdownEngineCodeBlocks

@MainActor
@Suite("Highlighter literal source fidelity", .serialized)
struct HighlighterSourceFidelityTests {
    @Test("canonical-equivalent source retains its own UTF-16 highlighting coordinates")
    func literalSourceCacheIdentity() throws {
        _ = NSApplication.shared
        for (first, second) in [("let café = 1", "let cafe\u{301} = 1"), ("let cafe\u{301} = 1", "let café = 1")] {
            let bridge = HighlighterSwiftBridge()
            let initial = try #require(bridge.highlight(code: first, language: "swift"))
            let changed = try #require(bridge.highlight(code: second, language: "swift"))
            #expect(initial.string.utf16.elementsEqual(first.utf16))
            #expect(changed.string.utf16.elementsEqual(second.utf16))
            #expect(changed.length == second.utf16.count)
        }
    }

    @Test("cached syntax colors still resolve for the appearance drawing the code")
    func cachedColorsResolveAtDrawTime() throws {
        _ = NSApplication.shared
        let bridge = HighlighterSwiftBridge()
        let text = "let x = 42"
        let highlighted = try #require(bridge.highlight(code: text, language: "swift"))
        let color = try #require(highlighted.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightColor: NSColor?, darkColor: NSColor?
        light.performAsCurrentDrawingAppearance { lightColor = color.usingColorSpace(.sRGB) }
        dark.performAsCurrentDrawingAppearance { darkColor = color.usingColorSpace(.sRGB) }
        #expect(lightColor != darkColor)
        #expect(bridge.highlight(code: text, language: "swift") === highlighted)
        #expect(bridge.highlight(code: text, language: nil) == nil)
    }
}
