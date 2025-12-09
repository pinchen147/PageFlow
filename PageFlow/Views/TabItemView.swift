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
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: DesignTokens.tabMaxWidth - DesignTokens.tabCloseButtonSize - DesignTokens.spacingSM)

            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
            }
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(height: DesignTokens.tabHeight)
        .frame(minWidth: DesignTokens.tabMinWidth, maxWidth: DesignTokens.tabMaxWidth)
        .background(.ultraThinMaterial)
        .background(DesignTokens.floatingToolbarBase.opacity(isActive ? 0.2 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
                .strokeBorder(.white.opacity(isActive ? 0.3 : 0.18))
        )
        .shadow(color: .black.opacity(0.1), radius: isActive ? 8 : 4, y: isActive ? 4 : 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            onSelect()
        }
    }
}
