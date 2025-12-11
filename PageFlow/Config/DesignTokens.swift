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

    static let highlightYellow = NSColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 0.6) // #FFFF00 @60%
    static let highlightGreen = NSColor(red: 0.0, green: 0.7, blue: 0.258, alpha: 0.6) // #00B342 @60%
    static let highlightRed = NSColor(red: 0.824, green: 0.0, blue: 0.0, alpha: 0.6) // #D20000 @60%
    static let highlightBlue = NSColor(red: 0.0, green: 0.447, blue: 0.776, alpha: 0.6) // #0072C6 @60%
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

    // MARK: - Floating Toolbar

    static let floatingToolbarPadding: CGFloat = 16
    static let floatingToolbarCornerRadius: CGFloat = 14
    static let floatingToolbarHeight: CGFloat = 28
    static let collapsedToolbarSize: CGFloat = 28
    static let toolbarButtonSize: CGFloat = 20
    static let toolbarIconSize: CGFloat = 10
    static let floatingToolbarBase = Color(red: 0.196, green: 0.196, blue: 0.196)

    // MARK: - Traffic Lights

    static let trafficLightSize: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8
    static let trafficLightContainerPadding: CGFloat = 8
    static let trafficLightHotspotWidth: CGFloat = 180
    static let trafficLightHotspotHeight: CGFloat = 40

    // MARK: - Animation

    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.25

    // MARK: - PDF Viewer

    static let pdfMinScale: CGFloat = 0.25
    static let pdfMaxScale: CGFloat = 4.0
    static let pdfDefaultScale: CGFloat = 1.0
    static let pdfZoomStep: CGFloat = 0.25

    // MARK: - Comments

    static let commentHighlightColor = NSColor.gray.withAlphaComponent(0.6)
    static let commentSidebarWidth: CGFloat = 260
    static let commentBubbleCornerRadius: CGFloat = 12
    static let commentTailSize: CGFloat = 8
    static let commentDefaultRectWidth: CGFloat = 140
    static let commentDefaultRectHeight: CGFloat = 32
    static let commentNoteIconSize: CGFloat = 24
    static let commentNoteOffset: CGFloat = 12

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
}
