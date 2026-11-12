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
    static let text = NSColor.labelColor
    static let separator = NSColor.separatorColor
    static let viewerBackground = NSColor(
        red: 27.0 / 255.0,
        green: 27.0 / 255.0,
        blue: 27.0 / 255.0,
        alpha: 1.0
    )

    // MARK: - Annotation Colors

    static let highlightYellow = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 1.0) // #FFFF00 @100%

    // MARK: - Search Highlight Colors

    /// Find matches look the same in every document type: the current one a
    /// strong yellow, the rest a light one (the macOS convention).
    static let searchCurrentResult = NSColor.systemYellow.withAlphaComponent(0.65)
    static let searchOtherResults = NSColor.systemYellow.withAlphaComponent(0.3)

    // MARK: - Spacing

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // MARK: - Layout

    static let sidebarWidth: CGFloat = 176
    static let thumbnailWidth: CGFloat = 120
    static let sidebarThumbnailWidth: CGFloat = sidebarWidth - 24
    static let dialogWidth: CGFloat = 300
    static let textFieldWidth: CGFloat = 200

    // MARK: - Thumbnail Grid

    static let thumbnailHeight: CGFloat = 170
    static let sidebarThumbnailHeight: CGFloat = 215
    static let thumbnailRenderWidth: CGFloat = 304
    static let thumbnailRenderHeight: CGFloat = 430
    static let thumbnailGridPadding: CGFloat = 8
    static let thumbnailCornerRadius: CGFloat = 4
    static let thumbnailBorderWidth: CGFloat = 2
    static let thumbnailBadgeFontSize: CGFloat = 12

    // MARK: - Settings Window

    static let settingsWindowWidth: CGFloat = 760
    static let settingsWindowHeight: CGFloat = 560
    static let settingsSidebarWidth: CGFloat = 210
    static let colorWellWidth: CGFloat = 44
    static let colorWellHeight: CGFloat = 20
    static let presetRowHeight: CGFloat = 24
    static let shortcutKeyDisplayWidth: CGFloat = 80
    static let shortcutButtonWidth: CGFloat = 100

    // MARK: - Floating Toolbar

    static let floatingToolbarPadding: CGFloat = 16
    static let floatingToolbarCornerRadius: CGFloat = 14
    static let collapsedToolbarSize: CGFloat = 28
    static let toolbarButtonSize: CGFloat = 20
    static let toolbarIconSize: CGFloat = 10
    static let floatingToolbarBase = Color(red: 0.196, green: 0.196, blue: 0.196)

    // MARK: - Liquid Glass

    static let glassPanelTintOpacity: CGFloat = 0.12
    static let sidebarGlassTintOpacity: CGFloat = 0.32
    static let sidebarControlGlassTintOpacity: CGFloat = 0.18
    /// Light-tinted chrome glass adds this to its own tint, capped below, so
    /// labels keep contrast over a white page in dark mode or a dark image in
    /// light mode (see `LegibleGlass`).
    static let legibleGlassBaseTint: CGFloat = 0.5
    static let legibleGlassMaxTint: CGFloat = 0.85
    static let glassElevationShadowOpacity: Double = 0.055
    // Fixed foregrounds for opaque white content cards only (chrome adapts).
    static let glassTextPrimary = Color(red: 0.08, green: 0.08, blue: 0.08)

    // MARK: - Traffic Lights

    static let trafficLightSize: CGFloat = 12
    /// Reserved leading width in the top chrome so the tab strip clears the
    /// native window buttons (close / minimize / zoom).
    static let trafficLightClusterWidth: CGFloat = 70
    static let trafficLightHotspotHeight: CGFloat = 40

    // MARK: - Controls

    /// A disabled control's glyph, relative to an enabled one: macOS's
    /// disabled control text is about 0.25 alpha against the label's 0.85.
    /// Applied once, by the shared toolbar label.
    static let disabledControlOpacity: Double = 0.3

    // MARK: - Animation

    static let animationFast: Double = 0.15

    /// The chrome's spring: the Deck's cards sliding. Reduce Motion swaps it
    /// for a short ease.
    static func chromeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: animationFast) : .spring(duration: 0.45, bounce: 0.1)
    }

    /// The toolbar folding into its sphere and springing open: quicker than
    /// the Deck, since it answers the pointer directly.
    static func toolbarFoldAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: animationFast) : .spring(duration: 0.3, bounce: 0.1)
    }

    // MARK: - Autoscroll (Thumbnail Drag)

    static let autoscrollEdgeZone: CGFloat = 60        // Edge detection zone from viewport edge
    static let autoscrollHysteresis: CGFloat = 10     // Buffer to prevent jitter at boundary
    static let autoscrollDwellTime: Double = 0.075    // Delay before activation (75ms)
    static let autoscrollMinInterval: Double = 0.08   // Fastest scroll speed (at edge)
    static let autoscrollMaxInterval: Double = 0.35   // Slowest scroll speed (at zone boundary)

    // MARK: - PDF Viewer

    nonisolated static let pdfMinScale: CGFloat = 0.1
    nonisolated static let pdfMaxScale: CGFloat = 4.0
    static let pdfDefaultScale: CGFloat = 1.0
    static let pdfViewPadding: CGFloat = 20
    static let pdfFitZoomBump: CGFloat = 0.05
    static let pdfTwoPageGap: CGFloat = 10
    static let pdfControlScrollZoomFactor: CGFloat = 1.1

    /// Markdown visual zoom (NSScrollView magnification, PDF-style). 50%–400%,
    /// with ⌘+/⌘− stepping multiplicatively.
    nonisolated static let markdownMinZoom: CGFloat = 0.5
    nonisolated static let markdownMaxZoom: CGFloat = 4.0
    /// ⌘+/⌘− and the toolbar's zoom buttons step by this factor in every
    /// document type, so a press feels the same everywhere. The zoom limits
    /// are nonisolated so `ZoomRange` can serve off-main page geometry.
    nonisolated static let zoomStepFactor: CGFloat = 1.25

    // MARK: - Markdown Reading

    /// Default left/right margin of the Markdown editor. The LIVE value is the
    /// user setting `SettingsManager.markdownSideMargin`; this is its default.
    static let markdownReadingGutter: CGFloat = 24
    /// Page look (doc 18 §4.3 D6): the reading column's measure in ems of the
    /// body font; the side-margin slider adds gutter on top.
    static let markdownPageMeasureEm: CGFloat = 42
    /// Breathing room between the floating top chrome and the document's first line.
    static let markdownFirstLineGap: CGFloat = 24

    // MARK: - Navigation Rail

    /// The rail sliding in from the leading edge and out to it.
    static let navigationRailSlideDuration: Double = 0.24
    /// How far the rail travels off the leading edge: its lane and a margin.
    static let navigationRailSlideDistance: CGFloat = 56
    /// The preview's leading edge, just past the marks so it reads as the rail's own.
    static let navigationRailPreviewX: CGFloat = 46
    /// The Markdown section preview card.
    static let navigationRailSectionPreviewWidth: CGFloat = 352
    static let navigationRailSectionPreviewHeight: CGFloat = 104

    // MARK: - Search

    static let searchBarWidth: CGFloat = 200
    /// The query and replacement fields and the magnifying glass.
    static let searchFieldFontSize: CGFloat = 14
    /// The result count and the match and close buttons.
    static let searchControlFontSize: CGFloat = 12
    static let searchBarAnimationDuration: Double = 0.2

    // MARK: - Comments

    // #80808099 - must match default preset in SettingsManager (0x99 = 153 = 0.6 alpha)
    static let commentHighlightColor: NSColor = {
        let gray = CGFloat(0x80) / 255.0
        let alpha = CGFloat(0x99) / 255.0
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: alpha)
    }()
    static let commentSidebarWidth: CGFloat = 200
    static let commentTailSize: CGFloat = 8
    static let commentDefaultRectWidth: CGFloat = 140
    static let commentDefaultRectHeight: CGFloat = 32

    // Opaque white content cards retain dark text in either appearance.
    /// The opaque content-card surface, shared by comment bubbles, the thumbnail
    /// letterbox fill, and the tab drag pill so they all read as the same card.
    static let contentCardSurface = Color.white
    static let commentCardBackground = contentCardSurface
    static let commentCardStroke = Color.black.opacity(0.08)
    static let commentCardStrokeSelected = Color(nsColor: .controlAccentColor)
    static let commentTextOpacity: Double = 1.0
    static let commentTextColor = glassTextPrimary
    static let commentTextNSColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    static let commentFontSize: CGFloat = 14
    static let commentBubbleShadowRadius: CGFloat = 8
    static let commentBubbleShadowOpacity: Double = 0.15

    // MARK: - EPUB Highlights

    /// How strongly a highlight colour shows behind book text: enough to read
    /// as the PDF colour on white and sepia paper, a little more on dark.
    static let epubHighlightOpacityLight: CGFloat = 0.38
    static let epubHighlightOpacitySepia: CGFloat = 0.34
    static let epubHighlightOpacityDark: CGFloat = 0.45
    /// Read Aloud: the sentence being read, and the word being said.
    static let epubSpokenSentence = NSColor.systemTeal.withAlphaComponent(0.16)
    static let epubSpokenWord = NSColor.systemTeal.withAlphaComponent(0.45)
    /// The dot in the margin beside a highlight with a note.
    static let epubNoteMarkerSize: CGFloat = 7
    static let epubNoteMarkerGap: CGFloat = 10
    static let epubNoteEditorHeight: CGFloat = 96
    static let epubHighlightSwatchSize: CGFloat = 18
    /// A colour swatch's ring in the note editor, stronger on the current colour.
    static let epubSwatchStrokeOpacity: Double = 0.2
    static let epubSwatchStrokeOpacityCurrent: Double = 0.7
    static let epubSwatchStrokeWidth: CGFloat = 1
    static let epubSwatchStrokeWidthCurrent: CGFloat = 2
    /// The highlight's colour beside its words on a Notes panel card.
    static let epubNoteColorBarWidth: CGFloat = 3
    static let epubNoteColorBarCornerRadius: CGFloat = 1.5
    /// A Notes panel card's outline, as a comment card's: heavier while edited.
    static let epubNoteCardStrokeWidth: CGFloat = 1
    static let epubNoteCardStrokeWidthEditing: CGFloat = 1.5
    static let epubNotesEmptyIconSize: CGFloat = 24

    // MARK: - Sidebar Toggle

    static let sidebarToggleButtonSize: CGFloat = 24
    static let sidebarToggleIconSize: CGFloat = 12

    // MARK: - Window

    static let windowDragRegionHeight: CGFloat = 6
    static let defaultWindowWidth: CGFloat = 900
    static let defaultWindowHeight: CGFloat = 700

    /// The file-drop indicator: a dashed outline around the whole window and a fan
    /// of document glyphs over "Drop files here" in the middle.
    static let fileDropOutlineInset: CGFloat = 8
    static let fileDropOutlineCornerRadius: CGFloat = 12
    static let fileDropOutlineWidth: CGFloat = 2
    static let fileDropOutlineDash: [CGFloat] = [6, 6]
    static let fileDropGlyphSize: CGFloat = 19
    static let fileDropGlyphSpacing: CGFloat = 18
    /// How far the outer glyphs of the fan lean away from the middle one, in degrees.
    static let fileDropGlyphTilt: Double = 16
    /// How much higher the middle glyph sits than the outer two.
    static let fileDropGlyphLift: CGFloat = 9

    // MARK: - Tabs

    static let tabHeight: CGFloat = 26
    static let tabMaxWidth: CGFloat = 160
    static let tabMinWidth: CGFloat = 80
    static let tabSpacing: CGFloat = 2
    static let tabCornerRadius: CGFloat = 6
    static let tabBarLeftMargin: CGFloat = 80
    static let tabCloseButtonSize: CGFloat = 14
    static let tabDirtyIndicatorSize: CGFloat = 6
    /// How much of a tucked-away tab shows in the compact tab strip (the Deck).
    static let tabDeckSliverWidth: CGFloat = 18
    /// The round glass icon buttons in the chrome (new tab, tab switcher).
    static let chromeIconSize: CGFloat = 24

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
