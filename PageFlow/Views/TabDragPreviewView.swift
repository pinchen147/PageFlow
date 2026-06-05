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
        .pageFlowLiquidGlassSurface(.tabDragPreview)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
        .compositingGroup()
    }
}
