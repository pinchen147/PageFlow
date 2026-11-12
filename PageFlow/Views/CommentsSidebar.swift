//
//  CommentsSidebar.swift
//  PageFlow
//
//  Right sidebar displaying PDF comment cards.
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
                .foregroundStyle(.primary)
            Spacer()
            GlassSidebarCloseButton(label: "Close Comments", action: onClose)
        }
        .padding(.leading, DesignTokens.spacingMD)
        .padding(.trailing, DesignTokens.spacingSM)
        .padding(.top, DesignTokens.spacingSM)
    }

    // MARK: - Comments List

    private var commentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.spacingSM) {
                    if commentManager.comments.isEmpty {
                        emptyState
                    } else {
                        ForEach(commentManager.sortedComments) { comment in
                            CommentBubbleView(
                                comment: comment,
                                presentation: commentManager.presentation(for: comment.id),
                                annotationOwner: commentManager,
                                isSelected: commentManager.selectedCommentID == comment.id,
                                isEditing: commentManager.editingCommentID == comment.id,
                                focusRevision: commentManager.editingRevision,
                                canEdit: commentManager.canEdit,
                                onSelect: { commentManager.selectComment(comment.id) },
                                onStartEditing: { commentManager.startEditing(comment.id) },
                                onTextChange: { commentManager.updateComment(comment.id, text: $0) },
                                onColorChange: { commentManager.updateCommentColor(comment.id, color: $0) },
                                onStopEditing: { commentManager.stopEditing() },
                                onDelete: { commentManager.deleteComment(comment.id) }
                            )
                            .id(comment.id)
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.spacingSM)
                .padding(.bottom, DesignTokens.spacingMD)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: commentManager.selectedCommentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: commentManager.editingRevision, initial: true) {
                guard let id = commentManager.editingCommentID else { return }
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No comments yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(addCommentHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignTokens.spacingXL)
    }

    /// Names the Add Comment shortcut as the user has it bound, not the default.
    private var addCommentHint: String {
        let shortcut = ShortcutModel.current(for: "comment")
        return shortcut.isNone ? "Select text and choose Tools > Add Comment"
            : "Select text and press \(shortcut.displayString)"
    }

}

// MARK: - PDF Comment Card

struct CommentBubbleView: View {
    let comment: CommentModel
    let presentation: CommentManager.Presentation?
    var annotationOwner: AnyObject? = nil
    let isSelected: Bool
    let isEditing: Bool
    let focusRevision: Int
    let canEdit: Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void
    let onTextChange: (String) -> Void
    let onColorChange: (NSColor) -> Void
    let onStopEditing: () -> Void
    let onDelete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private func resolved(_ color: NSColor) -> NSColor {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        var result = color
        appearance?.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }

    var body: some View {
        let ink = resolved(.textColor)
        AnnotationNoteCard(
            pageLabel: "Page \(comment.pageIndex + 1)",
            accessibilityLabel: "Comment on page \(comment.pageIndex + 1)", deleteLabel: "Delete Comment",
            excerpt: presentation?.excerpt, annotationColor: presentation?.color ?? DesignTokens.commentHighlightColor,
            surface: resolved(.textBackgroundColor), ink: ink, colorScheme: colorScheme,
            isSelected: isSelected, isEditing: isEditing, canEdit: canEdit,
            onSelect: onSelect, onEdit: onStartEditing, onDelete: onDelete
        ) {
            if isEditing && canEdit {
                VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
                    HStack(spacing: DesignTokens.spacingSM) {
                        AnnotationNoteColors(color: Binding(
                            get: { presentation?.color ?? DesignTokens.commentHighlightColor },
                            set: onColorChange), presets: SettingsManager.shared.commentPresets)
                        Spacer()
                    }
                    AnnotationNoteTextEditor(text: Binding(get: { comment.text }, set: onTextChange),
                        placeholder: "Add a comment...", accessibilityLabel: "Comment",
                        annotationOwner: annotationOwner, textColor: ink, colorScheme: colorScheme,
                        focusRevision: focusRevision, onDone: onStopEditing)
                }
            } else if comment.text.isEmpty {
                Text("Add a comment...")
                    .font(.system(size: DesignTokens.commentFontSize))
                    .foregroundStyle(.tertiary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MathTextView(text: comment.text, textColor: ink)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
struct ClickCatcher: NSViewRepresentable {
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
