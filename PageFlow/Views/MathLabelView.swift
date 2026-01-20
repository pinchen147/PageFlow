//
//  MathLabelView.swift
//  PageFlow
//
//  SwiftUI wrapper for MTMathUILabel to render LaTeX math expressions
//

import SwiftUI
import SwiftMath

struct MathLabelView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let mode: MTMathUILabelMode
    let maxWidth: CGFloat
    var onError: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.displayErrorInline = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        view.latex = latex
        view.font = MTFontManager.manager.latinModernFont(withSize: fontSize)
        view.labelMode = mode
        view.textColor = DesignTokens.commentTextNSColor.withAlphaComponent(DesignTokens.commentTextOpacity)
        view.textAlignment = mode == .display ? .center : .left
        view.invalidateIntrinsicContentSize()

        // Report parse errors to caller
        onError?(view.error != nil)
    }
}
