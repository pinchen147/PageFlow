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
            // Main content area - use .id() to force view recreation when tab changes
            if let pdfManager = tabManager.activePDFManager,
               let searchManager = tabManager.activeSearchManager,
               let activeTabID = tabManager.activeTabID {
                MainView(
                    pdfManager: pdfManager,
                    searchManager: searchManager,
                    recentFilesManager: recentFilesManager,
                    showingSearch: $showingSearch,
                    isTopBarHovered: $isTopBarHovered,
                    tabManager: tabManager,
                    onOpenFile: { url, isSecurityScoped in
                        tabManager.openDocument(url: url, isSecurityScoped: isSecurityScoped)
                        recentFilesManager.addRecentFile(url)
                    }
                )
                .id(activeTabID)
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
