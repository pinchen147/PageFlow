//
//  DocumentStatusChip.swift
//  PageFlow
//
//  The bottom-trailing chip every document shows (PDF "Page 3 of 12",
//  Markdown's word count): glass, shown on hover or always per Settings,
//  and a button that opens the document's Go to dialog.
//

import SwiftUI

/// The bottom strip that reveals the status chip on hover. It fades in and
/// out rather than popping; a fade is already free of motion, so Reduce
/// Motion keeps it.
///
/// The chip shows the longest of its labels the room allows, and none when
/// not even the shortest fits. `centerReservation` is a width kept free in the
/// middle of the strip, for the Find bar centred there.
struct DocumentStatusBar: View {
    let label: String
    var shorterLabels: [String] = []
    var centerReservation: CGFloat = 0
    var notice: DocumentStatusNotice?
    let help: String
    let height: CGFloat
    let action: () -> Void

    @State private var isHovering = false
    @State private var settingsManager = SettingsManager.shared

    private var isVisible: Bool {
        settingsManager.isPageIndicatorAlwaysVisible || isHovering
    }

    var body: some View {
        GeometryReader { strip in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if isVisible {
                    ViewThatFits(in: .horizontal) {
                        ForEach([label] + shorterLabels, id: \.self) { form in
                            DocumentStatusChip(label: form, notice: notice, help: help, action: action)
                        }
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .frame(width: chipRoom(in: strip.size.width), alignment: .trailing)
                    .transition(.opacity)
                }
            }
            .frame(width: strip.size.width, height: strip.size.height)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isVisible)
        .overlay(ChromeHoverSensor(isHovered: $isHovering))
    }

    /// The whole strip, or what's right of the reservation.
    private func chipRoom(in width: CGFloat) -> CGFloat {
        max(0, centerReservation > 0 ? (width - centerReservation) / 2 : width)
    }
}

/// Something about the document the reader can ask to see again, from an
/// info button in the chip.
struct DocumentStatusNotice {
    let message: String
    let show: () -> Void
}

/// The chip itself: digits keep their width so the label does not shimmer
/// as the page or count changes.
struct DocumentStatusChip: View {
    let label: String
    var notice: DocumentStatusNotice?
    let help: String
    let action: () -> Void

    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.leading, DesignTokens.spacingSM + 2)
                    .padding(.trailing, notice == nil ? DesignTokens.spacingSM + 2 : DesignTokens.spacingXS)
                    .padding(.vertical, DesignTokens.spacingSM)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .toolbarTooltip(help, enabled: settingsManager.showTooltips)
            if let notice {
                Button(action: notice.show) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.leading, DesignTokens.spacingXS)
                        .padding(.trailing, DesignTokens.spacingSM + 2)
                        .padding(.vertical, DesignTokens.spacingSM)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .accessibilityLabel(notice.message)
                .toolbarTooltip(notice.message, enabled: settingsManager.showTooltips)
            }
        }
        .pageFlowLiquidGlassSurface(.pageIndicator)
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: 10, y: -3)
        .padding(.bottom, DesignTokens.spacingXS)
        .padding(.trailing, DesignTokens.spacingMD)
    }
}
