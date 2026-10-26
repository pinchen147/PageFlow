//
//  ComplexDiagramTests.swift
//  MarkdownEngineMermaidTests
//
//  A real-world stress diagram (subgraph, classDef/class, <br/> labels, dotted
//  `-.->` edges, edge labels, decision `{}` nodes) — the kind a user actually
//  pastes. Proves BeautifulMermaid handles it AND that it collapses end-to-end
//  through the styling pass, guarding against a regression where a complex
//  diagram silently falls back to source.
//

import AppKit
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineMermaid

@MainActor
@Suite("Complex real-world diagram")
struct ComplexDiagramTests {

    /// Uses the feature set that commonly trips native Mermaid renderers.
    static let source = """
    flowchart TB
        P["Observed price of X"]
        P --> D["DECOMPOSE<br/>Price = Material floor + Transformation cost"]
        D --> F["MATERIAL FLOOR<br/>bill of materials at market prices"]
        D --> G["GAP ABOVE FLOOR<br/>energy, labor, capital, knowledge, rent"]
        subgraph FLOOR ["Recurse the floor until it stops moving"]
            F --> R{"Absolute floor,<br/>or just today's input price?"}
            R -->|conditional| RC["Input price is itself<br/>floor + gap. Recurse."]
            RC -.-> F
            R -->|absolute| ABS["Bottoms out at minimum work"]
            ABS --> IMM["Immovable."]
            ABS --> SUB["Only escape: SUBSTITUTION"]
        end
        classDef floorStyle fill:#e8eef7,stroke:#4a6fa5,color:#1a2b42
        class F,R,RC,ABS,IMM,SUB floorStyle
    """

    @Test("the complex diagram renders to a non-nil image via the bridge")
    func bridgeRenders() {
        _ = NSApplication.shared
        let result = MermaidBridge().render(source: Self.source, language: "mermaid",
                                            maxWidth: 640, fontSize: 16, theme: .default)
        guard let r = result else {
            Issue.record("complex diagram unexpectedly failed to render (fell back to source)")
            return
        }
        #expect(r.size.width > 0 && r.size.height > 0)
        #expect(r.size.width <= 641)
    }

    @Test("the complex diagram collapses to a block image end-to-end in a ```mermaid fence")
    func collapsesEndToEnd() {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.services.diagram = MermaidBridge()
        let fenced = "# Doc\n\n```mermaid\n" + Self.source + "\n```\n\nAfter.\n"
        let attrs = MarkdownStyler.styleAttributes(
            text: fenced, fontName: "Helvetica", fontSize: 16,
            caretLocation: -1, activeTokenIndices: [], configuration: config
        )
        #expect(attrs.contains { $0.attributes[.renderedBlockImage] is NSImage },
                "a complex fenced diagram must collapse to a block image")
    }
}
