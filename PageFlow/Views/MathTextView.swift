//
//  MathTextView.swift
//  PageFlow
//
//  Renders comment text with mixed plain text and LaTeX math expressions
//

import SwiftUI
import SwiftMath
import MarkdownEngineLatex

struct MathTextView: View {
    let text: String
    let fontSize: CGFloat
    let maxWidth: CGFloat
    let textColor: NSColor?

    init(text: String, fontSize: CGFloat = DesignTokens.commentFontSize, maxWidth: CGFloat = 160,
         textColor: NSColor? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.maxWidth = maxWidth
        self.textColor = textColor
    }

    private var segments: [TextSegment]? {
        MathTextParser.parse(text)
    }

    var body: some View {
        // Fast path: no math delimiters → plain Text (unchanged behavior)
        if let segments = segments {
            mathContent(segments)
        } else {
            plainText
        }
    }

    private var plainText: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle((textColor.map { Color(nsColor: $0) } ?? DesignTokens.commentTextColor).opacity(DesignTokens.commentTextOpacity))
    }

    // MARK: - Content Line Grouping

    private enum ContentLine {
        case inline([TextSegment])  // plain + inlineMath → render as single LaTeX
        case display(String)        // displayMath → centered block
    }

    private func groupIntoLines(_ segments: [TextSegment]) -> [ContentLine] {
        var lines: [ContentLine] = []
        var currentInline: [TextSegment] = []

        for segment in segments {
            switch segment {
            case .displayMath(let latex):
                // Flush any accumulated inline content
                if !currentInline.isEmpty {
                    lines.append(.inline(currentInline))
                    currentInline = []
                }
                lines.append(.display(latex))

            case .plain, .inlineMath:
                currentInline.append(segment)
            }
        }

        // Flush remaining inline content
        if !currentInline.isEmpty {
            lines.append(.inline(currentInline))
        }

        return lines
    }

    // MARK: - Inline to LaTeX Conversion

    private func inlineToLatex(_ segments: [TextSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .plain(let str):
                return "\\text{\(escapeLatex(str))}"
            case .inlineMath(let latex):
                return latex
            case .displayMath:
                return "" // Should never happen
            }
        }.joined()
    }

    private func escapeLatex(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\textbackslash ")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "&", with: "\\&")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Rendering

    @ViewBuilder
    private func mathContent(_ segments: [TextSegment]) -> some View {
        let lines = groupIntoLines(segments)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: ContentLine) -> some View {
        switch line {
        case .inline(let segments):
            MathOrFallbackView(
                latex: inlineToLatex(segments),
                delimiter: "",
                fontSize: fontSize,
                mode: .text,
                maxWidth: maxWidth,
                textColor: textColor
            )

        case .display(let latex):
            MathOrFallbackView(
                latex: latex,
                delimiter: "$$",
                fontSize: fontSize,
                mode: .display,
                maxWidth: maxWidth,
                textColor: textColor
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Math with Fallback

private struct MathOrFallbackView: View {
    let latex: String
    let delimiter: String
    let fontSize: CGFloat
    let mode: MTMathUILabelMode
    let maxWidth: CGFloat
    let textColor: NSColor?

    @State private var hasError = false

    private var nativeText: LatexNativeTextParts {
        LatexNativeText.split(latex)
    }

    var body: some View {
        if hasError || nativeText.requiresSourceFallback {
            Text("\(delimiter)\(latex)\(delimiter)")
                .font(.system(size: fontSize))
                .foregroundStyle((textColor.map { Color(nsColor: $0) } ?? DesignTokens.commentTextColor).opacity(DesignTokens.commentTextOpacity))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: max(4, fontSize * 0.35)) {
                MathLabelView(latex: nativeText.latex, fontSize: fontSize, mode: mode, maxWidth: maxWidth, textColor: textColor) { error in
                    DispatchQueue.main.async {
                        hasError = error
                    }
                }
                ForEach(Array(nativeText.annotations.enumerated()), id: \.offset) { _, annotation in
                    Text(annotation)
                        .font(.system(size: max(11, fontSize * 0.82)))
                        .foregroundStyle((textColor.map { Color(nsColor: $0) } ?? DesignTokens.commentTextColor).opacity(DesignTokens.commentTextOpacity))
                }
            }
        }
    }
}
