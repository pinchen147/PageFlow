//
//  TabItemView.swift
//  PageFlow
//
//  Individual tab component with glassmorphism styling
//

import SwiftUI

struct TabItemView: View {
    /// How the tab is drawn.
    enum Style: Equatable {
        /// The resting Liquid Glass pill.
        case glass
        /// The pill on the flat content card. Used while any tab drag is
        /// active — the gap-shift spring animates every pill, and animating N
        /// live glass surfaces re-samples each backdrop per frame (macOS 26),
        /// the reorder stutter — and by the Deck, whose cards overlap: glass
        /// cannot sample glass. Containers were considered and rejected to
        /// keep the resting look exactly as-is (ADR-0004).
        case card
        /// A Deck sliver: the content card showing only the icon, at the edge
        /// that peeks out from under the neighbouring card.
        case sliver(HorizontalEdge)
    }

    let tab: TabModel
    /// The tab's content type, used to pick a per-content icon so mixed PDF +
    /// Markdown tabs are distinguishable (S7b item 1). Optional because the
    /// source (`TabManager.contentKind(for:)`) is `nil` for an unknown id (a
    /// just-closed tab still lingering in the strip); the icon coalesces that
    /// to `.pdf` below, matching the legacy PDF-only appearance. The `.pdf`
    /// default also keeps call sites that don't pass a kind on the legacy look.
    var contentKind: ContentKind? = .pdf
    let isActive: Bool
    let isDirty: Bool
    let isHovering: Bool
    var style: Style = .glass

    var body: some View {
        Group {
            switch style {
            case .glass:
                content
                    .pageFlowLiquidGlassSurface(.tab(active: isActive))
            case .card, .sliver:
                content
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                            .fill(DesignTokens.contentCardSurface.opacity(isActive ? 1.0 : 0.88))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                            .strokeBorder(.white.opacity(isActive ? 0.3 : 0.18))
                    )
            }
        }
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: isActive ? 8 : 4, y: isActive ? -3 : -2)
        .contentShape(Rectangle())
        // Gesture handling moved to TabBarView for unified tap/drag detection
    }

    @ViewBuilder
    private var content: some View {
        if case .sliver(let edge) = style {
            sliver(showing: edge)
        } else {
            pill
        }
    }

    private var pill: some View {
        let isCloseVisible = isHovering || isActive

        return HStack(spacing: DesignTokens.spacingXS) {
            HStack(spacing: DesignTokens.spacingXS) {
                if isDirty {
                    dirtyDot(size: DesignTokens.tabDirtyIndicatorSize)
                }
                icon
                Text(tab.displayTitle)
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                    .foregroundStyle(DesignTokens.glassTextPrimary.opacity(isActive ? 0.92 : 0.74))
                    .pageFlowGlassTextHalo()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: DesignTokens.tabMaxWidth - DesignTokens.tabCloseButtonSize - DesignTokens.spacingSM, alignment: .leading)
            }

            // A pill wider than its title (the minimum width, a Deck card)
            // keeps the close button on its trailing edge, where
            // `TabBarMouseView` hit-tests it.
            Spacer(minLength: 0)

            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DesignTokens.glassTextSecondary.opacity(0.62))
                .pageFlowGlassTextHalo()
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .opacity(isCloseVisible ? 1 : 0)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(height: DesignTokens.tabHeight)
        .frame(minWidth: DesignTokens.tabMinWidth, maxWidth: DesignTokens.tabMaxWidth)
    }

    /// The icon centred in the shown edge, with the unsaved dot on its corner.
    private func sliver(showing edge: HorizontalEdge) -> some View {
        icon
            .frame(width: DesignTokens.tabDeckSliverWidth, height: DesignTokens.tabHeight)
            .overlay(alignment: .topTrailing) {
                if isDirty {
                    dirtyDot(size: DesignTokens.tabDirtyIndicatorSize - 2)
                        .padding(.top, DesignTokens.spacingXS)
                }
            }
            .frame(
                width: DesignTokens.tabMaxWidth,
                height: DesignTokens.tabHeight,
                alignment: edge == .leading ? .leading : .trailing
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tab.displayTitle)
    }

    private var icon: some View {
        Image(systemName: (contentKind ?? .pdf).tabIconSystemName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DesignTokens.glassTextSecondary.opacity(isActive ? 0.82 : 0.6))
            .pageFlowGlassTextHalo()
    }

    private func dirtyDot(size: CGFloat) -> some View {
        Circle()
            .fill(DesignTokens.glassTextPrimary.opacity(0.82))
            .frame(width: size, height: size)
    }
}
