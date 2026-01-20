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

    @State private var tabManager = TabManager()
    @State private var showingSearch = false
    @State private var showingToolbar = false
    @State private var isTopBarHovered = false

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
                        showingToolbar: $showingToolbar,
                        isTopBarHovered: $isTopBarHovered,
                        tabManager: tabManager,
                        onOpenFile: { url, isSecurityScoped, replaceCurrent in
                            tabManager.openDocument(url: url, isSecurityScoped: isSecurityScoped, replaceCurrent: replaceCurrent)
                            recentFilesManager.addRecentFile(url)
                        }
                    )
                    .opacity(isActive ? 1 : 0)
                    .zIndex(isActive ? 1 : 0)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                }
            }
        }
        .background(WindowRegistrar(tabManager: tabManager))
        .focusedSceneValue(\.tabManager, tabManager)
        .focusedSceneValue(\.showingSearch, $showingSearch)
        .focusedSceneValue(\.showingToolbar, $showingToolbar)
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

/// Helper view that registers the TabManager with the global registry
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

        guard window != nil, let tabManager = tabManager, !isRegistered else { return }

        WindowRegistry.shared.register(tabManager)
        isRegistered = true
    }
}
