//
//  SettingsManager.swift
//  PageFlow
//
//  Centralized settings state with UserDefaults persistence
//

import Foundation
import AppKit
import SwiftUI
import Observation
import os.log

/// The color scheme the Markdown editor renders in, independent of the system
/// appearance. `.system` follows the OS; `.light`/`.dark` force the whole
/// Markdown tab surface (`MarkdownTabView`: SwiftUI colorScheme + reading
/// background) and the engine editor's `NSScrollView.appearance`
/// (`NativeTextViewWrapper`). One canonical home for both mappings so the
/// AppKit and SwiftUI legs can't drift.
enum MarkdownColorScheme: String, CaseIterable {
    case system
    case light
    case dark

    /// AppKit leg: the forced appearance for the engine's scroll view
    /// (`nil` = follow the system).
    var forcedAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// SwiftUI leg: the forced scheme for the Markdown tab surface
    /// (`nil` = follow the system).
    var forcedColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()
    private let logger = Logger(subsystem: "com.pageflow", category: "SettingsManager")

    // MARK: - Color Preset Model

    struct ColorPreset: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var hex: String

        init(id: UUID = UUID(), name: String, hex: String) {
            self.id = id
            self.name = name
            self.hex = hex
        }

        var color: NSColor {
            get { Self.hexToColor(hex) ?? .black }
            set { hex = Self.colorToHex(newValue) }
        }

        private static func hexToColor(_ hex: String) -> NSColor? {
            var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

            var rgba: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgba)

            // Support both #RRGGBB (6 chars) and #RRGGBBAA (8 chars)
            // Use sRGB color space for consistency with DesignTokens
            if hexSanitized.count == 6 {
                return NSColor(
                    srgbRed: CGFloat((rgba & 0xFF0000) >> 16) / 255.0,
                    green: CGFloat((rgba & 0x00FF00) >> 8) / 255.0,
                    blue: CGFloat(rgba & 0x0000FF) / 255.0,
                    alpha: 1.0
                )
            } else if hexSanitized.count == 8 {
                return NSColor(
                    srgbRed: CGFloat((rgba & 0xFF000000) >> 24) / 255.0,
                    green: CGFloat((rgba & 0x00FF0000) >> 16) / 255.0,
                    blue: CGFloat((rgba & 0x0000FF00) >> 8) / 255.0,
                    alpha: CGFloat(rgba & 0x000000FF) / 255.0
                )
            }
            return nil
        }

        private static func colorToHex(_ color: NSColor) -> String {
            guard let rgbColor = color.usingColorSpace(.sRGB) else {
                return "#000000FF"
            }
            let r = Int(rgbColor.redComponent * 255)
            let g = Int(rgbColor.greenComponent * 255)
            let b = Int(rgbColor.blueComponent * 255)
            let a = Int(rgbColor.alphaComponent * 255)
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
    }

    struct ToolbarMetrics {
        let buttonSize: CGFloat
        let iconSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let containerHeight: CGFloat
    }

    static let defaultToolbarScale = 1.0
    static let toolbarScaleRange: ClosedRange<Double> = 0.8...1.6

    static func clampedToolbarScale(_ scale: Double) -> Double {
        min(max(scale, toolbarScaleRange.lowerBound), toolbarScaleRange.upperBound)
    }

    static func toolbarMetrics(for scale: Double) -> ToolbarMetrics {
        let clampedScale = CGFloat(clampedToolbarScale(scale))
        let buttonSize = DesignTokens.toolbarButtonSize * clampedScale
        let iconSize = DesignTokens.toolbarIconSize * clampedScale
        let horizontalPadding = max(DesignTokens.spacingXS, DesignTokens.spacingSM * clampedScale)
        let verticalPadding = max(2, DesignTokens.spacingXS * clampedScale)
        let containerHeight = max(
            buttonSize + (verticalPadding * 2),
            DesignTokens.collapsedToolbarSize * clampedScale
        )

        return ToolbarMetrics(
            buttonSize: buttonSize,
            iconSize: iconSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            containerHeight: containerHeight
        )
    }

    // MARK: - Keys

    private enum Keys {
        static let highlightPresets = "settings.highlightPresets"
        static let underlinePresets = "settings.underlinePresets"
        static let commentPresets = "settings.commentPresets"
        static let customShortcuts = "settings.customShortcuts"
        static let toolbarScale = "settings.toolbarScale"
        static let topBarAlwaysVisible = "settings.topBarAlwaysVisible"
        static let floatingToolbarAlwaysVisible = "settings.floatingToolbarAlwaysVisible"
        static let pageIndicatorAlwaysVisible = "settings.pageIndicatorAlwaysVisible"
        static let compactTabs = "settings.compactTabs"
        static let toolbarMagnificationEnabled = "settings.toolbarMagnificationEnabled"
        static let showTooltips = "settings.showTooltips"
        static let markdownColorScheme = "settings.markdownColorScheme"
        static let markdownSideMargin = "settings.markdownSideMargin"
        static let markdownFontFamily = "settings.markdownFontFamily"
        static let markdownFontSize = "settings.markdownFontSize"
        static let markdownCentersZoomedOut = "settings.markdownCentersZoomedOut"
        static let markdownPageLook = "settings.markdownPageLook"
    }

    /// The app-default Markdown editor font. PINNED to the engine's own default
    /// (`NativeTextViewWrapper.fontName` init default) — if one changes, the
    /// Settings picker's "Default" tag stops matching stored values.
    static let defaultMarkdownFontFamily = "SF Pro"
    /// The CURATED Markdown font menu — the default plus the most common
    /// English faces (sans + the two classics) and the two most common Chinese
    /// faces (sans + serif). Every family here supports ⌘B/I/U end to end: the
    /// Chinese families ship no italic faces, so ⌘I renders through the
    /// engine's synthetic-oblique fallback (`ItalicFallback.resolveFont`).
    /// Stored values outside this list reset to the default on load, so the
    /// picker can never show a dangling selection.
    static let markdownFontFamilies: [String] = [
        defaultMarkdownFontFamily,   // SF Pro — the system sans serif
        "Helvetica Neue",
        "Times New Roman",
        "PingFang SC",               // 苹方 — the system Chinese sans
        "Songti SC",                 // 宋体 — the classic Chinese serif
    ]
    static let defaultMarkdownFontSize: Double = 16
    /// The Settings stepper's range; stored values clamp to it on load.
    static let markdownFontSizeRange: ClosedRange<Double> = 10...28
    /// The side-margin slider's range (points); stored values clamp on load.
    static let markdownSideMarginRange: ClosedRange<Double> = 0...300

    // MARK: - Default Presets

    static let defaultHighlightPresets: [ColorPreset] = [
        ColorPreset(name: "Yellow", hex: "#FFFF00"),
        ColorPreset(name: "Green", hex: "#00B342"),
        ColorPreset(name: "Red", hex: "#D20000"),
        ColorPreset(name: "Blue", hex: "#0072C6")
    ]

    static let defaultUnderlinePresets: [ColorPreset] = [
        ColorPreset(name: "Black", hex: "#000000"),
        ColorPreset(name: "Yellow", hex: "#FFFF00"),
        ColorPreset(name: "Green", hex: "#00B342"),
        ColorPreset(name: "Red", hex: "#D20000"),
        ColorPreset(name: "Blue", hex: "#0072C6")
    ]

    static let defaultCommentPresets: [ColorPreset] = [
        ColorPreset(name: "Gray", hex: "#80808099")  // 99 hex = 153 = 0.6 alpha
    ]

    // MARK: - Properties

    private let defaults: UserDefaults
    private var isLoading = false

    var highlightPresets: [ColorPreset] = defaultHighlightPresets {
        didSet { if !isLoading { savePresets(highlightPresets, forKey: Keys.highlightPresets) } }
    }

    var underlinePresets: [ColorPreset] = defaultUnderlinePresets {
        didSet { if !isLoading { savePresets(underlinePresets, forKey: Keys.underlinePresets) } }
    }

    var commentPresets: [ColorPreset] = defaultCommentPresets {
        didSet { if !isLoading { savePresets(commentPresets, forKey: Keys.commentPresets) } }
    }

    var customShortcuts: [String: ShortcutModel] = [:] {
        didSet {
            if !isLoading { saveShortcuts() }
            NotificationCenter.default.post(name: Self.shortcutsDidChange, object: self)
        }
    }

    /// Posted when a shortcut changes, for the open editors to rebind live.
    static let shortcutsDidChange = Notification.Name("PageFlow.shortcutsDidChange")

    var toolbarScale = SettingsManager.defaultToolbarScale {
        didSet {
            let clampedScale = Self.clampedToolbarScale(toolbarScale)
            if toolbarScale != clampedScale {
                toolbarScale = clampedScale
                return
            }
            if !isLoading {
                defaults.set(toolbarScale, forKey: Keys.toolbarScale)
            }
        }
    }

    var isTopBarAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isTopBarAlwaysVisible, forKey: Keys.topBarAlwaysVisible)
            }
        }
    }

    var isFloatingToolbarAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isFloatingToolbarAlwaysVisible, forKey: Keys.floatingToolbarAlwaysVisible)
            }
        }
    }

    var isPageIndicatorAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isPageIndicatorAlwaysVisible, forKey: Keys.pageIndicatorAlwaysVisible)
            }
        }
    }

    /// The tab strip is the Deck: the focused tab full width, the rest as
    /// slivers. Off keeps the full-width, scrolling strip. Enabled by default
    /// (opt-out).
    var isCompactTabsEnabled = true {
        didSet {
            if !isLoading {
                defaults.set(isCompactTabsEnabled, forKey: Keys.compactTabs)
            }
        }
    }

    /// Dock-style icon magnification on the floating toolbar. Enabled by default (opt-out).
    var isToolbarMagnificationEnabled = true {
        didSet {
            if !isLoading {
                defaults.set(isToolbarMagnificationEnabled, forKey: Keys.toolbarMagnificationEnabled)
            }
        }
    }

    /// Hover tooltips (native macOS help tags) on the floating toolbar buttons. Enabled by default (opt-out).
    var showTooltips = true {
        didSet {
            if !isLoading {
                defaults.set(showTooltips, forKey: Keys.showTooltips)
            }
        }
    }

    /// The Markdown editor's forced color scheme. `.system` follows the OS.
    var markdownColorScheme: MarkdownColorScheme = .system {
        didSet {
            if !isLoading {
                defaults.set(markdownColorScheme.rawValue, forKey: Keys.markdownColorScheme)
            }
        }
    }

    /// The Markdown editor's left/right margin in points, user-defined (replaces
    /// the old Readable-line-length toggle). Reconciled LIVE by the engine
    /// (text-container insets), so dragging the slider re-lays mounted editors.
    var markdownSideMargin = Double(DesignTokens.markdownReadingGutter) {
        didSet {
            if !isLoading {
                defaults.set(markdownSideMargin, forKey: Keys.markdownSideMargin)
            }
        }
    }

    /// The Markdown editor's body font family — one of the curated
    /// `markdownFontFamilies`. Headings/code scale off it in the engine.
    var markdownFontFamily = SettingsManager.defaultMarkdownFontFamily {
        didSet {
            if !isLoading {
                defaults.set(markdownFontFamily, forKey: Keys.markdownFontFamily)
            }
        }
    }

    /// The Markdown editor's base body size in points.
    var markdownFontSize = SettingsManager.defaultMarkdownFontSize {
        didSet {
            if !isLoading {
                defaults.set(markdownFontSize, forKey: Keys.markdownFontSize)
            }
        }
    }

    /// Whether the Markdown document centers in the window when zoomed OUT
    /// (magnification < 1), PDF-style. Off = pinned left (default). Reconciled
    /// LIVE by the engine, so the toggle re-lays mounted editors.
    var markdownCentersZoomedOut = false {
        didSet {
            if !isLoading {
                defaults.set(markdownCentersZoomedOut, forKey: Keys.markdownCentersZoomedOut)
            }
        }
    }

    /// Page look: a centered 42-em reading column (doc 18 §4.3).
    var markdownPageLook = true {
        didSet {
            if !isLoading {
                defaults.set(markdownPageLook, forKey: Keys.markdownPageLook)
            }
        }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        loadSettings()
        isLoading = false
    }

    // MARK: - Add/Remove Presets

    func addHighlightPreset() {
        highlightPresets.append(ColorPreset(name: "New", hex: "#FFFF00"))
    }

    func removeHighlightPreset(at index: Int) {
        guard highlightPresets.count > 1, highlightPresets.indices.contains(index) else { return }
        highlightPresets.remove(at: index)
    }

    func addUnderlinePreset() {
        underlinePresets.append(ColorPreset(name: "New", hex: "#000000"))
    }

    func removeUnderlinePreset(at index: Int) {
        guard underlinePresets.count > 1, underlinePresets.indices.contains(index) else { return }
        underlinePresets.remove(at: index)
    }

    func addCommentPreset() {
        commentPresets.append(ColorPreset(name: "New", hex: "#80808099"))
    }

    func removeCommentPreset(at index: Int) {
        guard commentPresets.count > 1, commentPresets.indices.contains(index) else { return }
        commentPresets.remove(at: index)
    }

    // MARK: - Reset

    func resetColors() {
        highlightPresets = Self.defaultHighlightPresets
        underlinePresets = Self.defaultUnderlinePresets
        commentPresets = Self.defaultCommentPresets
    }

    func resetShortcuts() {
        customShortcuts = [:]
    }

    func resetToolbarScale() {
        toolbarScale = Self.defaultToolbarScale
    }

    // MARK: - Persistence

    private func loadSettings() {
        if let data = defaults.data(forKey: Keys.highlightPresets) {
            do {
                highlightPresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode highlight presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.underlinePresets) {
            do {
                underlinePresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode underline presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.commentPresets) {
            do {
                commentPresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode comment presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.customShortcuts) {
            do {
                customShortcuts = try JSONDecoder().decode([String: ShortcutModel].self, from: data)
            } catch {
                logger.error("Failed to decode custom shortcuts: \(error.localizedDescription)")
            }
        }

        if defaults.object(forKey: Keys.toolbarScale) != nil {
            toolbarScale = Self.clampedToolbarScale(defaults.double(forKey: Keys.toolbarScale))
        }

        isTopBarAlwaysVisible = defaults.bool(forKey: Keys.topBarAlwaysVisible)
        isFloatingToolbarAlwaysVisible = defaults.bool(forKey: Keys.floatingToolbarAlwaysVisible)
        isPageIndicatorAlwaysVisible = defaults.bool(forKey: Keys.pageIndicatorAlwaysVisible)
        isCompactTabsEnabled = defaults.object(forKey: Keys.compactTabs) == nil ? true : defaults.bool(forKey: Keys.compactTabs)

        // Opt-out default: only override the `true` default when a value was explicitly stored.
        if defaults.object(forKey: Keys.toolbarMagnificationEnabled) != nil {
            isToolbarMagnificationEnabled = defaults.bool(forKey: Keys.toolbarMagnificationEnabled)
        }

        if defaults.object(forKey: Keys.showTooltips) != nil {
            showTooltips = defaults.bool(forKey: Keys.showTooltips)
        }

        if let raw = defaults.string(forKey: Keys.markdownColorScheme),
           let scheme = MarkdownColorScheme(rawValue: raw) {
            markdownColorScheme = scheme
        }

        if defaults.object(forKey: Keys.markdownSideMargin) != nil {
            markdownSideMargin = min(
                max(defaults.double(forKey: Keys.markdownSideMargin), Self.markdownSideMarginRange.lowerBound),
                Self.markdownSideMarginRange.upperBound
            )
        }

        // Validate against the curated list, not just non-emptiness: fonts we
        // no longer offer (or that were uninstalled) reset to the default so
        // the Settings picker never shows a dangling selection.
        if let family = defaults.string(forKey: Keys.markdownFontFamily),
           Self.markdownFontFamilies.contains(family) {
            markdownFontFamily = family
        }
        let storedSize = defaults.double(forKey: Keys.markdownFontSize)
        if storedSize > 0 {
            // Clamp on load, not just in the Stepper (house precedent: clampedToolbarScale).
            markdownFontSize = min(
                max(storedSize, Self.markdownFontSizeRange.lowerBound),
                Self.markdownFontSizeRange.upperBound
            )
        }

        markdownCentersZoomedOut = defaults.bool(forKey: Keys.markdownCentersZoomedOut)
        markdownPageLook = defaults.object(forKey: Keys.markdownPageLook) == nil ? true : defaults.bool(forKey: Keys.markdownPageLook)
    }

    private func savePresets(_ presets: [ColorPreset], forKey key: String) {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode presets for \(key): \(error.localizedDescription)")
        }
    }

    private func saveShortcuts() {
        do {
            let data = try JSONEncoder().encode(customShortcuts)
            defaults.set(data, forKey: Keys.customShortcuts)
        } catch {
            logger.error("Failed to encode shortcuts: \(error.localizedDescription)")
        }
    }
}
