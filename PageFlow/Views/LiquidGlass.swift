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

// MARK: - Named Glass Styles

/// A named bundle of the glass-surface parameters, so call sites read
/// `.pageFlowLiquidGlassPanel(.toolbar)` instead of repeating an opaque tuple of
/// magic numbers. Presets are exposed as static members (see the extension
/// below), mirroring how SwiftUI surfaces `.bordered` / `.plain` styles.
///
/// Defaults mirror the underlying `pageFlowLiquidGlassSurface` / `Panel`
/// modifier defaults exactly, so a preset that omits a field reproduces the same
/// value the call site would have gotten by omitting that argument. `shadowRadius`
/// / `shadowY` are only consumed by the panel overload; the surface overload
/// ignores them.
struct GlassStyle {
    var cornerRadius: CGFloat
    var tint: PageFlowGlassTint = .dark
    var tintOpacity: CGFloat = 0.12
    var interactive: Bool = false
    var variant: PageFlowGlassVariant = .regular
    var strokeOpacity: Double = 0.22
    var shadowRadius: CGFloat = 10
    var shadowY: CGFloat = 5

    /// Returns a copy with the given fields overridden — an escape hatch for the
    /// one or two call sites that differ from a preset by a single value, without
    /// minting a whole new named style.
    func with(
        cornerRadius: CGFloat? = nil,
        tint: PageFlowGlassTint? = nil,
        tintOpacity: CGFloat? = nil,
        interactive: Bool? = nil,
        variant: PageFlowGlassVariant? = nil,
        strokeOpacity: Double? = nil,
        shadowRadius: CGFloat? = nil,
        shadowY: CGFloat? = nil
    ) -> GlassStyle {
        var copy = self
        if let cornerRadius { copy.cornerRadius = cornerRadius }
        if let tint { copy.tint = tint }
        if let tintOpacity { copy.tintOpacity = tintOpacity }
        if let interactive { copy.interactive = interactive }
        if let variant { copy.variant = variant }
        if let strokeOpacity { copy.strokeOpacity = strokeOpacity }
        if let shadowRadius { copy.shadowRadius = shadowRadius }
        if let shadowY { copy.shadowY = shadowY }
        return copy
    }
}

extension GlassStyle {
    // Chrome panels (carry their own elevation shadow).
    static let toolbar = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: 0.14, variant: .clear,
        strokeOpacity: 0.22, shadowRadius: 4, shadowY: -2
    )
    /// Shared by the outline sidebar and the comments sidebar (identical tuple).
    static let sidebar = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.sidebarGlassTintOpacity, variant: .clear,
        strokeOpacity: 0.22, shadowRadius: 4, shadowY: -2
    )
    /// Shared by the search bar and the toast (identical after defaults).
    static let glassPanel = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.glassPanelTintOpacity, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 10, shadowY: 5
    )
    /// The "Open PDF" empty-state button.
    static let primaryButton = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: 0.18, interactive: true, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 8, shadowY: 3
    )
    /// The drag-and-drop target panel.
    static let dropZone = GlassStyle(
        cornerRadius: DesignTokens.spacingMD,
        tint: .light, tintOpacity: 0.18, variant: .regular,
        strokeOpacity: 0.4, shadowRadius: 16, shadowY: 6
    )

    // Chrome surfaces (no built-in shadow; an external .shadow stays at the call site).
    static let pageIndicator = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.sidebarControlGlassTintOpacity, variant: .clear
    )
    static let newTabButton = GlassStyle(
        cornerRadius: DesignTokens.tabCornerRadius,
        tint: .light, tintOpacity: 0.14, variant: .clear, strokeOpacity: 0.22
    )
    static let dragHandle = GlassStyle(
        cornerRadius: 4,
        tint: .light, tintOpacity: 0.10, interactive: true, variant: .clear, strokeOpacity: 0.12
    )

    /// Settings-tab rows omit `tint` (so they keep the default `.dark`).
    static let settingsRow = GlassStyle(
        cornerRadius: DesignTokens.spacingSM,
        tintOpacity: 0.08, interactive: true, variant: .clear, strokeOpacity: 0.16
    )

    /// A tab pill; `active` drives tint and stroke. The pill's drop shadow is
    /// also state-dependent and stays as an external `.shadow` at the call site.
    static func tab(active: Bool) -> GlassStyle {
        GlassStyle(
            cornerRadius: DesignTokens.tabCornerRadius,
            tint: .light,
            tintOpacity: active ? 0.22 : 0.14,
            variant: .clear,
            strokeOpacity: active ? 0.3 : 0.18
        )
    }

    /// A settings action button whose emphasis depends on `enabled`. `activeTint`
    /// is the enabled tint opacity (0.08 for General's Reset, 0.10 for Shortcuts).
    static func settingsAction(enabled: Bool, activeTint: CGFloat) -> GlassStyle {
        GlassStyle(
            cornerRadius: DesignTokens.spacingSM,
            tintOpacity: enabled ? activeTint : 0.04,
            interactive: enabled,
            variant: .clear,
            strokeOpacity: enabled ? 0.16 : 0.08
        )
    }
}

extension View {
    /// Applies a named glass surface. Forwards every field to the parameterized
    /// `pageFlowLiquidGlassSurface`, so it is behavior-identical to spelling the
    /// tuple out. `shadowRadius` / `shadowY` are intentionally unused here.
    func pageFlowLiquidGlassSurface(_ style: GlassStyle) -> some View {
        pageFlowLiquidGlassSurface(
            cornerRadius: style.cornerRadius,
            tint: style.tint,
            tintOpacity: style.tintOpacity,
            interactive: style.interactive,
            variant: style.variant,
            strokeOpacity: style.strokeOpacity
        )
    }

    /// Applies a named glass panel (surface + elevation shadow). Forwards every
    /// field to the parameterized `pageFlowLiquidGlassPanel`.
    func pageFlowLiquidGlassPanel(_ style: GlassStyle) -> some View {
        pageFlowLiquidGlassPanel(
            cornerRadius: style.cornerRadius,
            tint: style.tint,
            tintOpacity: style.tintOpacity,
            interactive: style.interactive,
            variant: style.variant,
            strokeOpacity: style.strokeOpacity,
            shadowRadius: style.shadowRadius,
            shadowY: style.shadowY
        )
    }
}
