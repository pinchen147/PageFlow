//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI
import PDFKit

@main
struct PageFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFilesManager = RecentFilesManager()

    // MARK: - Focused Values

    @FocusedValue(\.tabManager) private var focusedTabManager
    @FocusedValue(\.showingSearch) private var focusedShowingSearch
    @FocusedValue(\.showingOutline) private var focusedShowingOutline
    @FocusedValue(\.showingComments) private var focusedShowingComments
    @FocusedValue(\.showingGoToPage) private var focusedShowingGoToPage
    @FocusedValue(\.showingFileImporter) private var focusedShowingFileImporter

    #if ENABLE_SPARKLE
    @State private var updateManager = UpdateManager()
    #endif

    // MARK: - Computed Properties

    private var hasDocument: Bool {
        focusedTabManager?.activePDFManager?.hasDocument == true
    }

    private var pdfManager: PDFManager? {
        focusedTabManager?.activePDFManager
    }

    private var showingSidebarLabel: String {
        (focusedShowingOutline?.wrappedValue == true) ? "Hide Sidebar" : "Show Sidebar"
    }

    private var showingCommentsLabel: String {
        (focusedShowingComments?.wrappedValue == true) ? "Hide Comments" : "Show Comments"
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            TabContainerView(recentFilesManager: recentFilesManager)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // MARK: Sparkle
            #if ENABLE_SPARKLE
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)
            }
            #endif

            // MARK: File Menu - New Items
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

                Divider()

                Button("Open…") {
                    focusedShowingFileImporter?.wrappedValue = true
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(focusedTabManager == nil)

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

                Divider()

                Button("Close Tab") {
                    focusedTabManager?.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(focusedTabManager?.tabs.isEmpty != false)
            }

            // MARK: File Menu - Save/Print
            CommandGroup(after: .importExport) {
                Button("Save") {
                    handleSave()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasDocument)

                Button("Save As…") {
                    handleSaveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!hasDocument)

                Divider()

                Button("Print…") {
                    pdfManager?.print()
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasDocument)
            }

            // MARK: Edit Menu - Undo/Redo
            CommandGroup(before: .pasteboard) {
                Button("Undo") {
                    NSApp.sendAction(#selector(UndoManager.undo), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    NSApp.sendAction(#selector(UndoManager.redo), to: nil, from: nil)
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Divider()
            }

            // MARK: Edit Menu - Find
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Find…") {
                    if hasDocument {
                        focusedShowingSearch?.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasDocument)
            }

            // MARK: View Menu
            CommandMenu("View") {
                Button("Zoom In") {
                    pdfManager?.zoomIn()
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!hasDocument)

                Button("Zoom Out") {
                    pdfManager?.zoomOut()
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!hasDocument)

                Button("Actual Size") {
                    pdfManager?.resetZoom()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!hasDocument)

                Button("Zoom to Fit") {
                    pdfManager?.requestFitOnce()
                    pdfManager?.scaleNeedsUpdate = true
                }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(!hasDocument)

                Divider()

                Toggle("Auto-Scale", isOn: Binding(
                    get: { pdfManager?.isAutoScaling ?? false },
                    set: { newValue in
                        guard let manager = pdfManager else { return }
                        manager.isAutoScaling = newValue
                        if newValue {
                            manager.requestFitOnce()
                            manager.scaleNeedsUpdate = true
                        }
                    }
                ))
                .disabled(!hasDocument || (pdfManager?.displayMode == .twoUp || pdfManager?.displayMode == .twoUpContinuous))

                Divider()

                // Display Mode options
                Picker("Display", selection: Binding(
                    get: { pdfManager?.displayMode ?? .singlePageContinuous },
                    set: { pdfManager?.displayMode = $0 }
                )) {
                    Text("Single Page").tag(PDFDisplayMode.singlePage)
                    Text("Single Page Continuous").tag(PDFDisplayMode.singlePageContinuous)
                    Text("Two Pages").tag(PDFDisplayMode.twoUp)
                    Text("Two Pages Continuous").tag(PDFDisplayMode.twoUpContinuous)
                }
                .pickerStyle(.inline)
                .disabled(!hasDocument)

                Divider()

                Button(showingSidebarLabel) {
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                        focusedShowingOutline?.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!hasDocument)

                Button(showingCommentsLabel) {
                    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                        focusedShowingComments?.wrappedValue.toggle()
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasDocument)

                Divider()

                Button("Enter Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }

            // MARK: Go Menu
            CommandMenu("Go") {
                Button("Next Page") {
                    pdfManager?.nextPage()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!hasDocument || (pdfManager?.currentPageIndex ?? 0) >= (pdfManager?.pageCount ?? 1) - 1)

                Button("Previous Page") {
                    pdfManager?.previousPage()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!hasDocument || (pdfManager?.currentPageIndex ?? 0) == 0)

                Divider()

                Button("First Page") {
                    pdfManager?.goToFirstPage()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!hasDocument)

                Button("Last Page") {
                    pdfManager?.goToLastPage()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!hasDocument)

                Divider()

                Button("Go to Page…") {
                    focusedShowingGoToPage?.wrappedValue = true
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!hasDocument)
            }

            // MARK: Tools Menu
            CommandMenu("Tools") {
                Button("Select Mode") {
                    pdfManager?.interactionMode = .select
                }
                .disabled(!hasDocument || pdfManager?.interactionMode == .select)

                Button("Pan Mode") {
                    pdfManager?.interactionMode = .pan
                }
                .disabled(!hasDocument || pdfManager?.interactionMode == .pan)

                Divider()

                Button("Highlight Selection") {
                    focusedTabManager?.activeAnnotationManager?.highlightSelection()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(!hasDocument)

                Button("Underline Selection") {
                    focusedTabManager?.activeAnnotationManager?.underlineSelection()
                }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(!hasDocument)

                Button("Add Comment") {
                    _ = focusedTabManager?.activeCommentManager?.addComment()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!hasDocument)

                Divider()

                Button("Rotate Clockwise") {
                    pdfManager?.rotateClockwise()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!hasDocument)

                Button("Rotate Counter-Clockwise") {
                    pdfManager?.rotateCounterClockwise()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasDocument)
            }

            // MARK: Tab Menu
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
        }
    }

    // MARK: - Helper Methods

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
