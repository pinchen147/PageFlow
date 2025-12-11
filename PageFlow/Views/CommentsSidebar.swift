//
//  CommentsSidebar.swift
//  PageFlow
//
//  Right sidebar displaying comments as speech bubbles with glassmorphism
//

import SwiftUI
import AppKit

struct CommentsSidebar: View {
    @Bindable var commentManager: CommentManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            commentsList
        }
        .frame(width: DesignTokens.commentSidebarWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                .strokeBorder(.white.opacity(0.22))
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Comments")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            sidebarCloseButton
        }
        .padding(.leading, DesignTokens.spacingMD)
        .padding(.trailing, DesignTokens.spacingSM)
        .padding(.top, DesignTokens.spacingSM)
    }

    private var sidebarCloseButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
        .contentShape(Rectangle())
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    // MARK: - Comments List

    private var commentsList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.spacingSM) {
                if commentManager.comments.isEmpty {
                    emptyState
                } else {
                    ForEach(commentManager.comments.sorted { $0.createdAt < $1.createdAt }) { comment in
                        CommentBubbleView(
                            comment: comment,
                            isSelected: commentManager.selectedCommentID == comment.id,
                            isEditing: commentManager.editingCommentID == comment.id,
                            onSelect: { commentManager.selectComment(comment.id) },
                            onStartEditing: { commentManager.startEditing(comment.id) },
                            onTextChange: { commentManager.updateComment(comment.id, text: $0) },
                            onStopEditing: { commentManager.stopEditing() },
                            onDelete: { commentManager.deleteComment(comment.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, DesignTokens.spacingSM)
            .padding(.bottom, DesignTokens.spacingMD)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.4))
            Text("No comments yet")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text("Select text and press ⌘E")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacingXL)
    }

}

// MARK: - Comment Bubble

struct CommentBubbleView: View {
    let comment: CommentModel
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onTextChange: (String) -> Void
    let onStopEditing: () -> Void
    let onDelete: () -> Void

    @State private var editText: String = ""
    @FocusState private var isFocused: Bool
    @State private var editorHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            pageLabel
            bubbleContent
        }
        .onAppear { editText = comment.text }
        .onChange(of: isEditing) { _, editing in
            if editing {
                editText = comment.text
                isFocused = true
            }
        }
    }

    private var pageLabel: some View {
        Button(action: onSelect) {
            Text("Page \(comment.pageIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.leading, DesignTokens.commentTailSize + DesignTokens.spacingXS)
        .contentShape(Rectangle())
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    private var bubbleContent: some View {
        HStack(alignment: .top, spacing: 0) {
            bubbleTail
            bubbleBody
        }
    }

    private var bubbleTail: some View {
        BubbleTail()
            .fill(.white.opacity(0.08))
            .frame(width: DesignTokens.commentTailSize, height: DesignTokens.commentTailSize * 2)
            .padding(.top, DesignTokens.spacingSM)
    }

    private var bubbleBody: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .center, spacing: DesignTokens.spacingSM) {
                contentArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: DesignTokens.spacingXS)
            }
            .padding(.horizontal, DesignTokens.spacingSM)
            .padding(.vertical, DesignTokens.spacingXS)
            .frame(minHeight: DesignTokens.tabHeight)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius))
            .overlay(bubbleBorder)
            .contentShape(Rectangle())
            .onTapGesture { onStartEditing() }
            .onHover { hovering in
                if !isEditing {
                    (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
            .contextMenu { contextMenuItems }

            bubbleCloseButton
                .padding(.top, DesignTokens.spacingXS)
                .padding(.trailing, DesignTokens.spacingXS)
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if isEditing {
            editableText
        } else {
            displayText
        }
    }

    private var bubbleCloseButton: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
        .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

        private var editableText: some View {
            ZStack(alignment: .leading) {
                if editText.isEmpty {
                    Text("Add a comment...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .italic()
                        .allowsHitTesting(false)
                }

                CustomTextEditor(
                    text: $editText,
                    isFocused: _isFocused,
                    calculatedHeight: $editorHeight,
                    onCommit: { onStopEditing() }
                )
                .frame(minHeight: editorHeight, alignment: .topLeading)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: editText) { _, newValue in
                onTextChange(newValue)
            }
        }

        private var displayText: some View {
            Text(comment.text.isEmpty ? "Add a comment..." : comment.text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(comment.text.isEmpty ? 0.4 : 0.85))
                .italic(comment.text.isEmpty)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
        }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
            .fill(.white.opacity(isSelected ? 0.12 : 0.08))
    }

    private var bubbleBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
            .strokeBorder(.white.opacity(isSelected ? 0.25 : 0.12))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit") { onStartEditing() }
        Button("Go to Page") { onSelect() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}

// MARK: - Custom Text Editor

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
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = NSColor.white.withAlphaComponent(0.9)
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

        if textView.string != text {
            textView.string = text
        }

        textView.onCommit = onCommit

        if isFocused && scrollView.window?.firstResponder != textView {
            scrollView.window?.makeFirstResponder(textView)
        }

        let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        calculatedHeight = max(usedHeight + 4, 20)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            let usedHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
            parent.calculatedHeight = max(usedHeight + 4, 20)
        }

    }
}

// MARK: - Comment Text View

class CommentTextView: NSTextView {
    var onCommit: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36
        let isShiftPressed = event.modifierFlags.contains(.shift)

        if isReturn && !isShiftPressed {
            // Enter without Shift: commit and exit editing
            onCommit()
        } else if isReturn && isShiftPressed {
            // Shift+Enter: insert newline
            insertNewline(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Bubble Tail Shape

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
