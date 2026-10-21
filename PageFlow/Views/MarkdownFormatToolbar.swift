//
//  MarkdownFormatToolbar.swift
//  PageFlow
//
//  The Markdown item set for the shared top-chrome toolbar slot, inside the
//  same `GlassToolbarShell` as the PDF `FloatingToolbar` — identical shell,
//  identical position (`TopChromeView`), and the SAME section structure:
//  open | zoom cluster + sidebar toggle | actions (Bold/Italic/
//  Underline/Heading). The magnifier cluster VISUALLY zooms the document
//  (per-document, persisted — PDF parity), the same as pinch / ⌘± / Ctrl-scroll;
//  the base font size lives in Settings.
//

import SwiftUI

@MainActor
struct MarkdownFormatToolbar: View {
    @Bindable var content: MarkdownContent
    var onOpenFilePicker: () -> Void
    /// The active tab's sidebar state (`TabSession.uiState.showingOutline` via
    /// `TabManager` — the same canonical slot the PDF toolbar binds).
    @Binding var showingOutline: Bool

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(icon: "doc", help: "Open a document", action: onOpenFilePicker)
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: "minus.magnifyingglass",
                help: "Zoom out",
                action: { content.zoomOut() },
                disabled: content.zoomScale <= DesignTokens.markdownMinZoom + 0.0001
            )
            GlassToolbarButton(
                icon: "1.magnifyingglass",
                help: "Actual size",
                action: { content.resetZoom() },
                disabled: abs(content.zoomScale - 1) < 0.0001
            )
            GlassToolbarButton(
                icon: "plus.magnifyingglass",
                help: "Zoom in",
                action: { content.zoomIn() },
                disabled: content.zoomScale >= DesignTokens.markdownMaxZoom - 0.0001
            )
            GlassToolbarButton(
                icon: "sidebar.leading",
                help: "Show or hide the outline",
                action: {
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                        showingOutline.toggle()
                    }
                }
            )
            Divider().frame(height: 16)
            // the reference editor's host toolbar: Table, Checklist and Insert ▾; the
            // marks live on the selection bar (doc 24 §6.12).
            ForEach(MarkdownFormatCommand.toolbar) { command in
                GlassToolbarButton(
                    icon: command.iconSystemName,
                    help: command.help,
                    action: { content.requestFormat(command) },
                    disabled: !content.isFormatEnabled(command)
                )
            }
            commentsButton
            Menu {
                ForEach(MarkdownFormatCommand.insertMenu) { command in
                    Button(command.title) { content.requestFormat(command) }
                        .disabled(!content.isFormatEnabled(command))
                }
            } label: {
                GlassToolbarLabel(icon: "plus", interactive: true)
            }
            .menuStyle(.borderlessButton)
            .pageFlowClickCursor()
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Insert")
        }
    }

    /// the reference editor's Comments button (doc 25 §1.4): "Show comments" while they
    /// are hidden (with the open count as a badge), "All comments" in the
    /// margin, "Floating comments" in the list.
    private var commentsButton: some View {
        GlassToolbarButton(icon: "bubble.left", help: content.commentsButtonHelp, action: { content.toggleCommentsList() })
            .accessibilityLabel("Comments")
            .overlay(alignment: .topTrailing) {
                if let count = content.hiddenCommentBadge {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
    }
}
