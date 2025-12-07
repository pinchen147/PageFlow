//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI

@main
struct PageFlowApp: App {
    @State private var pdfManager = PDFManager()
    @State private var recentFilesManager = RecentFilesManager()
    @State private var showingSearch = false

    var body: some Scene {
        WindowGroup {
            MainView(pdfManager: pdfManager, recentFilesManager: recentFilesManager, showingSearch: $showingSearch)
                .navigationTitle(pdfManager.documentTitle)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .importExport) {
                Button("Print...") {
                    pdfManager.print()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!pdfManager.hasDocument)

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
                    if pdfManager.hasDocument {
                        showingSearch.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!pdfManager.hasDocument)
            }
        }
    }

    private func openRecentFile(_ url: URL) {
        _ = pdfManager.loadDocument(from: url, isSecurityScoped: false)
        recentFilesManager.addRecentFile(url)
    }
}
