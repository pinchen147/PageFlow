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
        .pageFlowLiquidGlassPanel(
            cornerRadius: DesignTokens.floatingToolbarCornerRadius,
            tint: .light,
            tintOpacity: DesignTokens.sidebarGlassTintOpacity,
            variant: .clear,
            strokeOpacity: 0.22,
            shadowRadius: 4,
            shadowY: -2
        )
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
                .foregroundStyle(DesignTokens.sidebarTertiaryText)
            Text("No comments yet")
                .font(.caption)
                .foregroundStyle(DesignTokens.sidebarSecondaryText)
            Text("Select text and press ⌘E")
                .font(.caption2)
                .foregroundStyle(DesignTokens.sidebarTertiaryText)
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
            .fill(Color.white.opacity(isSelected ? DesignTokens.commentBubbleBackgroundSelected : DesignTokens.commentBubbleBackground))
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
            .pageFlowGlassControlLabel()
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isSelected ? DesignTokens.commentBubbleBackgroundSelected : DesignTokens.commentBubbleBackground))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.30 : 0.18), lineWidth: 1)
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
