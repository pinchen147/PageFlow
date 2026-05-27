//
//  WindowChromeContent.swift
//  PageFlow
//
//  The SwiftUI chrome (traffic lights + tab strip + floating toolbar) hosted
//  inside the per-window NSToolbar. Replaces TopChromeView's responsibilities
//  but without any hover/opacity logic — the toolbar's own isVisible (driven
//  by WindowChromeController) handles show/hide.
//

import SwiftUI

struct WindowChromeContent: View {
    @Bindable var tabManager: TabManager
    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        HStack(spacing: 0) {
            TrafficLightsView()
                .padding(DesignTokens.spacingXS)

            TabBarView(tabManager: tabManager)
                .frame(maxWidth: .infinity)

            activeFloatingToolbar
                .padding(.top, DesignTokens.spacingXS)
                .padding(.trailing, DesignTokens.floatingToolbarPadding)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var activeFloatingToolbar: some View {
        if let runtime = tabManager.activeRuntime {
            FloatingToolbar(
                pdfManager: runtime.pdfManager,
                annotationManager: runtime.annotationManager,
                commentManager: runtime.commentManager,
                bookmarkManager: runtime.bookmarkManager,
                onOpenFilePicker: { tabManager.openFilePicker() },
                showingOutline: $tabManager.showingOutline,
                showingComments: $tabManager.showingComments
            )
            .id(runtime.tabID)
        } else {
            Color.clear
        }
    }

    /// Toolbar height the host view requests from NSToolbar. Computed from
    /// the same metrics TopChromeView used so the layout matches the prior
    /// SwiftUI-overlay version pixel-for-pixel.
    static func intrinsicHeight(toolbarScale: Double) -> CGFloat {
        let metrics = SettingsManager.toolbarMetrics(for: toolbarScale)
        return max(
            DesignTokens.trafficLightHotspotHeight,
            metrics.containerHeight + DesignTokens.spacingXS
        )
    }
}
