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
            // Behind the content, not around it: glass around a view picks that view's
            // foreground from what it samples, so labels stopped following the scheme
            // the tint came from. A new appearance also left the old tint drawn, so the
            // tint is the glass's identity. Small glass still adapts to its backdrop
            // whatever its tint, so legible chrome gets a plain fill above it.
            self
                .background {
                    ZStack {
                        Color.clear
                            .glassEffect(
                                pageFlowGlass(variant: variant, tint: tint, tintOpacity: tintOpacity, interactive: interactive),
                                in: shape
                            )
                        if tintOpacity >= DesignTokens.legibleGlassBaseTint {
                            shape.fill(tint.color(opacity: DesignTokens.legibleGlassBaseTint))
                        }
                    }
                    .id(tint)
                }
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
    /// Floating chrome that labels must stay readable on over any page; see
    /// `LegibleGlass`.
    var legible = false

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
    // Chrome panels (carry their own elevation shadow). The toolbar, tabs and
    // chrome glyph buttons share the sidebar's glass in both appearances, so
    // all floating chrome reads as one material.
    /// Shared by the outline sidebar and the comments sidebar.
    static let sidebar = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.sidebarGlassTintOpacity, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 4, shadowY: -2, legible: true
    )
    static let toolbar = sidebar
    /// Shared by the search bar and the toast (identical after defaults).
    static let glassPanel = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.glassPanelTintOpacity, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 10, shadowY: 5, legible: true
    )
    /// Regular material supplies contrast for the native foreground hierarchy.
    static let tabSwitcher = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: 0.4, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 10, shadowY: 5
    )
    /// The "Open PDF" empty-state button.
    static let primaryButton = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: 0.18, interactive: true, variant: .regular,
        strokeOpacity: 0.22, shadowRadius: 8, shadowY: 3
    )

    // Chrome surfaces (no built-in shadow; an external .shadow stays at the call site).
    static let pageIndicator = GlassStyle(
        cornerRadius: DesignTokens.floatingToolbarCornerRadius,
        tint: .light, tintOpacity: DesignTokens.sidebarControlGlassTintOpacity, variant: .regular,
        legible: true
    )
    static let newTabButton = tab(active: true).with(strokeOpacity: 0.22)
    static let dragHandle = GlassStyle(
        cornerRadius: 4,
        tint: .light, tintOpacity: 0.10, interactive: true, variant: .clear, strokeOpacity: 0.12
    )

    /// A tab pill on the sidebar's glass; the focused tab is a step stronger
    /// in tint and stroke. The pill's drop shadow is state-dependent and stays
    /// as an external `.shadow` at the call site.
    static func tab(active: Bool) -> GlassStyle {
        GlassStyle(
            cornerRadius: DesignTokens.tabCornerRadius,
            tint: .light,
            tintOpacity: active ? DesignTokens.sidebarGlassTintOpacity : DesignTokens.sidebarControlGlassTintOpacity,
            variant: .regular,
            strokeOpacity: active ? 0.3 : 0.18,
            legible: true
        )
    }

}

extension View {
    /// Applies a named glass surface. `shadowRadius` / `shadowY` are unused here.
    func pageFlowLiquidGlassSurface(_ style: GlassStyle) -> some View {
        modifier(LegibleGlass(style: style, panel: false))
    }

    /// Applies a named glass panel (surface + elevation shadow).
    func pageFlowLiquidGlassPanel(_ style: GlassStyle) -> some View {
        modifier(LegibleGlass(style: style, panel: true))
    }
}

/// Glass samples whatever sits behind it: a white PDF page turns light glass
/// white under dark mode's white labels, and a dark image does the reverse in
/// light mode. Legible chrome (sidebar, toolbar, tabs, search, page indicator)
/// therefore takes a tint matching the appearance, strong enough that its
/// labels stay readable over any page.
private struct LegibleGlass: ViewModifier {
    let style: GlassStyle
    let panel: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var resolved: GlassStyle {
        guard style.legible, style.tint == .light else { return style }
        let opacity = min(DesignTokens.legibleGlassMaxTint, DesignTokens.legibleGlassBaseTint + style.tintOpacity)
        return style.with(tint: colorScheme == .dark ? .dark : .light, tintOpacity: opacity)
    }

    func body(content: Content) -> some View {
        let style = resolved
        if panel {
            content.pageFlowLiquidGlassPanel(
                cornerRadius: style.cornerRadius, tint: style.tint, tintOpacity: style.tintOpacity,
                interactive: style.interactive, variant: style.variant, strokeOpacity: style.strokeOpacity,
                shadowRadius: style.shadowRadius, shadowY: style.shadowY
            )
        } else {
            content.pageFlowLiquidGlassSurface(
                cornerRadius: style.cornerRadius, tint: style.tint, tintOpacity: style.tintOpacity,
                interactive: style.interactive, variant: style.variant, strokeOpacity: style.strokeOpacity
            )
        }
    }
}

// MARK: - Chrome Glyph Button

/// A 24×24 liquid-glass chrome glyph, shared by the tab bar's "+" and the Tab
/// Switcher chevron so the two stay visually identical by construction instead
/// of by copy-paste.
struct ChromeGlassIcon: View {
    let systemName: String
    var pointSize: CGFloat = 10

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.78))
            .frame(width: DesignTokens.chromeIconSize, height: DesignTokens.chromeIconSize)
            .pageFlowLiquidGlassSurface(.newTabButton)
            .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: 4, y: -2)
    }
}
