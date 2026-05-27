//
//  LiquidGlass.swift
//  PageFlow
//
//  Shared Liquid Glass styling for PageFlow controls and navigation chrome.
//

import AppKit
import SwiftUI

enum PageFlowGlassVariant: Equatable {
    case regular
    case clear
}

enum PageFlowGlassTint: Equatable {
    case dark
    case light

    func color(opacity: CGFloat) -> Color {
        switch self {
        case .dark:
            return DesignTokens.floatingToolbarBase.opacity(Double(opacity))
        case .light:
            return Color.white.opacity(Double(opacity))
        }
    }

    func nsColor(opacity: CGFloat) -> NSColor {
        switch self {
        case .dark:
            return NSColor(white: 0.196, alpha: opacity)
        case .light:
            return NSColor.white.withAlphaComponent(opacity)
        }
    }
}

extension View {
    @ViewBuilder
    func pageFlowLiquidGlassSurface(
        cornerRadius: CGFloat,
        tint: PageFlowGlassTint = .dark,
        tintOpacity: CGFloat = 0.12,
        interactive: Bool = false,
        variant: PageFlowGlassVariant = .regular,
        strokeOpacity: Double = 0.22
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            self
                .glassEffect(
                    pageFlowGlass(variant: variant, tint: tint, tintOpacity: tintOpacity, interactive: interactive),
                    in: shape
                )
                .overlay(
                    shape
                        .strokeBorder(.white.opacity(strokeOpacity))
                        .allowsHitTesting(false)
                )
        } else {
            self
                .background(HUDGlassFill(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity))
                .clipShape(shape)
                .overlay(
                    shape
                        .strokeBorder(.white.opacity(strokeOpacity))
                        .allowsHitTesting(false)
                )
        }
    }

    func pageFlowLiquidGlassPanel(
        cornerRadius: CGFloat = DesignTokens.floatingToolbarCornerRadius,
        tint: PageFlowGlassTint = .dark,
        tintOpacity: CGFloat = 0.12,
        interactive: Bool = false,
        variant: PageFlowGlassVariant = .regular,
        strokeOpacity: Double = 0.22,
        shadowRadius: CGFloat = 10,
        shadowY: CGFloat = 5
    ) -> some View {
        pageFlowLiquidGlassSurface(
            cornerRadius: cornerRadius,
            tint: tint,
            tintOpacity: tintOpacity,
            interactive: interactive,
            variant: variant,
            strokeOpacity: strokeOpacity
        )
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: shadowRadius, y: shadowY)
    }

    @ViewBuilder
    func pageFlowGlassControlLabel(
        interactive: Bool = true
    ) -> some View {
        self
            .foregroundStyle(DesignTokens.glassControlForeground.opacity(interactive ? 1 : 0.52))
    }
}

@available(macOS 26.0, *)
private func pageFlowGlass(
    variant: PageFlowGlassVariant,
    tint: PageFlowGlassTint,
    tintOpacity: CGFloat,
    interactive: Bool
) -> Glass {
    let base: Glass = variant == .clear ? .clear : .regular
    let glass = tintOpacity > 0
        ? base.tint(tint.color(opacity: tintOpacity))
        : base

    return glass.interactive(interactive)
}
