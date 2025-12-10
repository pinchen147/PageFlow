//
//  CommentsSidebar.swift
//  PageFlow
//
//  Right sidebar displaying comments as speech bubbles with glassmorphism
//

import SwiftUI

struct CommentsSidebar: View {
    @Bindable var commentManager: CommentManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            commentsList
        }
        .frame(width: DesignTokens.commentSidebarWidth)
        .background(sidebarBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius))
        .overlay(sidebarBorder)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
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

    // MARK: - Background

    private var sidebarBackground: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.15)
        }
    }

    private var sidebarBorder: some View {
        RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
            .strokeBorder(.white.opacity(0.15))
            .allowsHitTesting(false)
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
        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            if isEditing {
                editableText
            } else {
                displayText
            }
        }
        .padding(DesignTokens.spacingSM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.commentBubbleCornerRadius))
        .overlay(bubbleBorder)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .contextMenu { contextMenuItems }
    }

    private var editableText: some View {
        TextEditor(text: $editText)
            .font(.caption)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .foregroundStyle(.white.opacity(0.9))
            .frame(minHeight: 40, maxHeight: 100)
            .focused($isFocused)
            .onChange(of: editText) { _, newValue in
                onTextChange(newValue)
            }
            .onSubmit {
                onStopEditing()
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
        .onTapGesture(count: 2) { onStartEditing() }
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

// MARK: - Visual Effect

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
