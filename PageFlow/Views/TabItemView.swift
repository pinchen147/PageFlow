//
//  TabItemView.swift
//  PageFlow
//
//  Individual tab component with glassmorphism styling
//

import SwiftUI

struct TabItemView: View {
    let tab: TabModel
    let isActive: Bool
    let isDirty: Bool
    let isHovering: Bool

    var body: some View {
        let isCloseVisible = isHovering || isActive

        HStack(spacing: DesignTokens.spacingXS) {
            HStack(spacing: DesignTokens.spacingXS) {
                if isDirty {
                    Circle()
                        .fill(DesignTokens.glassTextPrimary.opacity(0.82))
                        .frame(width: DesignTokens.tabDirtyIndicatorSize, height: DesignTokens.tabDirtyIndicatorSize)
                }
                Text(tab.displayTitle)
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                    .foregroundStyle(DesignTokens.glassTextPrimary.opacity(isActive ? 0.92 : 0.74))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: DesignTokens.tabMaxWidth - DesignTokens.tabCloseButtonSize - DesignTokens.spacingSM)
            }

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DesignTokens.glassTextSecondary.opacity(0.62))
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .opacity(isCloseVisible ? 1 : 0)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(height: DesignTokens.tabHeight)
        .frame(minWidth: DesignTokens.tabMinWidth, maxWidth: DesignTokens.tabMaxWidth)
        .pageFlowLiquidGlassSurface(
            cornerRadius: DesignTokens.tabCornerRadius,
            tint: .light,
            tintOpacity: isActive ? 0.22 : 0.14,
            variant: .clear,
            strokeOpacity: isActive ? 0.3 : 0.18
        )
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: isActive ? 8 : 4, y: isActive ? -3 : -2)
        .contentShape(Rectangle())
        // Gesture handling moved to TabBarView for unified tap/drag detection
    }
}
