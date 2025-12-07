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

    // MARK: - Animation

    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.25
}
