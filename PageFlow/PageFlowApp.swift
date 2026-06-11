//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct PageFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var recentFilesManager = RecentFilesManager()
    @State private var settingsManager = SettingsManager.shared

    // MARK: - Focused Values

    @FocusedValue(\.tabManager) private var focusedTabManager
    @FocusedValue(\.showingSearch) private var focusedShowingSearch
    @FocusedValue(\.searchFocusRequest) private var focusedSearchFocusRequest
    @FocusedValue(\.alwaysOnTop) private var focusedAlwaysOnTop

    // Single shared updater for the whole app. UpdateManager is a no-op stub when
    // Sparkle isn't compiled in, so it is safe to hold unconditionally and inject
    // everywhere (the menu and the Settings toggle) rather than creating a second
    // SPUStandardUpdaterController — Sparkle requires exactly one updater instance,
    // and a second one is why the "check automatically" toggle wasn't sticking.
    @State private var updateManager = UpdateManager()

    @State private var firstLaunchManager = FirstLaunchManager()

    // MARK: - Computed Properties

    private var hasDocument: Bool {
        focusedTabManager?.activePDFManager?.hasDocument == true
    }

    private var pdfManager: PDFManager? {
        focusedTabManager?.activePDFManager
    }

    private var isEditingPages: Bool {
        focusedTabManager?.isEditingPages ?? false
    }

    private var pageCount: Int {
        pdfManager?.pageCount ?? 0
    }

    private var showingSidebarLabel: String {
        "Toggle Sidebar"  // Static to prevent body re-evaluation
    }

    private var showingCommentsLabel: String {
        (focusedTabManager?.showingComments == true) ? "Hide Comments" : "Show Comments"
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            TabContainerView()
                .environment(recentFilesManager)
                .onAppear {
                    appDelegate.windowContentBuilder = { tabManager in
                        AnyView(
                            TabContainerView(tabManager: tabManager)
                                .environment(recentFilesManager)
                        )
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) { appMenuContent }
            CommandGroup(replacing: .newItem) { fileNewMenuContent }
            CommandGroup(after: .importExport) { fileSaveMenuContent }
            CommandGroup(replacing: .undoRedo) { editUndoMenuContent }
            CommandGroup(after: .pasteboard) { editFindMenuContent }
            CommandMenu("View") { viewMenuContent }
            CommandMenu("Go") { goMenuContent }
            CommandMenu("Tools") { toolsMenuContent }
            CommandMenu("Tab") { tabMenuContent }
        }

        // MARK: Settings Window
        Settings {
            SettingsView()
                .environment(updateManager)
        }
    }

    // MARK: - App Menu

    @ViewBuilder
    private var appMenuContent: some View {
        Button(firstLaunchManager.isDefaultPDFReader ? "✓ Default PDF Reader" : "Set as Default PDF Reader…") {
            firstLaunchManager.setAsDefaultPDFReader()
        }
        .disabled(firstLaunchManager.isDefaultPDFReader)

        #if ENABLE_SPARKLE
        Divider()
        Button("Check for Updates…") {
            updateManager.checkForUpdates()
        }
        .disabled(!updateManager.canCheckForUpdates)
        #endif
    }

    // MARK: - File Menu

    @ViewBuilder
    private var fileNewMenuContent: some View {
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
            focusedTabManager?.openFilePicker()
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(focusedTabManager == nil)

        Menu("Open Recent") {
            ForEach(recentFilesManager.recentFiles) { recentFile in
                Button(recentFile.displayName) {
                    openRecentFile(recentFile)
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

    @ViewBuilder
    private var fileSaveMenuContent: some View {
        Button("Save") {
            Task { await handleSave() }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!hasDocument)

        Button("Save As…") {
            Task { await handleSaveAs() }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(!hasDocument)

        Divider()

        Button("Print…") {
            if let document = pdfManager?.document {
                runPrintPanel(for: document)
            }
        }
        .keyboardShortcut("p", modifiers: .command)
        .disabled(!hasDocument)
    }

    // MARK: - Edit Menu

    private var activeUndoManager: UndoManager? {
        focusedTabManager?.activeUndoManager
    }

    private var canUndo: Bool {
        focusedTabManager?.activeCanUndo ?? false
    }

    private var canRedo: Bool {
        focusedTabManager?.activeCanRedo ?? false
    }

    @ViewBuilder
    private var editUndoMenuContent: some View {
        Button("Undo") {
            let um = activeUndoManager
            #if DEBUG
            Swift.print("[UNDO] pressed: um=\(um.map { "\(ObjectIdentifier($0))" } ?? "nil"), canUndo=\(um?.canUndo ?? false)")
            #endif
            um?.undo()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(!canUndo)

        Button("Redo") {
            let um = activeUndoManager
            #if DEBUG
            Swift.print("[REDO] pressed: um=\(um.map { "\(ObjectIdentifier($0))" } ?? "nil"), canRedo=\(um?.canRedo ?? false)")
            #endif
            um?.redo()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(!canRedo)
    }

    @ViewBuilder
    private var editFindMenuContent: some View {
        Divider()

        Button("Find…") {
            if hasDocument {
                focusedShowingSearch?.wrappedValue = true
                focusedSearchFocusRequest?.wrappedValue += 1
            }
        }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!hasDocument)

        Divider()

        Button("Delete Page") {
            guard let manager = pdfManager,
                  manager.pageCount > 1 else { return }
            manager.deletePage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "deletePage")
        .disabled(!hasDocument || !isEditingPages || pageCount <= 1)

        Divider()

        Button("Copy Page") {
            guard let manager = pdfManager else { return }
            manager.copyPage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "copyPage")
        .disabled(!hasDocument || !isEditingPages)

        Button("Cut Page") {
            guard let manager = pdfManager,
                  manager.pageCount > 1 else { return }
            manager.cutPage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "cutPage")
        .disabled(!hasDocument || !isEditingPages || pageCount <= 1)

        Button("Paste Page") {
            guard let manager = pdfManager else { return }
            _ = manager.pastePage(after: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "pastePage")
        .disabled(!hasDocument || !isEditingPages || !(pdfManager?.canPaste ?? false))
    }

    // MARK: - View Menu

    @ViewBuilder
    private var viewMenuContent: some View {
        let toolbarScaleBinding = Binding(
            get: { settingsManager.toolbarScale },
            set: { settingsManager.toolbarScale = SettingsManager.clampedToolbarScale($0) }
        )
        let topBarVisibilityBinding = Binding(
            get: { settingsManager.isTopBarAlwaysVisible },
            set: { settingsManager.isTopBarAlwaysVisible = $0 }
        )
        let floatingToolbarVisibilityBinding = Binding(
            get: { settingsManager.isFloatingToolbarAlwaysVisible },
            set: { settingsManager.isFloatingToolbarAlwaysVisible = $0 }
        )
        let pageIndicatorVisibilityBinding = Binding(
            get: { settingsManager.isPageIndicatorAlwaysVisible },
            set: { settingsManager.isPageIndicatorAlwaysVisible = $0 }
        )

        Button("Zoom In") {
            pdfManager?.zoomIn()
        }
        .keyboardShortcut(for: "zoomIn")
        .disabled(!hasDocument)

        Button("Zoom Out") {
            pdfManager?.zoomOut()
        }
        .keyboardShortcut(for: "zoomOut")
        .disabled(!hasDocument)

        Button("Actual Size") {
            pdfManager?.resetZoom()
        }
        .keyboardShortcut(for: "actualSize")
        .disabled(!hasDocument)

        Button("Zoom to Fit") {
            pdfManager?.requestFitOnce()
        }
        .keyboardShortcut(for: "zoomToFit")
        .disabled(!hasDocument)

        Divider()

        Toggle("Auto-Scale", isOn: Binding(
            get: { pdfManager?.isAutoScaling ?? false },
            set: { newValue in
                guard let manager = pdfManager else { return }
                manager.isAutoScaling = newValue
                if newValue {
                    manager.requestFitOnce()
                }
            }
        ))
        .disabled(!hasDocument || (pdfManager?.displayMode == .twoUp || pdfManager?.displayMode == .twoUpContinuous))

        Divider()

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
            focusedTabManager?.showingOutline.toggle()
        }
        .keyboardShortcut("s", modifiers: [.command, .option])
        .disabled(!hasDocument)

        Button(showingCommentsLabel) {
            focusedTabManager?.showingComments.toggle()
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(!hasDocument)

        Toggle("Always Show Top Bar", isOn: topBarVisibilityBinding)
        .keyboardShortcut(for: "toggleTopBar")
        .disabled(focusedTabManager == nil)

        Toggle("Always Show Toolbar", isOn: floatingToolbarVisibilityBinding)
            .keyboardShortcut(for: "toggleToolbar")
            .disabled(focusedTabManager == nil)

        Toggle("Always Show Page Number", isOn: pageIndicatorVisibilityBinding)
            .keyboardShortcut(for: "togglePageIndicator")

        Divider()

        VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
            Text("Toolbar Size")
            Slider(value: toolbarScaleBinding, in: SettingsManager.toolbarScaleRange)
                .frame(width: 160)
            Text("\(Int(round(settingsManager.toolbarScale * 100)))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Button("Reset Toolbar Size") {
            settingsManager.resetToolbarScale()
        }
        .disabled(abs(settingsManager.toolbarScale - SettingsManager.defaultToolbarScale) < 0.001)

        Toggle("Always on Top", isOn: Binding(
            get: { focusedAlwaysOnTop?.wrappedValue ?? false },
            set: { focusedAlwaysOnTop?.wrappedValue = $0 }
        ))
        .disabled(focusedAlwaysOnTop == nil)

        Divider()

        Button("Enter Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
    }

    // MARK: - Go Menu

    @ViewBuilder
    private var goMenuContent: some View {
        Button("Back") {
            pdfManager?.goBack()
        }
        .keyboardShortcut(for: "goBack")
        .disabled(!(pdfManager?.canGoBack ?? false))

        Button("Forward") {
            pdfManager?.goForward()
        }
        .keyboardShortcut(for: "goForward")
        .disabled(!(pdfManager?.canGoForward ?? false))

        Divider()

        Button("Next Page") {
            pdfManager?.nextPage()
        }
        .keyboardShortcut(for: "nextPage")
        .disabled(!hasDocument || (pdfManager?.currentPageIndex ?? 0) >= (pdfManager?.pageCount ?? 1) - 1)

        Button("Previous Page") {
            pdfManager?.previousPage()
        }
        .keyboardShortcut(for: "previousPage")
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
            guard let tabManager = focusedTabManager else { return }
            tabManager.showingGoToPage.toggle()
        }
        .keyboardShortcut(for: "goToPage")
        .disabled(!hasDocument)
    }

    // MARK: - Tools Menu

    @ViewBuilder
    private var toolsMenuContent: some View {
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
        .keyboardShortcut(for: "highlight")
        .disabled(!hasDocument)

        Button("Underline Selection") {
            focusedTabManager?.activeAnnotationManager?.underlineSelection()
        }
        .keyboardShortcut(for: "underline")
        .disabled(!hasDocument)

        Button("Add Comment") {
            _ = focusedTabManager?.activeCommentManager?.addComment()
        }
        .keyboardShortcut(for: "comment")
        .disabled(!hasDocument)

        Divider()

        Button("Toggle Bookmark") {
            if let manager = focusedTabManager?.activeBookmarkManager,
               let pageIndex = pdfManager?.currentPageIndex {
                manager.toggleBookmark(at: pageIndex)
            }
        }
        .keyboardShortcut(for: "bookmark")
        .disabled(!hasDocument)

        Divider()

        Button("Rotate Clockwise") {
            pdfManager?.rotateClockwise()
        }
        .keyboardShortcut(for: "rotateClockwise")
        .disabled(!hasDocument)

        Button("Rotate Counter-Clockwise") {
            pdfManager?.rotateCounterClockwise()
        }
        .keyboardShortcut(for: "rotateCounterClockwise")
        .disabled(!hasDocument)

        Divider()

        Button("Copy Page as Markdown") {
            copyCurrentPageAsMarkdown()
        }
        .keyboardShortcut(for: "copyPageAsMarkdown")
        .disabled(!hasDocument)

        Button("Copy Document as Markdown") {
            copyEntireDocumentAsMarkdown()
        }
        .keyboardShortcut(for: "copyDocumentAsMarkdown")
        .disabled(!hasDocument)

        Menu("Save as Markdown") {
            Button("Current Page…") {
                savePageAsMarkdownFile()
            }

            Button("Entire Document…") {
                saveAsMarkdownFile()
            }
        }
        .disabled(!hasDocument)
    }

    // MARK: - Tab Menu

    @ViewBuilder
    private var tabMenuContent: some View {
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

    // MARK: - Helper Methods

    private func openRecentFile(_ recentFile: RecentFile) {
        guard let resolved = recentFilesManager.resolveRecentFile(recentFile) else { return }

        if let tabManager = focusedTabManager ?? WindowRegistry.shared.anyTabManager() {
            tabManager.openDocument(url: resolved.url, isSecurityScoped: resolved.isSecurityScoped)
        } else {
            appDelegate.enqueuePendingURLs([resolved.url], isSecurityScoped: resolved.isSecurityScoped)
            openNewWindow()
        }
    }

    private func handleSave() async {
        guard let tabManager = focusedTabManager else { return }
        let result = await tabManager.saveActiveDocument()
        if case .failure(let message) = result {
            showAlert(message: message)
        }
    }

    private func handleSaveAs() async {
        guard let tabManager = focusedTabManager else { return }
        let result = await tabManager.saveActiveDocumentAs()
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
        let contentView = TabContainerView()
            .environment(recentFilesManager)
        appDelegate.createNewWindow(with: contentView)
    }

    // MARK: - Markdown Export

    private var comments: [CommentModel] {
        focusedTabManager?.activeCommentManager?.comments ?? []
    }

    private func copyCurrentPageAsMarkdown() {
        exportMarkdown(scope: .currentPage(pdfManager?.currentPageIndex ?? 0))
    }

    private func copyEntireDocumentAsMarkdown() {
        exportMarkdown(scope: .entireDocument)
    }

    private func exportMarkdown(scope: ExportScope) {
        guard let document = pdfManager?.document else { return }

        let markdown = MarkdownExporter.export(scope: scope, document: document, comments: comments)
        guard !markdown.isEmpty else { return }

        MarkdownExporter.copyToClipboard(markdown)
    }

    private func savePageAsMarkdownFile() {
        guard let manager = pdfManager,
              let document = manager.document else { return }

        let pageIndex = manager.currentPageIndex
        let markdown = MarkdownExporter.export(
            scope: .currentPage(pageIndex),
            document: document,
            comments: comments
        )
        guard !markdown.isEmpty else { return }

        let filename = manager.documentURL?.deletingPathExtension().lastPathComponent ?? "document"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(filename)-page\(pageIndex + 1).md"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showAlert(message: "Failed to save: \(error.localizedDescription)")
            }
        }
    }

    private func saveAsMarkdownFile() {
        guard let manager = pdfManager,
              let document = manager.document else { return }

        let markdown = MarkdownExporter.export(
            scope: .entireDocument,
            document: document,
            comments: comments
        )
        guard !markdown.isEmpty else { return }

        let filename = manager.documentURL?.deletingPathExtension().lastPathComponent ?? "document"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(filename).md"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showAlert(message: "Failed to save: \(error.localizedDescription)")
            }
        }
    }
}
