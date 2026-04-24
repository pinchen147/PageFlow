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
                        .fill(Color.white.opacity(0.9))
                        .frame(width: DesignTokens.tabDirtyIndicatorSize, height: DesignTokens.tabDirtyIndicatorSize)
                }

                Text(snapshot.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .opacity(0)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(width: snapshot.width, height: DesignTokens.tabHeight)
        .background(.ultraThinMaterial)
        .background(DesignTokens.floatingToolbarBase.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
                .strokeBorder(.white.opacity(0.32))
        )
        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
        .compositingGroup()
    }
}
