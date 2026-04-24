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
    @State private var dragController = TabDragController.shared

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

    private var isTabBarVisible: Bool {
        isTopBarHovered || dragController.isActive
    }

    private var revealAnimation: Animation {
        .easeInOut(duration: DesignTokens.animationFast)
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: DesignTokens.windowDragRegionHeight)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                TrafficLightsView()
                    .padding(DesignTokens.spacingXS)
                    .opacity(isTabBarVisible ? 1 : 0)
                    .allowsHitTesting(isTabBarVisible)

                TabBarView(tabManager: tabManager)
                    .frame(maxWidth: .infinity)
                    .opacity(isTabBarVisible ? 1 : 0)
                    .allowsHitTesting(isTabBarVisible)

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
        // NSTrackingArea-based hover. `.onContinuousHover` gets pre-empted
        // when child NSViewRepresentables (TabBarMouseView, WindowDragArea)
        // install their own tracking areas — enter/exit events stutter.
        // The AppKit path fires on `mouseEntered` / `mouseExited` directly
        // and ignores child event capture.
        .overlay(HoverTrackingArea(isHovered: $isTopBarHovered))
        .animation(revealAnimation, value: isTabBarVisible)
        .animation(revealAnimation, value: isFloatingToolbarVisible)
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
