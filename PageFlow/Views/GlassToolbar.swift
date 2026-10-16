//
//  GlassToolbar.swift
//  PageFlow
//
//  The ONE Liquid Glass toolbar kit shared by every content type's toolbar in
//  the top-chrome slot (PDF `FloatingToolbar`, Markdown `MarkdownFormatToolbar`).
//  The shell owns everything that makes the toolbars look identical — metrics
//  padding, the proximity-magnification field, the glass panel, the container
//  height — so an item set CANNOT drift visually from its sibling; only the
//  buttons inside differ.
//

import SwiftUI

/// How the top chrome folds the toolbar into its glass sphere (`ToolbarFold`).
/// The shell draws the fold; the chrome owns the state.
struct ToolbarFoldControl {
    var isOpen: Bool
    /// The trailing button pins the toolbar open (`ToolbarFold.offersPin`);
    /// otherwise it unpins and folds it.
    var offersPin: Bool
    /// The fold button: stop pinning the toolbar open and fold it.
    var onUnpin: () -> Void
    /// A click on the sphere, or the keep-open button of a peek: pin the
    /// toolbar open.
    var onPin: () -> Void
}

extension EnvironmentValues {
    /// Set by the top chrome; nil draws the toolbar always open.
    @Entry var toolbarFold: ToolbarFoldControl?
}

/// The open toolbar's natural width, for the chrome's fold decision.
struct FloatingToolbarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The shared glass shell: item spacing + scale-derived padding + Dock-style
/// proximity magnification + the Liquid Glass panel + the container height.
/// In the top chrome it also folds (`ToolbarFoldEffect`).
@MainActor
struct GlassToolbarShell<Items: View>: View {
    @ViewBuilder var items: Items

    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        HStack(spacing: DesignTokens.spacingXS) { items }
            .modifier(ToolbarFoldEffect(
                metrics: SettingsManager.toolbarMetrics(for: settingsManager.toolbarScale),
                magnifies: settingsManager.isToolbarMagnificationEnabled,
                showsTooltips: settingsManager.showTooltips
            ))
    }
}

/// The toolbar's panel and its fold: the same glass panel springs from the
/// open capsule to a circle as tall as the toolbar (the sphere), its items
/// fading out as it narrows.
///
/// Every fold-dependent piece lives in this modifier so a peek or fold re-runs
/// only it: the item buttons arrive as `content` and are never rebuilt. Per
/// frame the fold stays cheap too — the items keep their natural width (only
/// the panel's width animates), and a plain rectangular clip trims them (a
/// mask would re-render every glyph halo offscreen each frame). The pointer
/// is sensed by the chrome's peek zone, which covers the whole toolbar.
private struct ToolbarFoldEffect: ViewModifier {
    let metrics: SettingsManager.ToolbarMetrics
    let magnifies: Bool
    let showsTooltips: Bool

    @Environment(\.toolbarFold) private var fold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openWidth: CGFloat = 0

    func body(content: Content) -> some View {
        let isOpen = fold?.isOpen ?? true
        let height = metrics.containerHeight
        let cornerRadius = isOpen ? DesignTokens.floatingToolbarCornerRadius : height / 2

        HStack(spacing: DesignTokens.spacingXS) {
            content
            if let fold {
                Divider().frame(height: 16)
                // The trailing button sits where the sphere was, so a click
                // meant for the sphere that lands after the toolbar opened
                // still keeps it open.
                if fold.offersPin {
                    GlassToolbarButton(icon: "pin", help: "Keep the toolbar open", action: fold.onPin)
                } else {
                    GlassToolbarButton(icon: "chevron.right.2", help: "Fold the toolbar", action: fold.onUnpin)
                }
            }
        }
        // The items sit on a light surface in either mode (porcelain in dark,
        // GlassStyle.toolbar), so their dividers draw for light.
        .environment(\.colorScheme, .light)
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { openWidth = $0 }
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .proximityField(isEnabled: magnifies)
        // Folded, the panel is a circle on the trailing end and the items run
        // off its leading edge. The clip box is the panel's width with
        // vertical headroom so magnified icons can still overflow the panel.
        .frame(width: isOpen ? nil : height, height: height, alignment: .trailing)
        .frame(height: height * 2)
        .clipped()
        .background {
            Color.clear
                .frame(height: height)
                .pageFlowLiquidGlassPanel(GlassStyle.toolbar.with(cornerRadius: cornerRadius))
        }
        .overlay(alignment: .trailing) {
            if let fold {
                sphere(diameter: height, isOpen: isOpen, open: fold.onPin)
            }
        }
        .frame(height: height)
        .preference(key: FloatingToolbarWidthPreferenceKey.self, value: openWidth)
        .animation(DesignTokens.toolbarFoldAnimation(reduceMotion: reduceMotion), value: isOpen)
    }

    private func sphere(diameter: CGFloat, isOpen: Bool, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            Image(systemName: "ellipsis")
                .font(.system(size: metrics.iconSize, weight: .bold))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .pageFlowGlassControlLabel()
        }
        .buttonStyle(.plain)
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
        .accessibilityLabel("Show Toolbar")
        .toolbarTooltip("Show the toolbar", enabled: showsTooltips)
    }
}

/// The shared icon label — used by `GlassToolbarButton` AND by menu labels
/// (e.g. the PDF color palette `Menu`), so every control in the shell renders
/// the same glass glyph.
@MainActor
struct GlassToolbarLabel: View {
    let icon: String
    var interactive: Bool = true

    @State private var settingsManager = SettingsManager.shared

    private var metrics: SettingsManager.ToolbarMetrics {
        SettingsManager.toolbarMetrics(for: settingsManager.toolbarScale)
    }

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: metrics.iconSize, weight: .medium))
            .frame(width: metrics.buttonSize, height: metrics.buttonSize)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
            .pageFlowGlassControlLabel(interactive: interactive)
            .proximityMagnified()
    }
}

/// The shared Liquid Glass toolbar button used by BOTH the PDF `FloatingToolbar`
/// and the Markdown `MarkdownFormatToolbar`, so the two content types render the
/// same glass control in the same top-chrome slot — only the item set differs.
@MainActor
struct GlassToolbarButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var disabled: Bool = false

    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        Button(action: action) {
            GlassToolbarLabel(icon: icon, interactive: !disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1.0)
        .toolbarTooltip(help, enabled: settingsManager.showTooltips)
    }
}

extension View {
    /// Toolbar hover tooltip.
    ///
    /// When enabled, `.help(_:)` renders the native macOS help tag (≈1s hover delay,
    /// a system constant) *and* sets the VoiceOver hint. When the user disables tooltips
    /// we fall back to `.accessibilityHint(_:)` so the description still reaches VoiceOver —
    /// the visual tag is a preference, accessibility is not.
    @ViewBuilder
    func toolbarTooltip(_ text: String, enabled: Bool) -> some View {
        if enabled {
            help(text)
        } else {
            accessibilityHint(text)
        }
    }
}
