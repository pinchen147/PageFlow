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
    @State private var isTopBarHovered = false

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

    var body: some View {
        ZStack {
            // Render all tabs in a stack to preserve state
            // Use zIndex to ensure active tab is on top for interactions
            // IMPORTANT: Explicit id: \.id prevents view recreation during state changes
            ForEach(tabManager.tabs, id: \.id) { tab in
                if let (pdfManager, searchManager, annotationManager, commentManager, bookmarkManager) = tabManager.managers(for: tab.id) {
                    let isActive = tab.id == tabManager.activeTabID

                    MainView(
                        tabID: tab.id,
                        pdfManager: pdfManager,
                        searchManager: searchManager,
                        annotationManager: annotationManager,
                        commentManager: commentManager,
                        bookmarkManager: bookmarkManager,
                        isActive: isActive,
                        showingSearch: $showingSearch,
                        searchFocusRequest: searchFocusRequest,
                        isAlwaysOnTop: tabManager.isAlwaysOnTop,
                        tabManager: tabManager,
                        onOpenFile: { url, isSecurityScoped, replaceCurrent in
                            tabManager.openDocument(url: url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent)
                        }
                    )
                    .opacity(isActive ? 1 : 0)
                    .zIndex(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                }
            }
        }
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .top) {
            TopChromeView(tabManager: tabManager, isTopBarHovered: $isTopBarHovered)
                .ignoresSafeArea(.all, edges: .top)
        }
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
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.flushPendingURLs(to: tabManager)
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            tabManager.closeFilePicker()
            tabManager.openDocument(url: url, isSecurityScoped: false)
        }
        .onDisappear {
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
