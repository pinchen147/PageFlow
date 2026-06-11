//
//  TabDragPreviewView.swift
//  PageFlow
//
//  Floating preview shown while a tab is dragged across windows.
//

import SwiftUI

struct TabDragPreviewSnapshot {
    let title: String
    let isDirty: Bool
    let width: CGFloat
}

struct TabDragPreviewView: View {
    let snapshot: TabDragPreviewSnapshot

    var body: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            HStack(spacing: DesignTokens.spacingXS) {
                if snapshot.isDirty {
                    Circle()
                        .fill(DesignTokens.glassTextPrimary.opacity(0.82))
                        .frame(width: DesignTokens.tabDirtyIndicatorSize, height: DesignTokens.tabDirtyIndicatorSize)
                }

                Text(snapshot.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.glassTextPrimary.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DesignTokens.glassTextSecondary.opacity(0.62))
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .opacity(0)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(width: snapshot.width, height: DesignTokens.tabHeight)
        // Opaque card, not Liquid Glass: the pill tracks the cursor, and live
        // glass re-samples its backdrop on every move (macOS 26) — the single
        // biggest source of drag lag. A static surface renders once and the
        // panel then moves for free.
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                .fill(DesignTokens.contentCardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.32))
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
        .compositingGroup()
    }
}
