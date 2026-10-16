//
//  MermaidRenderingTests.swift
//  MarkdownEngineTests
//
//  Milestone 2 of native block-diagram (Mermaid) rendering: the
//  library-agnostic STYLING integration, driven by a mock renderer. Mirrors
//  LatexRenderingTests/TableStylingTests — a fenced block whose info-string
//  names a diagram language collapses to the rendered image when inactive,
//  reveals raw source when the caret enters, and falls back to an ordinary
//  code block whenever the renderer returns nil (incl. the NoOp renderer).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

// MARK: - Mock renderer

/// Renders a fixed image for `"mermaid"` (and any language passed in
/// `alsoRenders`), `nil` otherwise, counting every call. `@unchecked Sendable`
/// via a lock so it satisfies the `BlockDiagramRenderer: Sendable` requirement
/// while still exposing a mutable call counter to the test thread.
private final class MockDiagramRenderer: BlockDiagramRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _languages: [String] = []
    private var _maxWidths: [CGFloat] = []
    let imageSize: CGSize
    let alsoRenders: Set<String>

    init(imageSize: CGSize = CGSize(width: 240, height: 160), alsoRenders: Set<String> = []) {
        self.imageSize = imageSize
        self.alsoRenders = alsoRenders
    }

    var callCount: Int { lock.withLock { _callCount } }
    var renderedLanguages: [String] { lock.withLock { _languages } }
    var maxWidths: [CGFloat] { lock.withLock { _maxWidths } }

    func render(source: String, language: String, maxWidth: CGFloat,
                fontSize: CGFloat, theme: MarkdownEditorTheme) -> DiagramRenderResult? {
        lock.withLock { _callCount += 1; _languages.append(language); _maxWidths.append(maxWidth) }
        guard language == "mermaid" || alsoRenders.contains(language) else { return nil }
        return DiagramRenderResult(image: NSImage(size: imageSize), size: imageSize)
    }
}

/// Opaque code-block background so "was the code fill cleared under the diagram?"
/// is observable (the default PlainText highlighter's background is transparent).
private struct OpaqueCodeHighlighter: SyntaxHighlighter {
    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { NSColor(calibratedWhite: 0.5, alpha: 1) }
    func highlight(code: String, language: String?) -> NSAttributedString? { nil }
    var appearanceDidChangeNotification: Notification.Name? { nil }
}

@MainActor
@Suite("Mermaid diagram rendering")
struct MermaidRenderingTests {
    private var fontName: String { NSFont.systemFont(ofSize: 16).fontName }

    /// The last-wins value of `key` at `location`, folding the ordered styled
    /// ranges exactly as `NSTextStorage.addAttribute` would (later ranges
    /// override earlier ones for the same key) — the honest oracle for
    /// "the diagram pass cleared the code background the AST styler painted".
    private func effective(_ key: NSAttributedString.Key, at location: Int, in attrs: [StyledRange]) -> Any? {
        var value: Any?
        for (range, a) in attrs where NSLocationInRange(location, range) {
            if let v = a[key] { value = v }
        }
        return value
    }

    private func services(diagram: any BlockDiagramRenderer,
                          highlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter()) -> MarkdownEditorServices {
        MarkdownEditorServices(syntaxHighlighter: highlighter, diagram: diagram)
    }

    // (a) inactive ```mermaid → anchor carries the image + the code background is cleared.
    @Test("an inactive mermaid block collapses to the diagram image and clears the code background")
    func inactiveMermaidRendersAndClearsBackground() {
        _ = NSApplication.shared
        let renderer = MockDiagramRenderer()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = services(diagram: renderer, highlighter: OpaqueCodeHighlighter())

        let text = "Intro\n\n```mermaid\ngraph TD\nA-->B\n```\n\nOutro"
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )

        let anchor = attrs.first { $0.attributes[.renderedBlockImage] is NSImage }
        #expect(anchor != nil, "inactive mermaid block should plant a rendered image on its anchor char")
        #expect(renderer.callCount == 1)
        #expect(renderer.renderedLanguages == ["mermaid"])

        // The AST styler painted the opaque code background over this range;
        // the diagram pass must clear it so it doesn't show behind the image.
        let anchorLoc = try! #require(anchor).range.location
        let bg = effective(.backgroundColor, at: anchorLoc, in: attrs) as? NSColor
        #expect(bg?.alphaComponent == 0, "code background must be cleared under the diagram, got \(String(describing: bg))")
    }

    // (b) caret inside → no image, raw source revealed (fallback to code styling).
    @Test("a mermaid block with the caret inside reveals raw source and renders no image")
    func activeMermaidRevealsSource() {
        _ = NSApplication.shared
        let renderer = MockDiagramRenderer()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = services(diagram: renderer)

        let text = "```mermaid\ngraph TD\nA-->B\n```\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let caret = 13   // inside "graph"
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: text as NSString
        )

        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: caret, activeTokenIndices: active,
            precomputedTokens: tokens, configuration: configuration
        )

        #expect(!attrs.contains { $0.attributes[.renderedBlockImage] is NSImage },
                "an active (caret-inside) mermaid block must not render an image")
        #expect(renderer.callCount == 0, "the renderer must be skipped for an active block")
    }

    // (c) an unsupported language (```python) → normal code block, renderer NOT called.
    @Test("an unsupported-language code block stays a code block and never calls the renderer")
    func unsupportedLanguageIsNotRendered() {
        _ = NSApplication.shared
        let renderer = MockDiagramRenderer()
        var configuration = MarkdownEditorConfiguration.default   // diagramLanguages == ["mermaid"]
        configuration.services = services(diagram: renderer)

        let text = "```python\nprint(1)\n```\n"
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )

        #expect(!attrs.contains { $0.attributes[.renderedBlockImage] is NSImage })
        #expect(renderer.callCount == 0, "python is not a diagram language → never a render candidate")
        #expect(!renderer.renderedLanguages.contains("python"))
    }

    // (c′) a configured language the renderer declines (nil) → falls back to code block.
    @Test("a configured diagram language the renderer declines falls back to a code block")
    func declinedDiagramFallsBackToCode() {
        _ = NSApplication.shared
        let renderer = MockDiagramRenderer()   // renders only "mermaid"; declines "pie"
        var configuration = MarkdownEditorConfiguration.default
        configuration.diagramLanguages = ["mermaid", "pie"]
        configuration.services = services(diagram: renderer)

        let text = "```pie\ntitle Pets\nDogs: 3\n```\n"
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )

        #expect(renderer.callCount == 1, "a configured language IS a candidate → the renderer is asked once")
        #expect(renderer.renderedLanguages == ["pie"])
        #expect(!attrs.contains { $0.attributes[.renderedBlockImage] is NSImage },
                "a nil render → no image, the block stays ordinary code (never lie, show the source)")
    }

    // (d) render-call count is bounded: scoped, not one call per paragraph.
    @Test("rendering is scoped to the diagram token, not rescanned per paragraph")
    func renderCountIsBounded() {
        _ = NSApplication.shared
        let renderer = MockDiagramRenderer()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = services(diagram: renderer)

        let prose = (0..<30).map { "Prose paragraph \($0) with enough words to be its own block." }
            .joined(separator: "\n\n")
        let text = prose + "\n\n```mermaid\ngraph TD\nA-->B\n```\n\n" + prose

        // Full-document pass: exactly one render for the one diagram block,
        // regardless of the 60 surrounding prose paragraphs.
        _ = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )
        #expect(renderer.callCount == 1, "one diagram block ⇒ one render, not one-per-paragraph")

        // A scoped restyle whose paragraphs don't touch the diagram must not
        // render it at all (per-keystroke restyles stay O(edit)).
        let scoped = MockDiagramRenderer()
        var scopedConfig = MarkdownEditorConfiguration.default
        scopedConfig.services = services(diagram: scoped)
        _ = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [],
            scopedRanges: [NSRange(location: 0, length: 5)], configuration: scopedConfig
        )
        #expect(scoped.callCount == 0, "a diagram outside the restyled paragraphs must not render")
    }

    // (e) NoOp renderer → ```mermaid stays a code block.
    @Test("the NoOp renderer leaves a mermaid block as an ordinary code block")
    func noOpRendererKeepsCodeBlock() {
        _ = NSApplication.shared
        let configuration = MarkdownEditorConfiguration.default   // diagram == NoOpBlockDiagramRenderer

        let text = "```mermaid\ngraph TD\nA-->B\n```\n"
        let attrs = MarkdownStyler.styleAttributes(
            text: text, fontName: fontName, fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration
        )
        #expect(!attrs.contains { $0.attributes[.renderedBlockImage] is NSImage })
    }

    // The shared viewport-anchor predicate — the load-bearing gate that makes a
    // mermaid code block reveal/collapse anchor the viewport like block math.
    @Test("isHeightBanded treats a mermaid code block as banded, a plain code block not")
    func heightBandedPredicate() {
        let mermaidText = "```mermaid\nA-->B\n```"
        let mermaidCB = MarkdownTokenizer.parseTokensViaAST(in: mermaidText).first { $0.kind == .codeBlock }
        let mermaid = try! #require(mermaidCB)
        #expect(MarkdownTokenKind.isHeightBanded(mermaid, in: mermaidText, diagramLanguages: ["mermaid"]))
        #expect(!MarkdownTokenKind.isHeightBanded(mermaid, in: mermaidText, diagramLanguages: []),
                "empty diagram-language set ⇒ no code block is banded")

        let pyText = "```python\nprint(1)\n```"
        let pyCB = MarkdownTokenizer.parseTokensViaAST(in: pyText).first { $0.kind == .codeBlock }
        #expect(!MarkdownTokenKind.isHeightBanded(try! #require(pyCB), in: pyText, diagramLanguages: ["mermaid"]))

        // A table is banded by KIND regardless of diagram languages.
        let tableText = "A | B\n--- | ---\n1 | 2\n"
        let tableTok = MarkdownTokenizer.parseTokensViaAST(in: tableText).first { $0.kind == .table }
        #expect(MarkdownTokenKind.isHeightBanded(try! #require(tableTok), in: tableText, diagramLanguages: []))
    }

    // The info-string is `language {metadata}`; only the first word is the
    // language, and the configured language set is case-normalized. Both hardened
    // the classification so a ` ```Mermaid {theme: dark} ` fence still resolves.
    @Test("info-string language is the first word; configured language casing is normalized")
    func infoStringFirstWordAndCasing() {
        let text = "```mermaid {theme: dark}\ngraph TD\nA-->B\n```"
        let token = try! #require(MarkdownTokenizer.parseTokensViaAST(in: text).first { $0.kind == .codeBlock })
        #expect(MarkdownTokenizer.extractLanguage(from: token, in: text) == "mermaid",
                "the language is the first info-string word, not the whole string")
        #expect(MarkdownTokenKind.isHeightBanded(token, in: text, diagramLanguages: ["mermaid"]),
                "a mermaid fence with trailing metadata still classifies as a diagram")

        // A host may configure any casing; the set is lowercased on assignment.
        var configuration = MarkdownEditorConfiguration.default
        configuration.diagramLanguages = ["Mermaid", "PlantUML"]
        #expect(configuration.diagramLanguages == ["mermaid", "plantuml"])
    }
}

// MARK: - Viewport anchoring (end-to-end)

@MainActor
@Suite("Mermaid viewport anchoring", .serialized)
struct MermaidViewportAnchorTests {
    typealias H = TableOverlayEndToEndTests

    static let pinMarker = "PINPOINT-UNIQUE-MERMAID"

    static let doc: String = {
        var lines: [String] = ["# Mermaid anchor fixture", ""]
        lines += (0..<6).map { "Intro prose line \($0) with steady text to fill space." }
        lines.append("")
        lines.append("```mermaid")
        lines.append("graph TD")
        lines.append("  A[Start] --> B[Middle]")
        lines.append("  B --> C[End]")
        lines.append("```")
        lines.append("")
        lines += (0..<8).map { "Middle prose line \($0) sits between the diagram and the pin." }
        lines.append("")
        lines.append(pinMarker)
        lines += (0..<40).map { "Tail prose line \($0) keeps the document scrollable." }
        return lines.joined(separator: "\n")
    }()

    /// A tall fixed image so collapsing the diagram (image) vs revealing its
    /// short source is a big height delta above the pin — the same reveal/collapse
    /// stress the table-anchor test applies, in the opposite direction.
    private func renderer() -> MockDiagramRenderer {
        MockDiagramRenderer(imageSize: CGSize(width: 300, height: 520))
    }

    private func configuration(_ diagram: any BlockDiagramRenderer) -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.readingWidth = 700
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 0)
        configuration.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
        configuration.services.diagram = diagram
        return configuration
    }

    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    private func mount(_ diagram: any BlockDiagramRenderer) async -> (NSWindow, NativeTextView, NativeTextViewCoordinator)? {
        _ = NSApplication.shared
        let host = H.Host(text: Self.doc)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: configuration(diagram)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting),
              let coordinator = tv.delegate as? NativeTextViewCoordinator else { return nil }
        return (window, tv, coordinator)
    }

    private func documentY(of location: Int, _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) -> CGFloat? {
        guard let bridge = coordinator.layoutBridge,
              let container = bridge.firstTextContainer else { return nil }
        let rect = bridge.boundingRect(forCharacterRange: NSRange(location: location, length: 1), in: container)
        guard rect.height >= 0.01 else { return nil }
        return rect.minY + tv.textContainerOrigin.y
    }

    private func pinViewportY(_ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) -> CGFloat? {
        let ns = tv.string as NSString
        let range = ns.range(of: Self.pinMarker)
        guard range.location != NSNotFound,
              let docY = documentY(of: range.location, tv, coordinator) else { return nil }
        return docY - tv.visibleRect.minY
    }

    private func scrollTo(location: Int, _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator) {
        guard let docY = documentY(of: location, tv, coordinator),
              let scrollView = tv.enclosingScrollView else { return }
        let delta = (docY - 300) - tv.visibleRect.minY
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clip)
    }

    private func fireSelectionChange(_ coordinator: NativeTextViewCoordinator, _ tv: NativeTextView) {
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: tv)
        )
    }

    @Test("collapsing a revealed mermaid diagram above the caret does not move the visible content")
    func collapseMermaidKeepsViewportStable() async throws {
        let (window, tv, coordinator) = try #require(await mount(renderer()))
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString

        // Reveal: caret into the diagram source (the click-into-diagram state).
        let graphLoc = ns.range(of: "graph TD").location
        #expect(graphLoc != NSNotFound)
        tv.setSelectedRange(NSRange(location: graphLoc + 2, length: 0))
        fireSelectionChange(coordinator, tv)
        await settle()

        // Scroll so the pin (prose below the diagram) is visible.
        let pinRange = ns.range(of: Self.pinMarker)
        scrollTo(location: pinRange.location, tv, coordinator)
        await settle(2)
        let before = try #require(pinViewportY(tv, coordinator))

        // Click OUT: caret onto the pin line — the diagram above COLLAPSES back
        // to its tall image (hundreds of points ADDED above the caret). Without
        // the anchor the pin would leap down by that delta; it must stay put.
        tv.setSelectedRange(NSRange(location: pinRange.location, length: 0))
        fireSelectionChange(coordinator, tv)
        let after = try #require(pinViewportY(tv, coordinator))
        #expect(abs(after - before) < 8,
                "collapsing the diagram above the caret moved the view by \(after - before)pt")

        await settle()
        let settled = try #require(pinViewportY(tv, coordinator))
        #expect(abs(settled - before) < 8, "view drifted after settling: \(settled - before)pt")
    }

    @Test("revealing a collapsed mermaid diagram above the caret does not move the visible content")
    func revealMermaidKeepsViewportStable() async throws {
        let (window, tv, coordinator) = try #require(await mount(renderer()))
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString

        // Start COLLAPSED: caret on the pin line, so the diagram above shows its
        // tall image (the resting state a reader scrolls through).
        let pinRange = ns.range(of: Self.pinMarker)
        #expect(pinRange.location != NSNotFound)
        tv.setSelectedRange(NSRange(location: pinRange.location, length: 0))
        fireSelectionChange(coordinator, tv)
        await settle()

        // Scroll so the pin (prose below the collapsed diagram) is visible.
        scrollTo(location: pinRange.location, tv, coordinator)
        await settle(2)
        let before = try #require(pinViewportY(tv, coordinator))

        // Click IN: caret into the diagram source — it REVEALS its short source
        // (hundreds of points REMOVED above the caret as the tall image goes away).
        // This is the inactive→active reveal direction, the load-bearing half of
        // this engine's jump history: without the anchor the pin would leap UP by
        // that delta; it must stay put.
        let graphLoc = ns.range(of: "graph TD").location
        #expect(graphLoc != NSNotFound)
        tv.setSelectedRange(NSRange(location: graphLoc + 2, length: 0))
        fireSelectionChange(coordinator, tv)
        let after = try #require(pinViewportY(tv, coordinator))
        #expect(abs(after - before) < 8,
                "revealing the diagram above the caret moved the view by \(after - before)pt")

        await settle()
        let settled = try #require(pinViewportY(tv, coordinator))
        #expect(abs(settled - before) < 8, "view drifted after settling: \(settled - before)pt")
    }
}
