//
//  TabContainerView.swift
//  PageFlow
//
//  Root container view for tab management
//

import SwiftUI

struct TabContainerView: View {
    @Bindable var tabManager: TabManager
    var recentFilesManager: RecentFilesManager
    @Binding var showingSearch: Bool

    @State private var isTopBarHovered = false

    var body: some View {
        ZStack {
            // Render all tabs in a stack to preserve state
            // Use zIndex to ensure active tab is on top for interactions
            ForEach(tabManager.tabs) { tab in
                if let (pdfManager, searchManager, annotationManager) = tabManager.managers(for: tab.id) {
                    let isActive = tab.id == tabManager.activeTabID
                    
                    MainView(
                        pdfManager: pdfManager,
                        searchManager: searchManager,
                        annotationManager: annotationManager,
                        showingSearch: $showingSearch,
                        isTopBarHovered: $isTopBarHovered,
                        tabManager: tabManager,
                        onOpenFile: { url, isSecurityScoped in
                            tabManager.openDocument(url: url, isSecurityScoped: isSecurityScoped)
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
        .onAppear {
            tabManager.restoreSession()
        }
        .onDisappear {
            tabManager.saveSession()
        }
    }
}
