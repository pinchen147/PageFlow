//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI

@main
struct PageFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFilesManager = RecentFilesManager()

    @FocusedValue(\.tabManager) private var focusedTabManager
    @FocusedValue(\.showingSearch) private var focusedShowingSearch

    #if ENABLE_SPARKLE
    @State private var updateManager = UpdateManager()
    #endif

    var body: some Scene {
        WindowGroup {
            TabContainerView(recentFilesManager: recentFilesManager)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            #if ENABLE_SPARKLE
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
            #endif

            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    focusedTabManager?.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(focusedTabManager == nil)

                Button("New Window") {
                    openNewWindow()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    focusedTabManager?.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(focusedTabManager?.tabs.isEmpty != false)
            }

            CommandGroup(after: .importExport) {
                Button("Print...") {
                    focusedTabManager?.activePDFManager?.print()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

                Divider()

                Button("Save") {
                    handleSave()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

                Button("Save As…") {
                    handleSaveAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

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
                    if focusedTabManager?.activePDFManager?.hasDocument == true {
                        focusedShowingSearch?.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

                Button("Add Comment") {
                    _ = focusedTabManager?.activeCommentManager?.addComment()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

                Button("Underline Selection") {
                    focusedTabManager?.activeAnnotationManager?.underlineSelection()
                }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)

                Button("Highlight Selection") {
                    focusedTabManager?.activeAnnotationManager?.highlightSelection()
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(focusedTabManager?.activePDFManager?.hasDocument != true)
            }

            CommandMenu("Tab") {
                Button("Select Next Tab") {
                    focusedTabManager?.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(focusedTabManager?.tabCount ?? 0 <= 1)

                Button("Select Previous Tab") {
                    focusedTabManager?.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(focusedTabManager?.tabCount ?? 0 <= 1)

                Divider()

                ForEach(1...9, id: \.self) { index in
                    Button("Select Tab \(index)") {
                        focusedTabManager?.selectTabByIndex(index - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                    .disabled(index > (focusedTabManager?.tabCount ?? 0))
                }
            }

            CommandGroup(before: .pasteboard) {
                Button("Undo") {
                    NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command])

                Button("Redo") {
                    NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
            }
        }
    }

    private func openRecentFile(_ url: URL) {
        focusedTabManager?.openDocument(url: url, isSecurityScoped: false)
        recentFilesManager.addRecentFile(url)
    }

    private func handleSave() {
        guard let result = focusedTabManager?.saveActiveDocument() else { return }
        if case .failure(let message) = result {
            showAlert(message: message)
        }
    }

    private func handleSaveAs() {
        guard let result = focusedTabManager?.saveActiveDocumentAs() else { return }
        if case .failure(let message) = result {
            showAlert(message: message)
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openNewWindow() {
        NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
    }
}
