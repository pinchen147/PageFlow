//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI

@main
struct PageFlowApp: App {
    @State private var tabManager = TabManager()
    @State private var recentFilesManager = RecentFilesManager()
    @State private var showingSearch = false

    var body: some Scene {
        WindowGroup {
            TabContainerView(
                tabManager: tabManager,
                recentFilesManager: recentFilesManager,
                showingSearch: $showingSearch
            )
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    tabManager.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("New Window") {
                    openNewWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    tabManager.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(tabManager.tabs.isEmpty)
            }

            CommandGroup(after: .importExport) {
                Button("Print...") {
                    tabManager.activePDFManager?.print()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(tabManager.activePDFManager?.hasDocument != true)

                Divider()

                Menu("Open Recent") {
                    ForEach(recentFilesManager.recentFiles, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            openRecentFile(url)
                        }
                    }

                    if !recentFilesManager.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            recentFilesManager.clearRecentFiles()
                        }
                    }
                }
                .disabled(recentFilesManager.recentFiles.isEmpty)
            }

            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    if tabManager.activePDFManager?.hasDocument == true {
                        showingSearch.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(tabManager.activePDFManager?.hasDocument != true)
            }

            // Tab navigation commands
            CommandMenu("Tab") {
                Button("Select Next Tab") {
                    tabManager.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(tabManager.tabCount <= 1)

                Button("Select Previous Tab") {
                    tabManager.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(tabManager.tabCount <= 1)

                Divider()

                // Cmd+1 through Cmd+9 for direct tab selection
                ForEach(1...9, id: \.self) { index in
                    Button("Select Tab \(index)") {
                        tabManager.selectTabByIndex(index - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled(index > tabManager.tabCount)
                }
            }
        }
    }

    private func openRecentFile(_ url: URL) {
        tabManager.openDocument(url: url, isSecurityScoped: false)
        recentFilesManager.addRecentFile(url)
    }

    private func openNewWindow() {
        // Open a new window using NSWorkspace
        if let appURL = Bundle.main.bundleURL as URL? {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
    }
}
