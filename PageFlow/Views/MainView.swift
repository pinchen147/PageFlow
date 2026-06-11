//
//  MainView.swift
//  PageFlow
//
//  Main application view with PDF display and controls
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct MainView: View {
    let tabID: UUID
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var tabUndoManager: UndoManager
    var isActive: Bool
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int
    @Bindable var tabManager: TabManager
    var onOpenFile: (URL, Bool, Bool) -> Void

    @State private var goToPageInput = ""
    @State private var goToPageError: String?
    @State private var isDragHovering = false
    @State private var isHoveringPageIndicator = false
    @State private var toastMessage: String?
    @State private var toastWorkItem: DispatchWorkItem?
    @State private var settingsManager = SettingsManager.shared

    private var showingGoToPage: Bool {
        get { tabManager.showingGoToPage(for: tabID) }
        nonmutating set { tabManager.setShowingGoToPage(newValue, for: tabID) }
    }

    private var showingFileImporter: Bool {
        get { tabManager.showingFileImporter(for: tabID) }
        nonmutating set { tabManager.setShowingFileImporter(newValue, for: tabID) }
    }

    private var showingGoToPageBinding: Binding<Bool> {
        Binding(
            // Gated on isActive like the sidebars and search bar: a hidden warm
            // tab's window-modal sheet would strand over the visible tab and
            // navigate the wrong document.
            get: { isActive && tabManager.showingGoToPage(for: tabID) },
            set: { tabManager.setShowingGoToPage($0, for: tabID) }
        )
    }

    private var showingOutline: Bool {
        get { tabManager.showingOutline(for: tabID) }
        nonmutating set { tabManager.setShowingOutline(newValue, for: tabID) }
    }

    private var showingComments: Bool {
        get { tabManager.showingComments(for: tabID) }
        nonmutating set { tabManager.setShowingComments(newValue, for: tabID) }
    }

    private var isEditingPages: Bool {
        get { tabManager.isEditingPages(for: tabID) }
        nonmutating set { tabManager.setIsEditingPages(newValue, for: tabID) }
    }

    private var isEditingPagesBinding: Binding<Bool> {
        Binding(
            get: { tabManager.isEditingPages(for: tabID) },
            set: { tabManager.setIsEditingPages($0, for: tabID) }
        )
    }

    private var topChromeHeight: CGFloat {
        TopChromeView.height(toolbarScale: settingsManager.toolbarScale)
    }

    private var isPageIndicatorVisible: Bool {
        settingsManager.isPageIndicatorAlwaysVisible || isHoveringPageIndicator
    }

    var body: some View {
        ZStack {
            if pdfManager.hasDocument {
                PDFViewWrapper(
                    pdfManager: pdfManager,
                    searchManager: searchManager,
                    annotationManager: annotationManager,
                    commentManager: commentManager,
                    bookmarkManager: bookmarkManager,
                    tabUndoManager: tabUndoManager,
                    isActive: isActive
                )
            } else {
                emptyState
            }
        }
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .topTrailing) {
            commentsSidebarOverlay
        }
        .overlay(alignment: .topLeading) {
            outlineSidebarOverlay
        }
        .overlay(alignment: .bottom) {
            // isActive gate: keeps inactive warm tabs' hover tracking areas out
            // of the window (same gate as the sidebars).
            if isActive, pdfManager.hasDocument {
                bottomPageBar
            }
        }
        .overlay(alignment: .bottom) {
            searchOverlay
        }
        .overlay(alignment: .center) {
            dragHoverOverlay
        }
        .sheet(isPresented: showingGoToPageBinding) {
            goToPageDialog
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
            handleDrop(providers: providers)
        }
        .ignoresSafeArea(.all, edges: .all)
        .onChange(of: pdfManager.hasDocument) { _, hasDoc in
            if !hasDoc {
                showingOutline = false
                showingComments = false
                bookmarkManager.clearBookmarks()
            } else {
                showingFileImporter = false
            }
        }
        .onChange(of: pdfManager.documentURL) { _, newURL in
            bookmarkManager.loadBookmarks(for: newURL)
        }
        .onAppear {
            if !pdfManager.hasDocument {
                // On older macOS, pending URLs from application(_:open:) will be
                // flushed synchronously by TabContainerView.onAppear before this fires.
                // On macOS 15+, onOpenURL delivers the file asynchronously — delay
                // the file picker to give it time to arrive.
                let hasPending = !(AppDelegate.shared?.pendingURLs.isEmpty ?? true)
                if !hasPending && !tabManager.isAwaitingPassword(for: tabID) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [pdfManager, tabManager] in
                        guard !pdfManager.hasDocument,
                              !tabManager.isAwaitingPassword(for: tabID),
                              !tabManager.consumeAutomaticFilePickerSuppression() else {
                            return
                        }
                        tabManager.openFilePicker()
                    }
                }
            }
        }
        .onChange(of: commentManager.selectedCommentID) { _, newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                    showingComments = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveResult)) { notification in
            // Only show toast in the active tab to prevent all tabs showing "Saved"
            guard isActive,
                  let info = notification.userInfo as? [String: String],
                  let message = info["message"] else { return }
            showToast(message)
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                toastView(message: toastMessage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, DesignTokens.spacingMD)
            }
        }
    }

    private var commentsSidebarOverlay: some View {
        ZStack(alignment: .topTrailing) {
            // Only the active warm tab mounts its sidebar: an inactive tab's
            // invisible copy keeps AppKit machinery alive (ClickCatcher's click
            // recognizers, the comment text editor) that competes with the
            // active tab's sidebar for clicks and focus — same class of bug as
            // the SearchBar focus gate below.
            if isActive, showingComments, pdfManager.hasDocument {
                CommentsSidebar(
                    commentManager: commentManager,
                    onClose: { showingComments = false }
                )
                .onExitCommand { showingComments = false }
                .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingXS)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingComments)
    }

    private var outlineSidebarOverlay: some View {
        ZStack(alignment: .topLeading) {
            // Same gate as the comments sidebar: the thumbnail grid's AppKit
            // reporters and drag machinery must not stay mounted in inactive
            // warm tabs.
            if isActive, showingOutline, pdfManager.hasDocument {
                SidebarView(
                    pdfManager: pdfManager,
                    bookmarkManager: bookmarkManager,
                    isEditingPages: isEditingPagesBinding,
                    items: pdfManager.outlineItems(),
                    onClose: { showingOutline = false }
                )
                .onExitCommand {
                    isEditingPages = false
                    showingOutline = false
                }
                .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.leading, DesignTokens.spacingXS)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline)
    }

    private var searchOverlay: some View {
        ZStack(alignment: .bottom) {
            // `showingSearch` is window-level state shared by every warm tab; only
            // the active tab presents the bar so an inactive tab can't grab focus.
            if isActive && showingSearch {
                SearchBar(
                    searchManager: searchManager,
                    pdfManager: pdfManager,
                    isVisible: $showingSearch,
                    focusRequest: searchFocusRequest
                )
                .padding(.bottom, DesignTokens.spacingXS)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingSearch)
    }

    private var dragHoverOverlay: some View {
        ZStack {
            if isDragHovering {
                dropTargetOverlay
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDragHovering)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingLG) {
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No PDF Open")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("Open PDF") {
                tabManager.openFilePicker()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DesignTokens.spacingMD)
            .padding(.vertical, DesignTokens.spacingSM)
            .pageFlowLiquidGlassPanel(.primaryButton)

            Text("or drag and drop a PDF file here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page Indicator

    private var pageIndicator: some View {
        Button {
            showingGoToPage = true
        } label: {
            Text("Page \(pdfManager.currentPageIndex + 1) of \(pdfManager.pageCount)")
                .font(.caption)
                .fontWeight(.medium)
                .pageFlowGlassControlLabel()
                .padding(.horizontal, DesignTokens.spacingSM + 2)
                .padding(.vertical, DesignTokens.spacingSM)
                .pageFlowLiquidGlassSurface(.pageIndicator)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: 10, y: -3)
        .padding(.bottom, DesignTokens.spacingXS)
        .padding(.trailing, DesignTokens.spacingMD)
    }

    private var bottomPageBar: some View {
        HStack {
            Spacer()
            if isPageIndicatorVisible {
                pageIndicator
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: topChromeHeight)
        .overlay(ChromeHoverSensor(isHovered: $isHoveringPageIndicator))
    }

    // MARK: - Go To Page Dialog

    private var goToPageDialog: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            Text("Go to Page")
                .font(.headline)

            TextField("Page number", text: $goToPageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: DesignTokens.textFieldWidth)
                .onSubmit {
                    goToPage()
                }

            if let error = goToPageError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("Cancel") {
                    showingGoToPage = false
                    goToPageInput = ""
                    goToPageError = nil
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    goToPage()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.spacingLG)
        .frame(width: DesignTokens.dialogWidth)
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else {
            return
        }

        // File importer returns security-scoped URLs - use callback to open in new tab
        DispatchQueue.main.async {
            onOpenFile(url, true, false)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        // Resolve every dropped file URL in drop order, then open them as tabs in this
        // window in one batch (TabManager.openDroppedDocuments handles dedup,
        // empty-tab reuse, failed-file rollback, and a single bring-to-front).
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                guard let url = await provider.loadDroppedFileURL(),
                      url.pathExtension.lowercased() == "pdf" else { continue }
                urls.append(url)
            }
            guard !urls.isEmpty else { return }

            tabManager.closeFilePicker()
            let failed = tabManager.openDroppedDocuments(urls)
            if failed > 0 {
                showToast(failed == 1 ? "Couldn’t open 1 file" : "Couldn’t open \(failed) files")
            }
        }

        return true
    }

    private func goToPage() {
        guard let pageNumber = Int(goToPageInput) else {
            goToPageError = "Please enter a valid number."
            return
        }

        guard pageNumber > 0, pageNumber <= pdfManager.pageCount else {
            goToPageError = "Page must be between 1 and \(pdfManager.pageCount)."
            return
        }

        pdfManager.goToPage(pageNumber - 1)
        showingGoToPage = false
        goToPageInput = ""
        goToPageError = nil
    }

    private var dropTargetOverlay: some View {
        ZStack {
            VStack(spacing: DesignTokens.spacingSM) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28, weight: .semibold))
                Text("Drop PDF to Open")
                    .font(.headline)
                Text("Drag a PDF anywhere in the window")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(DesignTokens.spacingLG)
        }
        .padding(DesignTokens.spacingLG)
        .pageFlowLiquidGlassPanel(.dropZone)
    }

    // MARK: - Toast

    private func showToast(_ message: String) {
        toastWorkItem?.cancel()
        toastMessage = message
        let workItem = DispatchWorkItem { self.toastMessage = nil }
        toastWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    private func toastView(message: String) -> some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, DesignTokens.spacingMD)
            .padding(.vertical, DesignTokens.spacingXS)
            .pageFlowLiquidGlassPanel(.glassPanel)
    }
}

// MARK: - Window Title Updater

/// Sets NSWindow.title for Dock menu display (title bar remains hidden)
struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        let view = WindowTitleView()
        view.title = title
        return view
    }

    func updateNSView(_ nsView: WindowTitleView, context: Context) {
        nsView.title = title
    }
}

final class WindowTitleView: NSView {
    var title = "" {
        didSet {
            updateTitleIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTitleIfNeeded()
    }

    private func updateTitleIfNeeded() {
        guard let window, window.title != title else { return }
        window.title = title
    }
}

// MARK: - Drop Helpers

private extension NSItemProvider {
    /// Resolves a dropped file URL, handling the `Data` / `URL` / `NSURL`
    /// representations AppKit may deliver. Returns nil if the item is not a file URL.
    func loadDroppedFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let value as URL: url = value
                case let value as NSURL: url = value as URL
                default: url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}

#Preview {
    MainView(
        tabID: UUID(),
        pdfManager: PDFManager(),
        searchManager: SearchManager(),
        annotationManager: AnnotationManager(),
        commentManager: CommentManager(),
        bookmarkManager: BookmarkManager(),
        tabUndoManager: UndoManager(),
        isActive: true,
        showingSearch: .constant(false),
        searchFocusRequest: 0,
        tabManager: TabManager(),
        onOpenFile: { _, _, _ in }
    )
}
