//
//  TabContainerView.swift
//  PageFlow
//
//  Root container view for tab management. Each window owns its own TabManager.
//

import SwiftUI
import AppKit

struct TabContainerView: View {
    @Environment(RecentFilesManager.self) private var recentFilesManager
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var settingsManager = SettingsManager.shared

    /// Holds this window's `TabManager`, constructed lazily on first use.
    ///
    /// SwiftUI re-runs a view's `init` on every scene/body recomputation. With
    /// `State(wrappedValue: TabManager())` that built — then immediately threw
    /// away — a full `TabManager` (five managers + wiring) on each of those
    /// passes; with a second scene open that invalidates often, it churned
    /// hundreds of throwaway managers and dominated frame time. The holder defers
    /// construction to first access, so a re-init costs nothing.
    @State private var holder: TabManagerHolder

    /// Default init: each window lazily creates its own TabManager.
    init() {
        self._holder = State(wrappedValue: TabManagerHolder())
    }

    /// Tear-off init: the caller hands us a pre-populated TabManager (e.g.
    /// one that already contains the dragged-out tab). The window opens with
    /// that state already in place — no race, no placeholder dance.
    init(tabManager: TabManager) {
        self._holder = State(wrappedValue: TabManagerHolder(adopting: tabManager))
    }

    /// This window's TabManager, stable for the view's lifetime.
    private var tabManager: TabManager { holder.manager }

    /// A Markdown tab can be forced light or dark (Settings); the drop indicator
    /// follows the page it is drawn over, else the Mac's appearance.
    private var dropIndicatorColorScheme: ColorScheme {
        guard let id = tabManager.activeTabID, tabManager.contentKind(for: id) == .markdown else {
            return systemColorScheme
        }
        return settingsManager.markdownColorScheme.forcedColorScheme ?? systemColorScheme
    }

    private var showingSearch: Binding<Bool> {
        Binding(get: { tabManager.showingSearch }, set: { tabManager.showingSearch = $0 })
    }

    private var activeWindowTitle: String {
        tabManager.activeSession?.content.document.documentTitle ?? "PageFlow"
    }

    /// One warm tab in the ZStack: the active tab is visible, hit-testable and
    /// on top; the rest stay mounted, hidden at full size (the editor inside is
    /// hidden at the AppKit level and does no work), so switching back is an
    /// instant show. `.id(tabID)` keeps each tab's PDFViewWrapper Coordinator
    /// bound to that tab's managers.
    @ViewBuilder
    private func warmTab(for render: TabRender) -> some View {
        let isActiveTab = render.id == tabManager.activeTabID
        TabRenderView(
            render: render,
            isActive: isActiveTab,
            isDisplayed: isActiveTab,
            showingSearch: showingSearch,
            searchFocusRequest: tabManager.searchFocusRequest,
            tabManager: tabManager
        )
        .id(render.id)
        .opacity(isActiveTab ? 1 : 0)
        .allowsHitTesting(isActiveTab)
        .zIndex(isActiveTab ? 1 : 0)
        .accessibilityHidden(!isActiveTab)
    }

    /// Every warm tab (TabManager.renderedTabs, LRU-capped) in one ZStack, so
    /// ⌘-number / ⌘[ ⌘] switching is an instant show rather than a teardown +
    /// cold rebuild. Only the active tab keeps its window-wide event monitors
    /// installed (driven by `isActive`); the LRU cap frees least-recently-used
    /// tabs. Per-tab reading position is restored by TabManager.restoreTabState
    /// + DocumentStateStore.
    private var content: some View {
        ZStack {
            ForEach(tabManager.renderedTabs) { render in
                warmTab(for: render)
            }
        }
    }

    var body: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .top) {
            TopChromeView(tabManager: tabManager)
                .ignoresSafeArea(.all, edges: .top)
        }
        // The ONE transient pill for this window ("Saved", open failures) —
        // content-agnostic, mounted once so PDF and Markdown can't drift.
        .overlay(alignment: .bottom) {
            TransientToastOverlay(tabManager: tabManager)
        }
        // The ONE file-drop indicator for this window, around the whole window
        // and above the chrome, in the active document's light or dark.
        .overlay {
            FileDropOverlay(isVisible: tabManager.isFileDropHovering)
                .environment(\.colorScheme, dropIndicatorColorScheme)
        }
        .toolbar(.hidden)
        .background(WindowConfigurator(isAlwaysOnTop: tabManager.isAlwaysOnTop))
        .background(WindowTitleUpdater(title: activeWindowTitle))
        .background(WindowRegistrar(tabManager: tabManager))
        .focusedSceneValue(\.tabManager, tabManager)
        .onAppear {
            tabManager.documentOpenedHandler = { [recentFilesManager] url, isSecurityScoped in
                recentFilesManager.addRecentFile(url, isSecurityScoped: isSecurityScoped)
            }

            // Deliver immediately if already registered. Otherwise keep launch
            // URLs queued for WindowRegistrar so restore can deduplicate them.
            if let appDelegate = AppDelegate.shared {
                appDelegate.flushPendingURLs(to: tabManager)
            }
        }
        .onOpenURL { url in
            guard url.pageFlowIsOpenableDocument else { return }
            tabManager.closeFilePicker()
            tabManager.openDocument(url: url, isSecurityScoped: false)
        }
        .onDisappear {
            tabManager.flushActiveTabViewState()
            WindowRegistry.shared.unregister(tabManager)
        }
        .sheet(item: Self.passwordRequestBinding(in: tabManager)) { request in
            Self.passwordDialog(for: request, in: tabManager)
        }
    }

    static func passwordRequestBinding(in tabManager: TabManager) -> Binding<TabManager.PasswordPrompt?> {
        let presented = tabManager.pendingPasswordRequest
        return Binding(
            get: { presented },
            set: { request in
                guard request == nil, let presented else { return }
                tabManager.cancelPasswordPrompt(for: presented)
            }
        )
    }

    static func passwordDialog(for request: TabManager.PasswordPrompt, in tabManager: TabManager) -> PasswordDialogView {
        PasswordDialogView(
            fileName: request.url.lastPathComponent,
            onSubmit: { password in
                tabManager.submitPassword(password, for: request)
            },
            onCancel: {
                tabManager.cancelPasswordPrompt(for: request)
            }
        )
    }
}

// MARK: - TabManager Holder

/// Lazily constructs and retains a window's `TabManager`. Construction is
/// deferred out of `TabContainerView.init` (which SwiftUI re-runs on every
/// scene recompute) so a re-init never builds a throwaway manager — see the
/// `holder` doc-comment on `TabContainerView`.
@MainActor
private final class TabManagerHolder {
    private var stored: TabManager?

    init() {}
    init(adopting manager: TabManager) { stored = manager }

    var manager: TabManager {
        if let stored { return stored }
        let created = TabManager()
        stored = created
        return created
    }
}

// MARK: - Window Registrar

/// Helper view that registers the TabManager with the global registry.
private struct WindowRegistrar: NSViewRepresentable {
    let tabManager: TabManager

    func makeNSView(context: Context) -> NSView {
        let view = WindowRegistrarView()
        view.tabManager = tabManager
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowRegistrarView: NSView {
    var tabManager: TabManager?
    private var isRegistered = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window = window, let tabManager = tabManager, !isRegistered else { return }

        WindowRegistry.shared.register(tabManager, window: window)
        isRegistered = true
    }
}
