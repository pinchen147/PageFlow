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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.displayErrorInline = false
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: MTMathUILabel, context: Context) {
        var invalidatesIntrinsicSize = false

        if context.coordinator.lastLatex != latex {
            view.latex = latex
            context.coordinator.lastLatex = latex
            invalidatesIntrinsicSize = true
        }

        if context.coordinator.lastFontSize != fontSize {
            view.font = MTFontManager.manager.latinModernFont(withSize: fontSize)
            context.coordinator.lastFontSize = fontSize
            invalidatesIntrinsicSize = true
        }

        if context.coordinator.lastMode != mode {
            view.labelMode = mode
            context.coordinator.lastMode = mode
            invalidatesIntrinsicSize = true
        }

        let textColor = DesignTokens.commentTextNSColor.withAlphaComponent(DesignTokens.commentTextOpacity)
        if view.textColor != textColor {
            view.textColor = textColor
        }

        let isDisplayMode = mode == .display
        if isDisplayMode, view.textAlignment != .center {
            view.textAlignment = .center
        } else if !isDisplayMode, view.textAlignment != .left {
            view.textAlignment = .left
        }

        if invalidatesIntrinsicSize {
            view.invalidateIntrinsicContentSize()
        }

        // Report parse errors to caller
        onError?(view.error != nil)
    }

    final class Coordinator {
        var lastLatex: String?
        var lastFontSize: CGFloat?
        var lastMode: MTMathUILabelMode?
    }
}
