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

    static let highlightYellow = NSColor(red: 1.0, green: 0.95, blue: 0.0, alpha: 0.4)
    static let highlightGreen = NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.4)
    static let highlightBlue = NSColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.4)
    static let highlightPink = NSColor(red: 1.0, green: 0.0, blue: 0.5, alpha: 0.4)
    static let underlineColor = NSColor.black

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
    static let floatingToolbarCornerRadius: CGFloat = 22
    static let floatingToolbarHeight: CGFloat = 44
    static let collapsedToolbarSize: CGFloat = 52
    static let toolbarButtonSize: CGFloat = 40
    static let toolbarIconSize: CGFloat = 14
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
}
