//
//  PageFlowApp.swift
//  PageFlow
//
//  Created by Chong Pin Shin on 7/12/25.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import MarkdownEngine

@main
struct PageFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var recentFilesManager: RecentFilesManager { appDelegate.recentFilesManager }
    @State private var settingsManager = SettingsManager.shared

    // MARK: - Focused Values

    @FocusedValue(\.tabManager) private var focusedSceneTabManager

    /// Reactive frontmost-window fallback for the menu commands. `@FocusedValue`
    /// resolves nil when the key window (e.g. a manually-created ⌘N / tear-off
    /// window) holds no focused SwiftUI view, so commands routed purely through
    /// it would no-op AND grey out. Resolving `focused ?? frontmost` keeps both
    /// the action targets and the enabled state on the window the user is in.
    @State private var activeWindow = ActiveWindowModel.shared
    @State private var undoCommands = UndoCommandRouter()

    /// The TabManager every menu command (⌘T/⌘W/⌘S/Find/…) targets: the focused
    /// window's, else the frontmost window's. Reactive on both inputs.
    private var focusedTabManager: TabManager? {
        focusedSceneTabManager ?? activeWindow.tabManager
    }

    @State private var firstLaunchManager = FirstLaunchManager()

    // MARK: - Computed Properties

    private var hasDocument: Bool {
        focusedTabManager?.activePDFManager?.hasDocument == true
    }

    // Content-aware command predicates (PDF + Markdown). Gate the Save / Save As /
    // Find / Print menu items so they follow the active tab's content type.
    private var canSave: Bool { focusedTabManager?.canSave ?? false }
    private var canSaveAs: Bool { focusedTabManager?.canSaveAs ?? false }
    private var canFind: Bool { focusedTabManager?.canFind ?? false }
    private var canPrint: Bool { focusedTabManager?.canPrint ?? false }

    /// Gate for the Format menu (⌘B/⌘I/⌘U/Heading): the active tab is a Markdown tab
    /// with content. PDF tabs and empty untitled buffers report false.
    private var canFormatMarkdown: Bool { focusedTabManager?.canFormatMarkdown ?? false }

    /// Gates for content-routed view commands — thin reads of TabManager's
    /// routing (the exhaustive switches live THERE, not in the menu layer).
    private var canUseViewCommands: Bool { focusedTabManager?.activeContentAcceptsViewCommands ?? false }
    private var canUnderline: Bool { focusedTabManager?.canUnderline ?? false }

    private var pdfManager: PDFManager? {
        focusedTabManager?.activePDFManager
    }

    private var pdfPermissions: PDFPermissions { pdfManager?.permissions ?? PDFPermissions() }

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
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) { appMenuContent }
            CommandGroup(replacing: .newItem) { fileNewMenuContent }
            CommandGroup(after: .importExport) { fileSaveMenuContent }
            CommandGroup(replacing: .undoRedo) { editUndoMenuContent }
            CommandGroup(after: .pasteboard) { editFindMenuContent }
            CommandMenu("Format") { formatMenuContent }
            // Into the system View menu (in place of Show/Hide Toolbar, which the
            // hidden-title-bar window never shows), so there is one View menu;
            // AppKit adds Enter Full Screen to it.
            CommandGroup(replacing: .toolbar) { viewMenuContent }
            CommandMenu("Go") { goMenuContent }
            CommandMenu("Tools") { toolsMenuContent }
            CommandMenu("Tab") { tabMenuContent }
        }

        // MARK: Settings Window
        Settings {
            SettingsView()
        }
    }

    // MARK: - App Menu

    @ViewBuilder
    private var appMenuContent: some View {
        Button(firstLaunchManager.isDefaultPDFReader ? "✓ Default PDF Reader" : "Set as Default PDF Reader…") {
            firstLaunchManager.setAsDefaultPDFReader()
        }
        .disabled(firstLaunchManager.isDefaultPDFReader)

        if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
            Divider()
            Button("Third-Party Notices…") { NSWorkspace.shared.open(notices) }
        }
    }

    // MARK: - File Menu

    @ViewBuilder
    private var fileNewMenuContent: some View {
        Button("New Tab") {
            focusedTabManager?.createNewTab()
        }
        .keyboardShortcut(for: "newTab")
        .disabled(focusedTabManager == nil)

        Button("New Markdown Document") {
            focusedTabManager?.newMarkdownDocument()
        }
        .keyboardShortcut(for: "newMarkdownDocument")
        .disabled(focusedTabManager == nil)

        Button("New Window") {
            openNewWindow()
        }
        .keyboardShortcut(for: "newWindow")

        Divider()

        Button("Open…") {
            focusedTabManager?.openFilePicker()
        }
        .keyboardShortcut(for: "openFile")
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
        .keyboardShortcut(for: "closeTab")
        .disabled(focusedTabManager?.tabs.isEmpty != false)
    }

    @ViewBuilder
    private var fileSaveMenuContent: some View {
        Button("Save") {
            Task { await handleSave() }
        }
        .keyboardShortcut(for: "save")
        .disabled(!canSave)

        Button("Save As…") {
            Task { await handleSaveAs() }
        }
        .keyboardShortcut(for: "saveAs")
        .disabled(!canSaveAs)

        Divider()

        Button("Print…") {
            // Content-aware: PDF prints via the unchanged PDFKit path; Markdown prints
            // the styled Live-Preview text. `printActiveDocument` is the single
            // exhaustive switch (peer of `saveActiveDocument`); `canPrint` is the gate.
            focusedTabManager?.printActiveDocument()
        }
        .keyboardShortcut(for: "print")
        .disabled(!canPrint)
    }

    // MARK: - Edit Menu

    private var undoAvailability: UndoAvailability {
        undoCommands.availability(fallback: UndoAvailability(
            canUndo: focusedTabManager?.activeCanUndo ?? false,
            canRedo: focusedTabManager?.activeCanRedo ?? false
        ))
    }

    @ViewBuilder
    private var editUndoMenuContent: some View {
        Button("Undo") {
            undoCommands.undo(fallback: focusedTabManager?.activeUndoManager)
        }
        .keyboardShortcut(for: "undo")
        .disabled(!undoAvailability.canUndo)

        Button("Redo") {
            undoCommands.redo(fallback: focusedTabManager?.activeUndoManager)
        }
        .keyboardShortcut(for: "redo")
        .disabled(!undoAvailability.canRedo)
    }

    @ViewBuilder
    private var editFindMenuContent: some View {
        Divider()

        Button("Find…") {
            focusedTabManager?.requestFind()
        }
        .keyboardShortcut(for: "search")
        .disabled(!canFind)

        Button("Find and Replace…") {
            focusedTabManager?.requestFind(showReplacement: true)
        }
        .keyboardShortcut(for: "findAndReplace")
        .disabled(!(focusedTabManager?.canReplace ?? false))

        Button("Find Next") {
            focusedTabManager?.activeFindDriver?.next()
        }
        .keyboardShortcut(for: "findNext")
        .disabled(!(focusedTabManager?.canNavigateFind ?? false))

        Button("Find Previous") {
            focusedTabManager?.activeFindDriver?.previous()
        }
        .keyboardShortcut(for: "findPrevious")
        .disabled(!(focusedTabManager?.canNavigateFind ?? false))

        Divider()

        Button("Delete Page") {
            guard let manager = pdfManager,
                  manager.pageCount > 1 else { return }
            manager.deletePage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "deletePage")
        .disabled(!pdfPermissions.editPages || !isEditingPages || pageCount <= 1)

        Divider()

        Button("Copy Page") {
            guard let manager = pdfManager else { return }
            manager.copyPage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "copyPage")
        .disabled(!pdfPermissions.copy || !isEditingPages)

        Button("Cut Page") {
            guard let manager = pdfManager,
                  manager.pageCount > 1 else { return }
            manager.cutPage(at: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "cutPage")
        .disabled(!pdfPermissions.editPages || !pdfPermissions.copy || !isEditingPages || pageCount <= 1)

        Button("Paste Page") {
            guard let manager = pdfManager else { return }
            _ = manager.pastePage(after: manager.currentPageIndex)
        }
        .keyboardShortcut(for: "pastePage")
        .disabled(!pdfPermissions.editPages || !isEditingPages || !(pdfManager?.canPaste ?? false))
    }

    // MARK: - Format Menu

    /// Content-aware Markdown formatting. Each item posts a format request onto the
    /// active tab's scoped editor bus (the only sanctioned reach into the engine);
    /// gated so it is enabled only for a Markdown tab with content. PDF tabs see a
    /// disabled Format menu, never a broken command. Bold/Italic use the standard
    /// Inline styles, then block formats; every item routes to the active
    /// Markdown tab's selection.
    @ViewBuilder
    private var formatMenuContent: some View {
        ForEach([MarkdownFormatCommand.bold, .italic, .underline, .strikethrough, .code, .highlight, .link]) { formatButton($0) }
        Divider()
        ForEach([MarkdownFormatCommand.text, .heading, .heading2, .heading3]) { formatButton($0) }
        Divider()
        ForEach([MarkdownFormatCommand.bulletedList, .numberedList, .checklist, .quote, .codeBlock]) { formatButton($0) }
        Divider()
        ForEach([MarkdownFormatCommand.table, .divider]) { formatButton($0) }
    }

    /// A Format item; marks, text styles and lists carry the selection bar's
    /// check mark (doc 24 §7.8.9).
    private func formatButton(_ command: MarkdownFormatCommand) -> some View {
        Toggle(isOn: Binding(
            get: { isMarkdownFormatOn(command) },
            set: { _ in focusedTabManager?.requestMarkdownFormat(command) }
        )) {
            Text(command.title)
        }
        .keyboardShortcut(command.menuShortcut)
        .disabled(!canFormatMarkdown || focusedTabManager?.activeMarkdownContent?.isFormatEnabled(command) == false)
    }

    private func isMarkdownFormatOn(_ command: MarkdownFormatCommand) -> Bool {
        focusedTabManager?.activeMarkdownContent?.isFormatOn(command) ?? false
    }

    @ViewBuilder
    private var foldingMenuContent: some View {
        let content = focusedTabManager?.activeMarkdownContent
        let _ = content?.foldingRevision
        let controller = content?.editorController
        Menu("Folding") {
            Button(controller?.isCurrentSectionFolded == true ? "Expand Section" : "Collapse Section") {
                controller?.performFoldingCommand(.toggleFold)
            }
            .keyboardShortcut(for: "markdown.toggleFold")
            .disabled(controller?.canPerformFoldingCommand(.toggleFold) != true)

            Button("Collapse All") {
                controller?.performFoldingCommand(.collapseAll)
            }
            .keyboardShortcut(for: "markdown.collapseAll")
            .disabled(controller?.canPerformFoldingCommand(.collapseAll) != true)

            Button("Expand All") {
                controller?.performFoldingCommand(.expandAll)
            }
            .keyboardShortcut(for: "markdown.expandAll")
            .disabled(controller?.canPerformFoldingCommand(.expandAll) != true)
        }
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

        // Content-routed zoom (PDF view zoom / Markdown text size) — the
        // routing lives on TabManager.
        Button("Zoom In") {
            focusedTabManager?.zoomIn()
        }
        .keyboardShortcut(for: "zoomIn")
        .disabled(!canUseViewCommands)

        Button("Zoom Out") {
            focusedTabManager?.zoomOut()
        }
        .keyboardShortcut(for: "zoomOut")
        .disabled(!canUseViewCommands)

        Button("Actual Size") {
            focusedTabManager?.resetZoom()
        }
        .keyboardShortcut(for: "actualSize")
        .disabled(!canUseViewCommands)

        Button("Zoom to Fit") {
            pdfManager?.requestFitOnce()
        }
        .keyboardShortcut(for: "zoomToFit")
        .disabled(!hasDocument)

        Divider()

        foldingMenuContent

        Divider()

        Toggle("Auto-Scale", isOn: Binding(
            get: { pdfManager?.isAutoScaling ?? false },
            set: { newValue in
                guard let manager = pdfManager else { return }
                manager.setAutoScaling(newValue)
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
        .keyboardShortcut(for: "toggleSidebar")
        // Content-agnostic: the PDF sidebar and the Markdown outline bind the
        // same per-tab uiState slot.
        .disabled(!canUseViewCommands)

        Button(showingCommentsLabel) {
            focusedTabManager?.showingComments.toggle()
        }
        .keyboardShortcut(for: "toggleComments")
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
            get: { focusedTabManager?.isAlwaysOnTop ?? false },
            set: { focusedTabManager?.isAlwaysOnTop = $0 }
        ))
        .disabled(focusedTabManager == nil)
    }

    // MARK: - Go Menu

    @ViewBuilder
    private var goMenuContent: some View {
        // Content-routed (TabManager): PDF page history / Markdown scroll trail.
        Button("Back") {
            focusedTabManager?.goBack()
        }
        .keyboardShortcut(for: "goBack")
        .disabled(!(focusedTabManager?.canGoBack ?? false))

        Button("Forward") {
            focusedTabManager?.goForward()
        }
        .keyboardShortcut(for: "goForward")
        .disabled(!(focusedTabManager?.canGoForward ?? false))

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
        .keyboardShortcut(for: "firstPage")
        .disabled(!hasDocument)

        Button("Last Page") {
            pdfManager?.goToLastPage()
        }
        .keyboardShortcut(for: "lastPage")
        .disabled(!hasDocument)

        Divider()

        // Content-routed: the PDF dialog jumps to a page, the Markdown dialog
        // to a line — same shortcut, same per-tab uiState slot.
        Button(focusedTabManager?.goToDialogTitle ?? "Go to Page…") {
            guard let tabManager = focusedTabManager else { return }
            tabManager.showingGoToPage.toggle()
        }
        .keyboardShortcut(for: "goToPage")
        .disabled(!(focusedTabManager?.canShowGoToDialog ?? false))
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
        .disabled(!pdfPermissions.annotate)

        // A PDF annotation; Markdown's Underline is in the Format menu (both ⌘U by default).
        Button("Underline Selection") {
            focusedTabManager?.underlineActiveSelection()
        }
        .keyboardShortcut(for: "underline")
        .disabled(!canUnderline)

        Button("Add Comment") {
            _ = focusedTabManager?.activeCommentManager?.addComment()
        }
        .keyboardShortcut(for: "comment")
        .disabled(!pdfPermissions.annotate)

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
        .disabled(!pdfPermissions.editPages)

        Button("Rotate Counter-Clockwise") {
            pdfManager?.rotateCounterClockwise()
        }
        .keyboardShortcut(for: "rotateCounterClockwise")
        .disabled(!pdfPermissions.editPages)

        Divider()

        Button("Copy Page as Markdown") {
            copyCurrentPageAsMarkdown()
        }
        .keyboardShortcut(for: "copyPageAsMarkdown")
        .disabled(!pdfPermissions.copy)

        Button("Copy Document as Markdown") {
            copyEntireDocumentAsMarkdown()
        }
        .keyboardShortcut(for: "copyDocumentAsMarkdown")
        .disabled(!pdfPermissions.copy)

        Menu("Save as Markdown") {
            Button("Current Page…") {
                savePageAsMarkdownFile()
            }

            Button("Entire Document…") {
                saveAsMarkdownFile()
            }
        }
        .disabled(!pdfPermissions.copy)
    }

    // MARK: - Tab Menu

    @ViewBuilder
    private var tabMenuContent: some View {
        Button("Search Tabs…") {
            TabSwitcherController.shared.toggle(forWindow: NSApp.keyWindow, hostTabManager: focusedTabManager)
        }
        .keyboardShortcut(for: "searchTabs")
        .disabled(focusedTabManager == nil)

        Divider()

        Button("Select Next Tab") {
            focusedTabManager?.selectNextTab()
        }
        .keyboardShortcut(for: "selectNextTab")
        .disabled(focusedTabManager?.tabCount ?? 0 <= 1)

        Button("Select Previous Tab") {
            focusedTabManager?.selectPreviousTab()
        }
        .keyboardShortcut(for: "selectPreviousTab")
        .disabled(focusedTabManager?.tabCount ?? 0 <= 1)

        Divider()

        ForEach(1...9, id: \.self) { index in
            Button("Select Tab \(index)") {
                focusedTabManager?.selectTabByIndex(index - 1)
            }
            .keyboardShortcut(for: ShortcutCatalog.selectTabID(index))
            .disabled(index > (focusedTabManager?.tabCount ?? 0))
        }
    }

    // MARK: - Helper Methods

    private func openRecentFile(_ recentFile: RecentFile) {
        guard let resolved = recentFilesManager.resolveRecentFile(recentFile) else { return }

        // `focusedTabManager` already folds in the frontmost-window fallback,
        // which is nil only when no window exists at all — exactly when we want
        // the new-window branch below.
        if let tabManager = focusedTabManager {
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
        pdfManager?.copyMarkdown(scope: scope, comments: comments)
    }

    private func savePageAsMarkdownFile() {
        guard let manager = pdfManager, manager.permissions.copy else { return }
        let pageIndex = manager.currentPageIndex
        let filename = manager.documentURL?.deletingPathExtension().lastPathComponent ?? "document"
        saveMarkdownFile(scope: .currentPage(pageIndex), filename: "\(filename)-page\(pageIndex + 1).md")
    }

    private func saveAsMarkdownFile() {
        guard let manager = pdfManager, manager.permissions.copy else { return }
        let filename = manager.documentURL?.deletingPathExtension().lastPathComponent ?? "document"
        saveMarkdownFile(scope: .entireDocument, filename: "\(filename).md")
    }

    private func saveMarkdownFile(scope: ExportScope, filename: String) {
        guard let manager = pdfManager, let document = manager.document, manager.permissions.copy else { return }
        let revision = manager.closeRevision
        let requestedComments = comments
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard manager.document === document, manager.closeRevision == revision else {
                self.showAlert(message: "The PDF changed while choosing an export location. Please export it again.")
                return
            }
            manager.exportMarkdown(scope: scope, comments: requestedComments) { markdown in
                do {
                    try markdown.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self.showAlert(message: "Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }
}
