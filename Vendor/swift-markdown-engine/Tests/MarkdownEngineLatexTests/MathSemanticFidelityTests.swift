import AppKit
import MarkdownEngine
import SwiftMath
import Testing
@testable import MarkdownEngineLatex

@Suite("Math semantic fidelity")
struct MathSemanticFidelityTests {
    @Test("negated equality stays a not-equal relation", arguments: [
        #"a \not= b"#,
        #"a \not = b"#,
        "a \\not\n= b",
    ])
    func negatedEqualityKeepsItsMeaning(_ formula: String) throws {
        let list = try #require(SwiftMathBridge.parse(formula))
        #expect(list.atoms.filter { $0.type == .relation }.map(\.nucleus) == ["≠"])
    }

    @Test("negated membership stays a not-in relation", arguments: [
        #"c \not\in D"#,
        #"c \not \in D"#,
        "c \\not\t\\in D",
    ])
    func negatedMembershipKeepsItsMeaning(_ formula: String) throws {
        let list = try #require(SwiftMathBridge.parse(formula))
        #expect(list.atoms.filter { $0.type == .relation }.map(\.nucleus) == ["∉"])
    }

    @Test("entailment renders as its relation symbol")
    func entailmentKeepsItsMeaning() throws {
        let list = try #require(SwiftMathBridge.parse(#"P \vdash Q"#))
        #expect(list.atoms.filter { $0.type == .relation }.map(\.nucleus) == ["⊢"])
    }

    @MainActor
    @Test("unsupported semantic commands request readable source fallback", arguments: [
        #"\cancel{x}"#,
        #"\bcancel{x}"#,
        #"\xcancel{x+y}"#,
        #"\sout{x}"#,
        #"\frac{1}{\cancel{x}}"#,
        #"A \not\subseteq B"#,
        #"a \not\approx b"#,
        #"a \not\infty"#,
        #"a \unknownrelation b"#,
        #"\newcommand{\vv}{\mathbf{v}} \vv + 1"#,
    ])
    func unsupportedCommandsFallBack(_ formula: String) {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        #expect(bridge.render(latex: formula, fontSize: 17, theme: .default) == nil)
    }

    @MainActor
    @Test("supported formulas remain renderable", arguments: [
        #"a \neq b"#,
        #"a \ne b"#,
        #"c \notin D"#,
        #"\neg p"#,
        #"\boxed{\frac{a}{b}}"#,
        #"\begin{matrix}a\\not= b\end{matrix}"#,
    ])
    func supportedFormulasStillRender(_ formula: String) throws {
        _ = NSApplication.shared
        let result = try #require(SwiftMathBridge().render(latex: formula, fontSize: 17, theme: .default))
        #expect(result.size.width > 0 && result.size.height > 0)
    }
}
