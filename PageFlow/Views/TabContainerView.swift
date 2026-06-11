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

    @State private var tabManager: TabManager
    @State private var showingSearch = false
    @State private var searchFocusRequest = 0

    /// Default init: each window creates its own empty TabManager.
    init() {
        self._tabManager = State(wrappedValue: TabManager())
    }

    /// Tear-off init: the caller hands us a pre-populated TabManager (e.g.
    /// one that already contains the dragged-out tab). The window opens with
    /// that state already in place — no race, no placeholder dance.
    init(tabManager: TabManager) {
        self._tabManager = State(wrappedValue: tabManager)
    }

    private var alwaysOnTopBinding: Binding<Bool> {
        Binding(
            get: { tabManager.isAlwaysOnTop },
            set: { tabManager.isAlwaysOnTop = $0 }
        )
    }

    private var activeWindowTitle: String {
        tabManager.activePDFManager?.documentTitle ?? "PageFlow"
    }

    /// One warm tab in the ZStack: the active tab is visible, hit-testable, and on
    /// top; the rest stay mounted but invisible and inert. Extracted from the
    /// `ForEach` so the SwiftUI type-checker resolves `MainView`'s initializer once
    /// here instead of inside the loop closure.
    @ViewBuilder
    private func warmTab(for runtime: TabRuntime) -> some View {
        let isActiveTab = runtime.tabID == tabManager.activeTabID
        MainView(
            tabID: runtime.tabID,
            pdfManager: runtime.pdfManager,
            searchManager: runtime.searchManager,
            annotationManager: runtime.annotationManager,
            commentManager: runtime.commentManager,
            bookmarkManager: runtime.bookmarkManager,
            tabUndoManager: runtime.undoManager,
            isActive: isActiveTab,
            showingSearch: $showingSearch,
            searchFocusRequest: searchFocusRequest,
            tabManager: tabManager,
            onOpenFile: { url, isSecurityScoped, replaceCurrent in
                tabManager.openDocument(url: url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent)
            }
        )
        .id(runtime.tabID)
        .opacity(isActiveTab ? 1 : 0)
        .allowsHitTesting(isActiveTab)
        .zIndex(isActiveTab ? 1 : 0)
        .accessibilityHidden(!isActiveTab)
    }

    var body: some View {
        ZStack {
            // Keep a small warm set of tabs mounted (TabManager.renderedRuntimes,
            // LRU-capped) and switch by visibility, so Cmd-number/⌘[ ⌘] switching is
            // an instant show rather than a teardown + cold PDFKit rebuild.
            //
            // Each tab keeps its own `.id(tabID)`, so its PDFViewWrapper Coordinator
            // stays bound to that tab's managers (the original reason this `.id`
            // exists — without it one reused MainView kept a Coordinator captured on
            // the wrong tab's `let` managers). The grow-over-time lag that the
            // earlier "tear down on every switch" fix targeted is instead prevented
            // at its real source: only the active tab keeps its window-wide event
            // monitors installed (driven by `isActive`), and the LRU cap tears down
            // and frees least-recently-used tabs. Per-tab reading position is still
            // restored by TabManager.restoreTabState + DocumentStateStore.
            ForEach(tabManager.renderedRuntimes, id: \.tabID) { runtime in
                warmTab(for: runtime)
            }
        }
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .top) {
            TopChromeView(tabManager: tabManager)
                .ignoresSafeArea(.all, edges: .top)
        }
        .toolbar(.hidden)
        .background(WindowConfigurator(isAlwaysOnTop: tabManager.isAlwaysOnTop))
        .background(WindowTitleUpdater(title: activeWindowTitle))
        .background(WindowRegistrar(tabManager: tabManager))
        .focusedSceneValue(\.tabManager, tabManager)
        .focusedSceneValue(\.showingSearch, $showingSearch)
        .focusedSceneValue(\.searchFocusRequest, $searchFocusRequest)
        .focusedSceneValue(\.alwaysOnTop, alwaysOnTopBinding)
        .onChange(of: showingSearch) { _, isShowing in
            if !isShowing {
                tabManager.clearAllSearchState()
            }
        }
        .onAppear {
            tabManager.documentOpenedHandler = { [recentFilesManager] url, isSecurityScoped in
                recentFilesManager.addRecentFile(url, isSecurityScoped: isSecurityScoped)
            }

            // Flush any Finder-opened URLs immediately on cold launch
            // (faster than waiting for WindowRegistrarView to mount + async dispatch)
            if let appDelegate = AppDelegate.shared {
                appDelegate.flushPendingURLs(to: tabManager)
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            tabManager.closeFilePicker()
            tabManager.openDocument(url: url, isSecurityScoped: false)
        }
        .onDisappear {
            tabManager.flushActiveTabViewState()
            WindowRegistry.shared.unregister(tabManager)
        }
        .sheet(item: $tabManager.pendingPasswordRequest) { request in
            PasswordDialogView(
                fileName: request.url.lastPathComponent,
                onSubmit: { password in
                    tabManager.submitPassword(password)
                },
                onCancel: {
                    tabManager.cancelPasswordPrompt()
                }
            )
        }
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
