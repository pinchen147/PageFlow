//
//  MarkdownFormatToolbar.swift
//  PageFlow
//
//  The Markdown item set for the shared top-chrome toolbar slot, inside the
//  same `GlassToolbarShell` as the PDF `FloatingToolbar` — identical shell,
//  identical position (`TopChromeView`), and the SAME section structure:
//  open | zoom cluster + sidebar toggle + Find | actions (Bold/Italic/
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
    /// Find, as PDF and EPUB put it after the sidebar button.
    var canFind = true
    var onFind: () -> Void = {}

    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(icon: "doc", help: "Open a document", action: onOpenFilePicker, label: "Open")
            Divider().frame(height: 16)
            ZoomToolbarGroup(
                canZoomOut: content.canZoomOut,
                canZoomIn: content.canZoomIn,
                onZoomOut: { content.zoomOut() },
                onZoomIn: { content.zoomIn() },
                reset: .init(help: "Actual size", disabled: !content.canResetZoom,
                             action: { content.resetZoom() }),
                fit: .init(isFitted: content.isWidthFitted, isAvailable: !content.isAwaitingOpen,
                           label: "Fit Text to Window", help: "Fit the reading text to the window width",
                           allowsRefitting: true, action: { content.zoomToFit() })
            )
            SidebarFindToolbarGroup(showingSidebar: $showingOutline, canFind: canFind, onFind: onFind)
            Divider().frame(height: 16)
            // the reference editor's host toolbar: Table, Checklist and Insert ▾; the
            // marks live on the selection bar (doc 24 §6.12).
            ForEach(MarkdownFormatCommand.toolbar) { command in
                GlassToolbarButton(
                    icon: command.iconSystemName,
                    help: command.help,
                    action: { content.requestFormat(command) },
                    disabled: !content.isFormatEnabled(command),
                    label: command.title
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
            // Follows the "Show button tooltips" setting like the other buttons.
            .toolbarTooltip("Insert", enabled: settingsManager.showTooltips)
            .accessibilityLabel("Insert")
        }
    }

    /// the reference editor's Comments button (doc 25 §1.4): "Show comments" while they
    /// are hidden (with the open count as a badge), "All comments" in the
    /// margin, "Floating comments" in the list.
    private var commentsButton: some View {
        // PDF's comments icon, filled while the list (the panel) shows.
        GlassToolbarButton(icon: content.isShowingCommentsList ? "bubble.right.fill" : "bubble.right",
                           help: content.commentsButtonHelp, action: { content.toggleCommentsList() },
                           label: "Comments", isOn: content.isShowingCommentsList)
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
