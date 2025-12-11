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
            closeButton
        }
        .padding(.horizontal, DesignTokens.spacingMD)
        .padding(.vertical, DesignTokens.spacingSM)
    }

    private var closeButton: some View {
        Button(action: onClose) {
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
        Text("Page \(comment.pageIndex + 1)")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.leading, DesignTokens.spacingXS)
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
            .offset(y: 10)
    }

    private var bubbleBody: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                if isEditing {
                    editableText
                } else {
                    displayText
                }
            }
            .padding(DesignTokens.spacingSM)
            .padding(.trailing, DesignTokens.spacingMD)
            .frame(maxWidth: .infinity, alignment: .leading)

            closeButton
                .padding(.trailing, DesignTokens.spacingXS)
        }
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.commentBubbleCornerRadius))
        .overlay(bubbleBorder)
        .contentShape(Rectangle())
        .onTapGesture { onStartEditing() }
        .onHover { hovering in
            if !isEditing {
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
        }
        .contextMenu { contextMenuItems }
    }

    private var closeButton: some View {
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
        TextEditor(text: $editText)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .focused($isFocused)
            .frame(minHeight: 20)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: editText) { _, newValue in
                onTextChange(newValue)
            }
    }

    private var displayText: some View {
        Group {
            if comment.text.isEmpty {
                Text("Add a comment...")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .italic()
            } else {
                Text(comment.text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bubbleBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.commentBubbleCornerRadius)
            .fill(.white.opacity(isSelected ? 0.12 : 0.08))
    }

    private var bubbleBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.commentBubbleCornerRadius)
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

