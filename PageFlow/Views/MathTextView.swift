//
//  MathTextView.swift
//  PageFlow
//
//  Renders comment text with mixed plain text and LaTeX math expressions
//

import SwiftUI
import SwiftMath

struct MathTextView: View {
    let text: String
    let fontSize: CGFloat
    let maxWidth: CGFloat

    init(text: String, fontSize: CGFloat = DesignTokens.commentFontSize, maxWidth: CGFloat = 160) {
        self.text = text
        self.fontSize = fontSize
        self.maxWidth = maxWidth
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
            .foregroundStyle(DesignTokens.commentTextColor.opacity(DesignTokens.commentTextOpacity))
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
                maxWidth: maxWidth
            )

        case .display(let latex):
            MathOrFallbackView(
                latex: latex,
                delimiter: "$$",
                fontSize: fontSize,
                mode: .display,
                maxWidth: maxWidth
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

    @State private var hasError = false

    var body: some View {
        if hasError {
            Text("\(delimiter)\(latex)\(delimiter)")
                .font(.system(size: fontSize))
                .foregroundStyle(DesignTokens.commentTextColor.opacity(DesignTokens.commentTextOpacity))
        } else {
            MathLabelView(latex: latex, fontSize: fontSize, mode: mode, maxWidth: maxWidth) { error in
                DispatchQueue.main.async {
                    hasError = error
                }
            }
        }
    }
}
