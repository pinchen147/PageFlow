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
    let fieldLabel: String
    var onCommit: () -> Void = {}
    /// Takes the keyboard on opening, however late the window arrives.
    var takesFocusOnAppear = false
    var annotationOwner: AnyObject?
    /// EPUB supplies its book colors; omitted inputs keep PDF's native defaults.
    var textColor: NSColor? = nil
    var colorScheme: ColorScheme? = nil
    /// An explicit Edit request, independent of appearance-only updates.
    var focusRevision: Int? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CommentTextView()
        textView.takesFocusOnAppear = takesFocusOnAppear
        textView.annotationOwner = annotationOwner

        textView.delegate = context.coordinator
        textView.onCommit = onCommit
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: DesignTokens.commentFontSize)
        textView.textColor = (textColor ?? DesignTokens.commentTextNSColor).withAlphaComponent(0.9)
        configureBookAppearance(textView)
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

        textView.setAccessibilityLabel(fieldLabel)
        textView.annotationOwner = annotationOwner
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
            // The typing history's ranges are for the text it replaced.
            context.coordinator.undoManager.removeAllActions()
        }

        textView.textColor = (textColor ?? DesignTokens.commentTextNSColor).withAlphaComponent(0.9)
        configureBookAppearance(textView)
        textView.onCommit = onCommit

        let requestsFocus = focusRevision.map { context.coordinator.lastFocusRevision != $0 } ?? isFocused
        if requestsFocus, let window = scrollView.window {
            if window.firstResponder !== textView { window.makeFirstResponder(textView) }
            context.coordinator.lastFocusRevision = focusRevision
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

    private func configureBookAppearance(_ textView: CommentTextView) {
        guard let colorScheme, let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) else { return }
        if textView.appearance?.name != appearance.name { textView.appearance = appearance }
        textView.insertionPointColor = (textColor ?? DesignTokens.commentTextNSColor).withAlphaComponent(0.9)
        appearance.performAsCurrentDrawingAppearance {
            textView.selectedTextAttributes = [
                .foregroundColor: NSColor.selectedTextColor.usingColorSpace(.sRGB) ?? .selectedTextColor,
                .backgroundColor: NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? .selectedTextBackgroundColor
            ]
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastFocusRevision: Int?
        var onTextChange: ((String) -> Void)?
        var onHeightChange: ((CGFloat) -> Void)?
        /// The typing in this comment, undone in the field. Its own stack: the
        /// window's would outlive the editor and carry over to the next comment.
        let undoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

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
    weak var annotationOwner: AnyObject?

    static func owns(_ responder: NSResponder?, owner: AnyObject) -> Bool {
        guard let editor = responder as? CommentTextView, editor.isEditable,
              let window = editor.window, window.firstResponder === editor else { return false }
        return editor.annotationOwner === owner
    }

    var onCommit: () -> Void = {}
    var takesFocusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocusOnAppear, let window else { return }
        takesFocusOnAppear = false
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Return during an input method's composition is the composition's.
        guard !hasMarkedText() else { return super.keyDown(with: event) }
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
