//
//  EPUBMathTypesetting.swift
//  PageFlow
//
//  Book formulas (MathML, converted to LaTeX by EPUBKit) typeset with
//  SwiftMath, the engine Markdown notes use.
//

import EPUBKit
import Foundation
import MarkdownEngineLatex

nonisolated struct EPUBSwiftMathTypesetter: EPUBMathTypesetter {
    /// Gives EPUBKit this typesetter, once, before the first chapter renders.
    static let installed: Void = { EPUBMath.typesetter = EPUBSwiftMathTypesetter() }()

    func typeset(_ formulas: [EPUBMathFormula]) -> [EPUBMathLayout?] {
        // SwiftMath lays out through a view, so on the main thread: one hop
        // per chapter. Drawing the result needs no view.
        EPUBMainThreadRelay.sync { Self.layouts(formulas) }
    }

    @MainActor private static func layouts(_ formulas: [EPUBMathFormula]) -> [EPUBMathLayout?] {
        formulas.map { formula in
            for source in formula.sources {
                guard let typeset = LatexTypeset.make(source, fontSize: EPUBMath.referenceSize,
                                                      displayStyle: formula.isDisplay) else { continue }
                return EPUBMathLayout(size: CGSize(width: typeset.width, height: typeset.height),
                                      descent: typeset.descent) { context, color in
                    typeset.draw(in: context, color: color)
                }
            }
            return nil
        }
    }
}
