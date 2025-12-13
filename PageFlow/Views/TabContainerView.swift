//
//  TabContainerView.swift
//  PageFlow
//
//  Root container view for tab management. Each window owns its own TabManager.
//

import SwiftUI

struct TabContainerView: View {
    var recentFilesManager: RecentFilesManager

    @State private var tabManager = TabManager()
    @State private var showingSearch = false
    @State private var isTopBarHovered = false

    var body: some View {
        ZStack {
            // Render all tabs in a stack to preserve state
            // Use zIndex to ensure active tab is on top for interactions
            ForEach(tabManager.tabs) { tab in
                if let (pdfManager, searchManager, annotationManager, commentManager, bookmarkManager) = tabManager.managers(for: tab.id) {
                    let isActive = tab.id == tabManager.activeTabID

                    MainView(
                        pdfManager: pdfManager,
                        searchManager: searchManager,
                        annotationManager: annotationManager,
                        commentManager: commentManager,
                        bookmarkManager: bookmarkManager,
                        showingSearch: $showingSearch,
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
        .focusedSceneValue(\.tabManager, tabManager)
        .focusedSceneValue(\.showingSearch, $showingSearch)
        .onAppear {
            WindowRegistry.shared.register(tabManager)
        }
        .onDisappear {
            WindowRegistry.shared.unregister(tabManager)
        }
    }
}
