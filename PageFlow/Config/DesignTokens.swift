//
//  DesignTokens.swift
//  PageFlow
//
//  Design system - Single source of truth for colors, spacing, and layout constants
//

import AppKit
import SwiftUI

struct DesignTokens {
    // MARK: - Colors (macOS native)

    static let background = NSColor.windowBackgroundColor
    static let secondaryBackground = NSColor.controlBackgroundColor
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let accent = NSColor.controlAccentColor
    static let separator = NSColor.separatorColor
    static let viewerBackground = NSColor(
        red: 27.0 / 255.0,
        green: 27.0 / 255.0,
        blue: 27.0 / 255.0,
        alpha: 1.0
    )

    // MARK: - Annotation Colors

    static let highlightYellow = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0) // #FFFF00 @100%
    static let highlightGreen = NSColor(red: 0.0, green: 0.7, blue: 0.258, alpha: 1.0) // #00B342 @100%
    static let highlightRed = NSColor(red: 0.824, green: 0.0, blue: 0.0, alpha: 1.0) // #D20000 @100%
    static let highlightBlue = NSColor(red: 0.0, green: 0.447, blue: 0.776, alpha: 1.0) // #0072C6 @100%
    static let underlineColor = NSColor.black
    static let underlineYellow = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0) // #FFFF00
    static let underlineGreen = NSColor(red: 0.0, green: 0.7, blue: 0.258, alpha: 1.0) // #00B342
    static let underlineRed = NSColor(red: 0.824, green: 0.0, blue: 0.0, alpha: 1.0) // #D20000
    static let underlineBlue = NSColor(red: 0.0, green: 0.447, blue: 0.776, alpha: 1.0) // #0072C6

    // MARK: - Search Highlight Colors

    static let searchCurrentResult = NSColor(red: 0.6, green: 0, blue: 0, alpha: 0.6)
    static let searchOtherResults = NSColor(red: 0, green: 0, blue: 0.6, alpha: 0.6)

    // MARK: - Text Selection

    static let textSelectionColor = NSColor(red: 0.494, green: 0.769, blue: 0.878, alpha: 0.3)

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Layout

    static let sidebarWidth: CGFloat = 200
    static let thumbnailWidth: CGFloat = 120
    static let toolbarHeight: CGFloat = 38
    static let dialogWidth: CGFloat = 300
    static let textFieldWidth: CGFloat = 200

    // MARK: - Thumbnail Grid

    static let thumbnailHeight: CGFloat = 170
    static let thumbnailRenderWidth: CGFloat = 240
    static let thumbnailRenderHeight: CGFloat = 340
    static let thumbnailGridPadding: CGFloat = 12
    static let thumbnailCornerRadius: CGFloat = 4
    static let thumbnailBorderWidth: CGFloat = 2
    static let thumbnailBadgeFontSize: CGFloat = 12

    // MARK: - Settings Window

    static let settingsWindowWidth: CGFloat = 500
    static let settingsWindowHeight: CGFloat = 450
    static let colorWellWidth: CGFloat = 44
    static let colorWellHeight: CGFloat = 20
    static let presetRowHeight: CGFloat = 24
    static let shortcutKeyDisplayWidth: CGFloat = 80
    static let shortcutButtonWidth: CGFloat = 100

    // MARK: - Floating Toolbar

    static let floatingToolbarPadding: CGFloat = 16
    static let floatingToolbarCornerRadius: CGFloat = 14
    static let floatingToolbarHeight: CGFloat = 28
    static let collapsedToolbarSize: CGFloat = 28
    static let toolbarButtonSize: CGFloat = 20
    static let toolbarIconSize: CGFloat = 10
    static let floatingToolbarBase = Color(red: 0.196, green: 0.196, blue: 0.196)

    // MARK: - Liquid Glass

    static let glassPanelTintOpacity: CGFloat = 0.12
    static let glassControlTintOpacity: CGFloat = 0.06
    static let sidebarGlassTintOpacity: CGFloat = 0.32
    static let sidebarControlGlassTintOpacity: CGFloat = 0.18
    static let glassElevationShadowOpacity: Double = 0.055
    static let glassTextPrimary = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let glassTextSecondary = Color(red: 0.24, green: 0.24, blue: 0.24)
    static let glassTextTertiary = Color(red: 0.42, green: 0.42, blue: 0.42)
    static let glassControlForeground = glassTextPrimary
    static let glassGlyphHighlight = Color.white.opacity(0.78)
    static let glassGlyphShadow = Color.black.opacity(0.28)
    static let sidebarPrimaryText = glassTextPrimary
    static let sidebarSecondaryText = glassTextSecondary
    static let sidebarTertiaryText = glassTextTertiary

    // MARK: - Traffic Lights

    static let trafficLightSize: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    static let trafficLightContainerPadding: CGFloat = 8
    static let trafficLightHotspotWidth: CGFloat = 180
    static let trafficLightHotspotHeight: CGFloat = 40

    // MARK: - Animation

    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.25

    // MARK: - Autoscroll (Thumbnail Drag)

    static let autoscrollEdgeZone: CGFloat = 60        // Edge detection zone from viewport edge
    static let autoscrollHysteresis: CGFloat = 10     // Buffer to prevent jitter at boundary
    static let autoscrollDwellTime: Double = 0.075    // Delay before activation (75ms)
    static let autoscrollMinInterval: Double = 0.08   // Fastest scroll speed (at edge)
    static let autoscrollMaxInterval: Double = 0.35   // Slowest scroll speed (at zone boundary)

    // MARK: - PDF Viewer

    static let pdfMinScale: CGFloat = 0.1
    static let pdfMaxScale: CGFloat = 4.0
    static let pdfDefaultScale: CGFloat = 1.0
    static let pdfZoomStep: CGFloat = 0.25
    static let pdfViewPadding: CGFloat = 20
    static let pdfFitZoomBump: CGFloat = 0.05
    static let pdfTwoPageGap: CGFloat = 10
    static let pdfControlScrollZoomFactor: CGFloat = 1.1

    // MARK: - Search

    static let searchBarWidth: CGFloat = 200

    // MARK: - Comments

    // #80808099 - must match default preset in SettingsManager (0x99 = 153 = 0.6 alpha)
    static let commentHighlightColor: NSColor = {
        let gray = CGFloat(0x80) / 255.0
        let alpha = CGFloat(0x99) / 255.0
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: alpha)
    }()
    static let commentSidebarWidth: CGFloat = sidebarWidth
    static let commentBubbleCornerRadius: CGFloat = 12
    static let commentTailSize: CGFloat = 8
    static let commentDefaultRectWidth: CGFloat = 140
    static let commentDefaultRectHeight: CGFloat = 32
    static let commentNoteIconSize: CGFloat = 24
    static let commentNoteOffset: CGFloat = 12

    // Comment bubble styling (glassmorphism)
    static let commentBubbleBackground: Double = 0.18
    static let commentBubbleBackgroundSelected: Double = 0.28
    static let commentTextOpacity: Double = 1.0
    static let commentTextColor = glassTextPrimary
    static let commentTextNSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    static let commentFontSize: CGFloat = 14
    static let commentBubbleShadowRadius: CGFloat = 8
    static let commentBubbleShadowOpacity: Double = 0.15

    // MARK: - Sidebar Toggle

    static let sidebarToggleButtonSize: CGFloat = 24
    static let sidebarToggleIconSize: CGFloat = 12
    static let sidebarToggleCornerRadius: CGFloat = 4
    static let sidebarToggleContainerCornerRadius: CGFloat = 6
    static let sidebarToggleContainerPadding: CGFloat = 2

    // MARK: - Window

    static let windowDragRegionHeight: CGFloat = 6
    static let defaultWindowWidth: CGFloat = 900
    static let defaultWindowHeight: CGFloat = 700

    // MARK: - Tabs

    static let tabBarHeight: CGFloat = 32
    static let tabHeight: CGFloat = 26
    static let tabMaxWidth: CGFloat = 160
    static let tabMinWidth: CGFloat = 80
    static let tabSpacing: CGFloat = 2
    static let tabCornerRadius: CGFloat = 6
    static let tabBarLeftMargin: CGFloat = 80
    static let tabCloseButtonSize: CGFloat = 14
    static let tabDirtyIndicatorSize: CGFloat = 6

    // MARK: - Timing (PDFKit workaround delays)

    /// Brief delay for PDFKit layout to settle after document/scale changes
    static let pdfLayoutSettleDelay: TimeInterval = 0.05
    /// Delay for PDFKit to update layout after display mode changes
    static let pdfDisplayModeSettleDelay: TimeInterval = 0.1
    /// Interval between retries when waiting for PDFView to become ready
    static let pdfViewReadyRetryInterval: TimeInterval = 0.1
    /// Maximum retries when waiting for PDFView/window readiness
    static let maxReadinessRetries: Int = 10
}
