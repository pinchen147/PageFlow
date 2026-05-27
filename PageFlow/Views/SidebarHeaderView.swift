//
//  SidebarHeaderView.swift
//  PageFlow
//
//  Header controls for the document sidebar.
//

import SwiftUI

struct SidebarHeaderView: View {
    @Binding var mode: SidebarMode
    @Binding var isEditingPages: Bool
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .pageFlowGlassControlLabel()

            Spacer()

            if mode == .thumbnails && isEditingPages {
                doneButton
            }

            modeToggle
            closeButton
        }
    }

    private var headerTitle: String {
        switch mode {
        case .outline: return "Contents"
        case .thumbnails: return "Thumbnails"
        case .bookmarks: return "Bookmarks"
        }
    }

    private var doneButton: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                isEditingPages = false
            }
        } label: {
            Text("Done")
                .font(.system(size: 12))
                .padding(.horizontal, DesignTokens.spacingSM)
                .padding(.vertical, DesignTokens.spacingXS)
                .pageFlowGlassControlLabel()
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    private var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                isEditingPages = false
                mode = nextMode
            }
        } label: {
            Image(systemName: modeIcon)
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.primary)
                .frame(
                    width: DesignTokens.sidebarToggleButtonSize,
                    height: DesignTokens.sidebarToggleButtonSize
                )
                .contentShape(Rectangle())
                .pageFlowGlassControlLabel()
        }
        .buttonStyle(.plain)
        .help(modeHelpText)
    }

    private var closeButton: some View {
        Button {
            isEditingPages = false
            onClose()
        } label: {
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

    private var nextMode: SidebarMode {
        switch mode {
        case .outline: return .thumbnails
        case .thumbnails: return .bookmarks
        case .bookmarks: return .outline
        }
    }

    private var modeIcon: String {
        switch mode {
        case .outline: return "square.grid.2x2"
        case .thumbnails: return "bookmark"
        case .bookmarks: return "list.bullet"
        }
    }

    private var modeHelpText: String {
        switch mode {
        case .outline: return "Show Thumbnails"
        case .thumbnails: return "Show Bookmarks"
        case .bookmarks: return "Show Contents"
        }
    }
}
