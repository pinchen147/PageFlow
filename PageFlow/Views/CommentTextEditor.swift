//
//  CommentTextEditor.swift
//  PageFlow
//
//  AppKit text editor adapter used by editable comment bubbles.
//

import SwiftUI
import AppKit

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @FocusState var isFocused: Bool
    @Binding var calculatedHeight: CGFloat
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CommentTextView()

        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = NSFont.systemFont(ofSize: DesignTokens.commentFontSize)
        textView.textColor = DesignTokens.commentTextNSColor.withAlphaComponent(0.9)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 2)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommentTextView else { return }

        context.coordinator.onTextChange = { [weak scrollView] newText in
            guard scrollView != nil else { return }
            text = newText
        }
        context.coordinator.onHeightChange = { [weak scrollView] newHeight in
            guard scrollView != nil else { return }
            calculatedHeight = newHeight
        }

        if textView.string != text {
            textView.string = text
        }

        textView.textColor = DesignTokens.commentTextNSColor.withAlphaComponent(0.9)
        textView.onCommit = onCommit

        if isFocused && scrollView.window?.firstResponder != textView {
            scrollView.window?.makeFirstResponder(textView)
        }

        if let textContainer = textView.textContainer,
           let layoutManager = textView.layoutManager {
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let newHeight = max(usedHeight + 4, 20)
            if calculatedHeight != newHeight {
                DispatchQueue.main.async {
                    calculatedHeight = newHeight
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            onTextChange?(textView.string)

            if let textContainer = textView.textContainer,
               let layoutManager = textView.layoutManager {
                let usedHeight = layoutManager.usedRect(for: textContainer).height
                onHeightChange?(max(usedHeight + 4, 20))
            }
        }
    }
}

final class CommentTextView: NSTextView {
    var onCommit: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShiftPressed = event.modifierFlags.contains(.shift)

        if isReturn && !isShiftPressed {
            onCommit()
        } else if isReturn && isShiftPressed {
            insertNewline(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
