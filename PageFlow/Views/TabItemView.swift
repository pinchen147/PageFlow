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
    /// While any tab drag is active, pills drop to the flat content-card
    /// surface: the gap-shift spring animates every pill, and animating N live
    /// glass surfaces re-samples each backdrop per frame (macOS 26) — the
    /// reorder stutter. Glass returns on drop. Containers were considered and
    /// rejected to keep the resting look exactly as-is (ADR-0004).
    var isDragInProgress: Bool = false

    var body: some View {
        let isCloseVisible = isHovering || isActive

        let content = HStack(spacing: DesignTokens.spacingXS) {
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

        Group {
            if isDragInProgress {
                content
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                            .fill(DesignTokens.contentCardSurface.opacity(isActive ? 1.0 : 0.88))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(isActive ? 0.3 : 0.18))
                    )
            } else {
                content
                    .pageFlowLiquidGlassSurface(.tab(active: isActive))
            }
        }
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: isActive ? 8 : 4, y: isActive ? -3 : -2)
        .contentShape(Rectangle())
        // Gesture handling moved to TabBarView for unified tap/drag detection
    }
}
