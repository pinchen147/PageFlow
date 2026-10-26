//
//  SwiftMathBridgeTests.swift
//  MarkdownEngineLatexTests
//
//  SwiftMath asserts (Debug) or drops spacing (Release) when a binary operator
//  is left unnormalized after a relation, open, punctuation or operator atom —
//  TeX Appendix G rules 5/6 — in lists its own finalize never visits, or
//  across spacing atoms it looks through. These formulas come from the owner's
//  notes; each one crashed a Debug build before the bridge normalized the list.
//

import AppKit
import Testing
import SwiftMath
@testable import MarkdownEngineLatex
import MarkdownEngine

@Suite("SwiftMath bridge normalization")
struct SwiftMathBridgeTests {

    private static let formulas = [
        #"y \;=\; -x"#,                                                  // relation, space, binary
        #"\frac{\partial\,\mathrm{ITA}}{\partial b^*} \;=\; -\frac{L^*-50}{(L^*-50)^2 + b^{*2}}\cdot\frac{180}{\pi}"#,
        #"\begin{aligned} a &= -1 \\ b &= +2 \end{aligned}"#,           // table cells
        #"\overline{-x} + \underline{-y}"#,                              // over/underline bodies
        #"\hat{-x}"#,                                                    // accent body
        #"L^* \cdot (-1)"#,                                              // script that is only an operator
        #"\left( -a \right) \times -b"#,                                 // inner list + operator pair
    ]

    @MainActor
    @Test("every owner formula renders without tripping SwiftMath's spacing assertion")
    func rendersOwnerFormulas() {
        _ = NSApplication.shared
        let bridge = SwiftMathBridge()
        for formula in Self.formulas {
            let result = bridge.render(latex: formula, fontSize: 17, theme: .default)
            #expect(result != nil, "no render for \(formula)")
            #expect((result?.size.width ?? 0) > 0)
        }
    }

    @Test("normalization demotes binary operators exactly where TeX does, looking through spaces")
    func normalizesThroughSpacingAtoms() throws {
        let list = try #require(MTMathListBuilder.build(fromString: #"a \;=\; -b - c"#))
        SwiftMathBridge.normalizeBinaryOperators(in: list)
        let types = list.atoms.map(\.type)
        // a, space, =, space, -(unary), b, -(binary), c
        #expect(types == [.variable, .space, .relation, .space, .unaryOperator, .variable, .binaryOperator, .variable])
    }
}
