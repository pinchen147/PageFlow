//
//  TopChromeView.swift
//  PageFlow
//
//  Window-level top chrome: window-drag strip, traffic lights, tab bar, and
//  floating toolbar. Rendered once per window so inactive tabs stay isolated.
//

import SwiftUI
import AppKit

struct TopChromeView: View {
    @Bindable var tabManager: TabManager
    @State private var settingsManager = SettingsManager.shared
    @State private var dragController = TabDragController.shared
    @State private var isHoveringChrome = false

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

    private var isChromeRevealed: Bool {
        isHoveringChrome || dragController.isActive
    }

    private var isTopBarVisible: Bool {
        settingsManager.isTopBarAlwaysVisible || isChromeRevealed
    }

    private var isFloatingToolbarVisible: Bool {
        settingsManager.isFloatingToolbarAlwaysVisible || isChromeRevealed
    }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: DesignTokens.windowDragRegionHeight)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                // The tab bar stays mounted while hidden — reveal is an opacity
                // flip, not a subtree rebuild, so hover doesn't hitch and the
                // bar's scroll position survives. `isInteractive` unmounts its
                // AppKit overlays (mouse routing, window-drag), keeping the
                // hidden strip hit-test-transparent.
                HStack(spacing: 0) {
                    trafficLightsReservedSpace
                        .padding(DesignTokens.spacingXS)

                    TabSwitcherChevron(tabManager: tabManager, isInteractive: isTopBarVisible)

                    TabBarView(tabManager: tabManager, isInteractive: isTopBarVisible)
                }
                .frame(maxWidth: .infinity)
                .opacity(isTopBarVisible ? 1 : 0)
                .allowsHitTesting(isTopBarVisible)

                if isFloatingToolbarVisible {
                    activeFloatingToolbar
                        .padding(.top, DesignTokens.spacingXS)
                        .padding(.trailing, DesignTokens.floatingToolbarPadding)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .overlay(ChromeHoverSensor(isHovered: $isHoveringChrome))
        .background(WindowChromeVisibilityReporter(isTrafficLightsVisible: isTopBarVisible))
    }

    private var trafficLightsReservedSpace: some View {
        // Reserve leading space so the tab strip clears the native window buttons.
        Color.clear
            .frame(width: DesignTokens.trafficLightClusterWidth, height: DesignTokens.trafficLightSize)
            .allowsHitTesting(false)
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
}

private struct WindowChromeVisibilityReporter: NSViewRepresentable {
    let isTrafficLightsVisible: Bool

    func makeNSView(context: Context) -> WindowChromeVisibilityReporterView {
        let view = WindowChromeVisibilityReporterView()
        view.isTrafficLightsVisible = isTrafficLightsVisible
        return view
    }

    func updateNSView(_ nsView: WindowChromeVisibilityReporterView, context: Context) {
        nsView.isTrafficLightsVisible = isTrafficLightsVisible
    }
}

private final class WindowChromeVisibilityReporterView: NSView {
    var isTrafficLightsVisible = false {
        didSet {
            applyVisibility()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyVisibility(animated: false)
    }

    private func applyVisibility(animated: Bool = true) {
        guard let window else { return }
        let controller = WindowChromeController.attached(to: window) ?? WindowChromeController.installIfNeeded(on: window)
        controller.setTrafficLightsVisible(isTrafficLightsVisible, animated: animated)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct ChromeHoverSensor: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> ChromeHoverNSView {
        let view = ChromeHoverNSView()
        view.onHoverChanged = updateHover
        return view
    }

    func updateNSView(_ nsView: ChromeHoverNSView, context: Context) {
        nsView.onHoverChanged = updateHover
    }

    private func updateHover(_ hovering: Bool) {
        guard isHovered != hovering else { return }
        isHovered = hovering
    }
}

final class ChromeHoverNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        if newWindow == nil {
            if let trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            setHovering(false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func refreshHoverState() {
        guard let window else {
            setHovering(false)
            return
        }

        setHovering(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        onHoverChanged?(hovering)
    }
}
