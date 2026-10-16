//
//  GlassSidebar.swift
//  PageFlow
//
//  The ONE Liquid Glass sidebar kit shared by every content type's document
//  sidebar in the leading-overlay slot (PDF `SidebarView`, Markdown
//  `MarkdownOutlineSidebar`). The shell owns everything that makes the
//  sidebars look identical — the panel width, glass treatment, header
//  placement, list container insets, empty-state line, and close control —
//  so a content's sidebar CANNOT drift visually from its sibling; only the
//  header controls and rows inside differ. (The comments sidebar is NOT a
//  client: it is the trailing overlay with its own metrics.)
//

import SwiftUI

/// The shared glass panel: header slot above a content slot inside the ONE
/// width / padding / Liquid Glass treatment.
struct GlassSidebarShell<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            header
                .padding(.leading, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingSM)
                .padding(.top, DesignTokens.spacingSM)

            content
        }
        .padding(.horizontal, DesignTokens.spacingXS)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(width: DesignTokens.sidebarWidth)
        .pageFlowLiquidGlassPanel(.sidebar)
    }
}

/// The shared scrolling row container (outline, bookmarks, markdown outline):
/// leading-aligned rows with the ONE set of list insets on a transparent
/// scroller. Non-list sidebar content (the thumbnail grid) is not a client.
struct GlassSidebarList<Rows: View>: View {
    @ViewBuilder var rows: Rows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { rows }
                .padding(.horizontal, DesignTokens.spacingMD + DesignTokens.spacingSM)
                .padding(.bottom, DesignTokens.spacingMD)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .scrollContentBackground(.hidden)
    }
}

/// The shared header title ("Contents", "Bookmarks", …).
struct GlassSidebarTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .pageFlowGlassControlLabel()
    }
}

/// The shared empty-state line ("No Outline Available", "No Bookmarks").
struct GlassSidebarEmptyState: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DesignTokens.sidebarSecondaryText)
            .pageFlowGlassControlLabel()
            .padding(DesignTokens.spacingMD)
    }
}

/// The shared xmark close control in every sidebar header.
struct GlassSidebarCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .pageFlowGlassControlLabel()
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}
