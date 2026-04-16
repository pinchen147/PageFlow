//
//  TopChromeView.swift
//  PageFlow
//
//  Window-level top chrome: window-drag strip, traffic lights, tab bar, and
//  floating toolbar. Rendered once per window so hover state changes never
//  cascade into inactive tabs' view trees.
//

import SwiftUI

struct TopChromeView: View {
    @Bindable var tabManager: TabManager
    @Binding var isTopBarHovered: Bool
    @State private var settingsManager = SettingsManager.shared

    static func height(toolbarScale: Double) -> CGFloat {
        let metrics = SettingsManager.toolbarMetrics(for: toolbarScale)
        return max(
            DesignTokens.trafficLightHotspotHeight,
            metrics.containerHeight + DesignTokens.windowDragRegionHeight + DesignTokens.spacingXS
        )
    }

    private var totalHeight: CGFloat {
        Self.height(toolbarScale: settingsManager.toolbarScale)
    }

    private var contentHeight: CGFloat {
        totalHeight - DesignTokens.windowDragRegionHeight
    }

    private var isFloatingToolbarVisible: Bool {
        settingsManager.isToolbarPinned || isTopBarHovered
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: DesignTokens.windowDragRegionHeight)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                TrafficLightsView()
                    .padding(DesignTokens.spacingXS)
                    .opacity(isTopBarHovered ? 1 : 0)
                    .allowsHitTesting(isTopBarHovered)

                TabBarView(tabManager: tabManager)
                    .frame(maxWidth: .infinity)
                    .opacity(isTopBarHovered ? 1 : 0)
                    .allowsHitTesting(isTopBarHovered)

                activeFloatingToolbar
                    .padding(.top, DesignTokens.spacingXS)
                    .padding(.trailing, DesignTokens.floatingToolbarPadding)
                    .opacity(isFloatingToolbarVisible ? 1 : 0)
                    .allowsHitTesting(isFloatingToolbarVisible)
            }
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isTopBarHovered { isTopBarHovered = true }
            case .ended:
                if isTopBarHovered { isTopBarHovered = false }
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isTopBarHovered)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isFloatingToolbarVisible)
    }

    @ViewBuilder
    private var activeFloatingToolbar: some View {
        if let activeID = tabManager.activeTabID,
           let managers = tabManager.managers(for: activeID) {
            FloatingToolbar(
                pdfManager: managers.0,
                annotationManager: managers.2,
                commentManager: managers.3,
                bookmarkManager: managers.4,
                onOpenFilePicker: { tabManager.openFilePicker() },
                showingOutline: $tabManager.showingOutline,
                showingComments: $tabManager.showingComments
            )
            .id(activeID)
        } else {
            Color.clear
        }
    }
}
