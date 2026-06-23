//
//  CommentsSidebar.swift
//  PageFlow
//
//  Right sidebar displaying comments as speech bubbles.
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
        .pageFlowLiquidGlassPanel(.sidebar)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Comments")
                .font(.headline)
                .pageFlowGlassControlLabel()
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
                .foregroundStyle(DesignTokens.sidebarSecondaryText)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .pageFlowGlassControlLabel()
        }
        .buttonStyle(.plain)
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
                    ForEach(commentManager.sortedComments) { comment in
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
                .foregroundStyle(DesignTokens.sidebarTertiaryText)
                .pageFlowGlassTextHalo()
            Text("No comments yet")
                .font(.caption)
                .foregroundStyle(DesignTokens.sidebarSecondaryText)
                .pageFlowGlassTextHalo()
            Text("Select text and press ⌘E")
                .font(.caption2)
                .foregroundStyle(DesignTokens.sidebarTertiaryText)
                .pageFlowGlassTextHalo()
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
    @State private var isViewActive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            pageLabel
            bubbleContent
        }
        .onAppear {
            isViewActive = true
            editText = comment.text
        }
        .onDisappear {
            isViewActive = false
        }
        .onChange(of: isEditing) { _, editing in
            guard isViewActive else { return }
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
                .foregroundStyle(DesignTokens.sidebarSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.spacingXS)
                .padding(.vertical, 2)
                .pageFlowGlassControlLabel()
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
            .fill(DesignTokens.commentCardBackground)
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
            .shadow(color: .black.opacity(DesignTokens.commentBubbleShadowOpacity), radius: DesignTokens.commentBubbleShadowRadius, y: 2)
            .contentShape(Rectangle())
            // Single click jumps to the comment on its page; double click edits.
            // Uses AppKit click recognizers (single requires double to fail) instead of
            // SwiftUI TapGesture(count:)/.exclusively, which composed unreliably here —
            // a double-click registered as separate single clicks, so editing needed a
            // third click. Absent while editing so clicks reach the text editor.
            .background {
                if !isEditing {
                    ClickCatcher(onSingleClick: onSelect, onDoubleClick: onStartEditing)
                }
            }
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
                .foregroundStyle(DesignTokens.sidebarSecondaryText)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .pageFlowGlassControlLabel()
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

        private var editableText: some View {
            ZStack(alignment: .leading) {
                if editText.isEmpty {
                    Text("Add a comment...")
                        .font(.system(size: DesignTokens.commentFontSize))
                        .foregroundStyle(DesignTokens.sidebarTertiaryText)
                        .italic()
                        .allowsHitTesting(false)
                }

                CustomTextEditor(
                    text: $editText,
                    isFocused: _isFocused,
                    calculatedHeight: $editorHeight,
                    onCommit: { [onStopEditing] in
                        onStopEditing()
                    }
                )
                .frame(minHeight: editorHeight, alignment: .topLeading)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: editText) { _, newValue in
                guard isViewActive else { return }
                onTextChange(newValue)
            }
        }

        private var displayText: some View {
            Group {
                if comment.text.isEmpty {
                    Text("Add a comment...")
                        .font(.system(size: DesignTokens.commentFontSize))
                        .foregroundStyle(DesignTokens.sidebarTertiaryText)
                        .italic()
                } else {
                    MathTextView(text: comment.text)
                }
            }
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
            .fill(DesignTokens.commentCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? DesignTokens.commentCardStrokeSelected : DesignTokens.commentCardStroke,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit") { onStartEditing() }
        Button("Go to Page") { onSelect() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}

// MARK: - Click Catcher

/// Deterministic single- vs double-click discrimination via AppKit. SwiftUI's
/// `TapGesture(count:)` + `.exclusively` compose unreliably on macOS — a double-click
/// can register as separate single clicks, so editing a comment needed a third click.
/// `NSClickGestureRecognizer` with `require(toFail:)` gives a clean either/or: the
/// single fires only if the double fails. Sits in the bubble's background, so the
/// (non-interactive) text content's clicks fall through to it while the close button
/// and context menu layered in front keep working; it's omitted while editing so the
/// text editor receives clicks directly.
private struct ClickCatcher: NSViewRepresentable {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let single = NSClickGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleSingle))
        single.numberOfClicksRequired = 1
        single.delegate = context.coordinator
        let double = NSClickGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleDouble))
        double.numberOfClicksRequired = 2
        double.delegate = context.coordinator
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSingle = onSingleClick
        context.coordinator.onDouble = onDoubleClick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSingleClick, onDoubleClick) }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var onSingle: () -> Void
        var onDouble: () -> Void
        init(_ onSingle: @escaping () -> Void, _ onDouble: @escaping () -> Void) {
            self.onSingle = onSingle
            self.onDouble = onDouble
        }
        @objc func handleSingle() { onSingle() }
        @objc func handleDouble() { onDouble() }

        // AppKit has no require(toFail:); express it via the delegate so the 1-click
        // recognizer only succeeds once the 2-click recognizer has failed. A clean
        // double-click then fires the double handler alone (no stray single).
        func gestureRecognizer(_ recognizer: NSGestureRecognizer,
                               shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
            guard let recognizer = recognizer as? NSClickGestureRecognizer,
                  let other = other as? NSClickGestureRecognizer else { return false }
            return recognizer.numberOfClicksRequired == 1 && other.numberOfClicksRequired == 2
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
