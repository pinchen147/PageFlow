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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Toolbar fold (see `ToolbarFold`): measured widths, and the peek
    // (`ToolbarPeek`) with its fold grace timer.
    @State private var tabsWidth: CGFloat = 0
    @State private var tabStripWidth: CGFloat = 0
    @State private var toolbarSlotWidth: CGFloat = 0
    @State private var toolbarOpenWidth: CGFloat = 0
    @State private var peek = ToolbarPeek()
    @State private var foldTimer: Task<Void, Never>?

    /// Grace before an open toolbar folds after the pointer leaves it.
    private static let foldDelay: Duration = .milliseconds(300)

    static func height(toolbarScale: Double) -> CGFloat {
        let metrics = SettingsManager.toolbarMetrics(for: toolbarScale)
        return max(
            DesignTokens.trafficLightHotspotHeight,
            metrics.containerHeight + DesignTokens.windowDragRegionHeight + DesignTokens.spacingXS
        )
    }

    private var metrics: SettingsManager.ToolbarMetrics {
        SettingsManager.toolbarMetrics(for: settingsManager.toolbarScale)
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

    /// The toolbar — open or as its sphere — shows with the tabs, or always
    /// when pinned open.
    private var isToolbarVisible: Bool {
        settingsManager.isFloatingToolbarAlwaysVisible || isTopBarVisible
    }

    private var fold: ToolbarFold {
        ToolbarFold(
            isPinned: settingsManager.isFloatingToolbarAlwaysVisible,
            isPeeking: peek.isPeeking,
            tabsWidth: tabsWidth,
            tabStripWidth: tabStripWidth,
            slotWidth: toolbarSlotWidth,
            openWidth: toolbarOpenWidth
        )
    }

    private var foldAnimation: Animation {
        DesignTokens.toolbarFoldAnimation(reduceMotion: reduceMotion)
    }

    var body: some View {
        let fold = fold

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

                    // A toolbar floating past the whole strip covers the chevron;
                    // its AppKit click target must not take the toolbar's clicks.
                    TabSwitcherChevron(
                        tabManager: tabManager,
                        isInteractive: isTopBarVisible && !fold.coversTabSwitcher
                    )
                    .opacity(fold.coversTabSwitcher ? 0 : 1)

                    TabBarView(
                        tabManager: tabManager,
                        compactTabs: settingsManager.isCompactTabsEnabled,
                        isInteractive: isTopBarVisible,
                        occludedTrailingWidth: fold.coveredStripWidth
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabStripWidth = $0 }
                }
                .frame(maxWidth: .infinity)
                .opacity(isTopBarVisible ? 1 : 0)
                .allowsHitTesting(isTopBarVisible)

                toolbarSlot(fold)
            }
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight)
            .animation(foldAnimation, value: fold.holdsWidth)
        }
        .frame(maxWidth: .infinity)
        .frame(height: totalHeight)
        .overlay(ChromeHoverSensor(isHovered: $isHoveringChrome))
        .overlay(alignment: .trailing) { peekZone(fold) }
        .background(WindowChromeVisibilityReporter(isTrafficLightsVisible: isTopBarVisible))
        .onPreferenceChange(TabStripWidthPreferenceKey.self) { tabsWidth = $0 }
        .onPreferenceChange(FloatingToolbarWidthPreferenceKey.self) { width in
            if width > 0 { toolbarOpenWidth = width }
        }
        .onChange(of: isToolbarVisible) { _, visible in
            if !visible { send(.dismissed) }
        }
        .onChange(of: dragController.isActive) { _, dragging in
            if dragging { send(.dismissed) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            send(.menuOpened)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            send(.menuClosed)
        }
    }

    /// The toolbar's slot keeps its width while the chrome is hidden, so the
    /// tabs never re-lay out at reveal. Pinned and fitting, it holds the open
    /// toolbar's width; otherwise the sphere's, and the open toolbar floats
    /// leftward over the tabs.
    private func toolbarSlot(_ fold: ToolbarFold) -> some View {
        Color.clear
            .frame(width: fold.holdsWidth ? toolbarOpenWidth : metrics.containerHeight, height: metrics.containerHeight)
            .overlay(alignment: .trailing) {
                if isToolbarVisible {
                    ActiveFloatingToolbar(tabManager: tabManager)
                        .environment(\.toolbarFold, foldControl(fold))
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                }
            }
            .animation(foldAnimation, value: isToolbarVisible)
            // The toolbar's placement in the slot animates with its width, so
            // its trailing edge stays on the sphere and it grows leftward out
            // of it (the shell animates only its own width).
            .animation(foldAnimation, value: fold.isOpen)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { toolbarSlotWidth = $0 }
            .padding(.top, DesignTokens.spacingXS)
            .padding(.trailing, DesignTokens.floatingToolbarPadding)
            .zIndex(1)
    }

    // MARK: - Toolbar Fold

    /// Where the open toolbar will be, which opens it (`ToolbarFold.peekReach`),
    /// the full height of the chrome: the pointer needn't land on the sphere.
    /// It senses only — clicks and window drags pass through — and snaps to
    /// its new width instead of animating with the fold.
    private func peekZone(_ fold: ToolbarFold) -> some View {
        ChromeHoverSensor { hovering in
            send(hovering ? .pointerEntered(isOpen: self.fold.isOpen, isDragging: dragController.isActive) : .pointerExited)
        }
        .frame(width: fold.peekReach + DesignTokens.floatingToolbarPadding, height: totalHeight)
        .transaction { $0.animation = nil }
    }

    private func foldControl(_ fold: ToolbarFold) -> ToolbarFoldControl {
        ToolbarFoldControl(
            isOpen: fold.isOpen,
            offersPin: fold.offersPin,
            onUnpin: {
                settingsManager.isFloatingToolbarAlwaysVisible = false
                send(.unpinned)
            },
            onPin: {
                settingsManager.isFloatingToolbarAlwaysVisible = true
                send(.pinned)
            }
        )
    }

    /// Runs a peek event and the fold grace timer it asks for. The toolbar
    /// opens the moment the pointer reaches the peek zone (a click meant for
    /// the sphere lands on the open toolbar's trailing button, in the same
    /// place).
    private func send(_ event: ToolbarPeek.Event) {
        switch peek.handle(event) {
        case .keep:
            break
        case .cancel:
            foldTimer?.cancel()
            foldTimer = nil
        case .start:
            foldTimer?.cancel()
            foldTimer = Task {
                try? await Task.sleep(for: Self.foldDelay)
                guard !Task.isCancelled else { return }
                send(.graceElapsed)
            }
        }
    }

    private var trafficLightsReservedSpace: some View {
        // Reserve leading space so the tab strip clears the native window buttons.
        Color.clear
            .frame(width: DesignTokens.trafficLightClusterWidth, height: DesignTokens.trafficLightSize)
            .allowsHitTesting(false)
    }
}

/// The ONE toolbar slot, content-routed through `TabRender` — the same routing
/// authority every mount site switches over, so a future content type is a
/// compile error here too. A PDF tab shows the PDF FloatingToolbar, a Markdown
/// tab the MarkdownFormatToolbar: same Liquid Glass shell, same position,
/// different item set. Its own view so a fold or peek in the chrome (which
/// reaches the shell through the environment) never rebuilds the item set.
private struct ActiveFloatingToolbar: View {
    @Bindable var tabManager: TabManager

    var body: some View {
        switch tabManager.activeRender {
        case .pdf(let runtime):
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
        case .markdown(let runtime):
            MarkdownFormatToolbar(
                content: runtime.content,
                onOpenFilePicker: { tabManager.openFilePicker() },
                showingOutline: $tabManager.showingOutline
            )
            .id(runtime.tabID)
        case nil:
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
    private let report: (Bool) -> Void

    init(isHovered: Binding<Bool>) {
        report = { hovering in
            guard isHovered.wrappedValue != hovering else { return }
            isHovered.wrappedValue = hovering
        }
    }

    /// Reports enter/exit without storing it in view state, for a caller
    /// whose body must not re-run on every hover change.
    init(onHoverChanged: @escaping (Bool) -> Void) {
        report = onHoverChanged
    }

    func makeNSView(context: Context) -> ChromeHoverNSView {
        let view = ChromeHoverNSView()
        view.onHoverChanged = report
        return view
    }

    func updateNSView(_ nsView: ChromeHoverNSView, context: Context) {
        nsView.onHoverChanged = report
    }
}

final class ChromeHoverNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Re-create every call (StablePDFView pattern): a tracking area kept
        // across a window re-parent stays registered with the OLD window and
        // goes inert — installed, enabled, and silent. This is how torn-off /
        // re-hosted windows lost their hover reveal (traffic lights "gone").
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // .activeInActiveApp, not .activeInKeyWindow: native traffic lights
        // reveal on hover in non-key windows too — a freshly torn-off window
        // isn't key until first clicked.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .enabledDuringMouseDrag, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        // A view that grows under or shrinks away from a resting pointer
        // gets no enter/exit event; re-read where the pointer is. A turn
        // later: AppKit updates tracking areas inside layout, and the report
        // changes the chrome's state.
        DispatchQueue.main.async { [weak self] in self?.refreshHoverState() }
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit does NOT reliably re-invoke updateTrackingAreas after a
        // direct window-to-window re-parent — re-arm explicitly so the fresh
        // area registers with THIS window (verified live: areas existed but
        // never fired in the re-hosted window).
        updateTrackingAreas()
        refreshHoverState()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        // The area's registration belongs to the old window: drop it on ANY
        // window change, not just teardown. viewDidMoveToWindow re-arms.
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        if newWindow == nil {
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
