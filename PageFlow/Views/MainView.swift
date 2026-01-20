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
    var isActive: Bool
    @Binding var showingSearch: Bool
    @Binding var showingToolbar: Bool
    @Binding var isTopBarHovered: Bool
    @Bindable var tabManager: TabManager
    var onOpenFile: (URL, Bool, Bool) -> Void

    @State private var goToPageInput = ""
    @State private var goToPageError: String?
    @State private var isDragHovering = false
    @State private var isBottomBarHovered = false
    @State private var toastMessage: String?
    @State private var toastWorkItem: DispatchWorkItem?

    private var showingGoToPage: Bool {
        get { tabManager.showingGoToPageState[tabID] ?? false }
        nonmutating set { tabManager.setShowingGoToPage(newValue, for: tabID) }
    }

    private var showingFileImporter: Bool {
        get { tabManager.showingFileImporterState[tabID] ?? false }
        nonmutating set { tabManager.setShowingFileImporter(newValue, for: tabID) }
    }

    private var showingGoToPageBinding: Binding<Bool> {
        Binding(
            get: { tabManager.showingGoToPageState[tabID] ?? false },
            set: { tabManager.setShowingGoToPage($0, for: tabID) }
        )
    }

    private var showingFileImporterBinding: Binding<Bool> {
        Binding(
            get: { tabManager.showingFileImporterState[tabID] ?? false },
            set: { tabManager.setShowingFileImporter($0, for: tabID) }
        )
    }

    private var showingOutline: Bool {
        get { tabManager.showingOutlineState[tabID] ?? false }
        nonmutating set { tabManager.setShowingOutline(newValue, for: tabID) }
    }

    private var showingOutlineBinding: Binding<Bool> {
        Binding(
            get: { tabManager.showingOutlineState[tabID] ?? false },
            set: { tabManager.setShowingOutline($0, for: tabID) }
        )
    }

    private var showingComments: Bool {
        get { tabManager.showingCommentsState[tabID] ?? false }
        nonmutating set { tabManager.setShowingComments(newValue, for: tabID) }
    }

    private var showingCommentsBinding: Binding<Bool> {
        Binding(
            get: { tabManager.showingCommentsState[tabID] ?? false },
            set: { tabManager.setShowingComments($0, for: tabID) }
        )
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
                    isActive: isActive
                )
            } else {
                emptyState
            }
        }
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .topTrailing) {
            if showingComments, pdfManager.hasDocument {
                CommentsSidebar(
                    commentManager: commentManager,
                    onClose: { showingComments = false }
                )
                .onExitCommand { showingComments = false }
                .padding(.top, DesignTokens.trafficLightHotspotHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingXS)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingComments)
        .overlay(alignment: .topLeading) {
            if showingOutline, pdfManager.hasDocument {
                SidebarView(
                    pdfManager: pdfManager,
                    bookmarkManager: bookmarkManager,
                    tabManager: tabManager,
                    items: pdfManager.outlineItems(),
                    onClose: { showingOutline = false }
                )
                .onExitCommand {
                    tabManager.isEditingPages = false
                    showingOutline = false
                }
                .padding(.top, DesignTokens.trafficLightHotspotHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.leading, DesignTokens.spacingXS)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingComments)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                // Window drag region - thin strip at very top
                WindowDragArea()
                    .frame(height: DesignTokens.windowDragRegionHeight)
                    .frame(maxWidth: .infinity)

                // Tab bar area
                HStack(spacing: 0) {
                    // Traffic lights
                    TrafficLightsView(isHovering: $isTopBarHovered)
                        .padding(DesignTokens.spacingXS)

                    // Tab bar - fills remaining space between traffic lights and toolbar
                    TabBarView(tabManager: tabManager, isHovering: $isTopBarHovered)
                        .frame(maxWidth: .infinity)

                    // Floating toolbar (pinned or auto-hide on hover)
                    FloatingToolbar(
                        pdfManager: pdfManager,
                        annotationManager: annotationManager,
                        commentManager: commentManager,
                        bookmarkManager: bookmarkManager,
                        onOpenFilePicker: { tabManager.openFilePicker() },
                        isTopBarHovered: $isTopBarHovered,
                        showingOutline: showingOutlineBinding,
                        showingComments: showingCommentsBinding,
                        toolbarPinned: showingToolbar
                    )
                    .padding(.top, DesignTokens.spacingXS)
                    .padding(.trailing, DesignTokens.floatingToolbarPadding)
                }
                .frame(maxWidth: .infinity)
                .frame(height: DesignTokens.trafficLightHotspotHeight - DesignTokens.windowDragRegionHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.trafficLightHotspotHeight)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isTopBarHovered = true
                case .ended:
                    isTopBarHovered = false
                }
            }
        }
        .overlay(alignment: .bottom) {
            if pdfManager.hasDocument {
                bottomHoverBar
            }
        }
        .overlay(alignment: .bottom) {
            if showingSearch {
                SearchBar(searchManager: searchManager, pdfManager: pdfManager, isVisible: $showingSearch)
                    .padding(.bottom, DesignTokens.spacingXS)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .center) {
            if isDragHovering {
                dropTargetOverlay
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: showingGoToPageBinding) {
            goToPageDialog
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
            handleDrop(providers: providers)
        }
        .onOpenURL { url in
            handleOpenURL(url)
        }
        .animation(.easeInOut(duration: 0.15), value: isDragHovering)
        .animation(.easeInOut(duration: 0.2), value: showingSearch)
        .onChange(of: showingSearch) { _, isShowing in
            if !isShowing {
                searchManager.clearSearch()
            }
        }
        .toolbar(.hidden)
        .background(WindowConfigurator())
        .background(WindowTitleUpdater(title: pdfManager.documentTitle))
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
                tabManager.openFilePicker()
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
            .buttonStyle(.borderedProminent)

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
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.spacingSM + 2)
                .padding(.vertical, DesignTokens.spacingSM)
                .background(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                        .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                        .allowsHitTesting(false)
                )
                .cornerRadius(DesignTokens.floatingToolbarCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                        .strokeBorder(.white.opacity(0.22))
                        .allowsHitTesting(false)
                )
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        .padding(.bottom, DesignTokens.spacingXS)
        .padding(.trailing, DesignTokens.spacingMD)
    }

    private var bottomHoverBar: some View {
        let isIndicatorVisible = isBottomBarHovered || showingGoToPage

        return HStack {
            Spacer()
            pageIndicator
                .opacity(isIndicatorVisible ? 1 : 0)
                .allowsHitTesting(isIndicatorVisible)
                .animation(.easeInOut(duration: DesignTokens.animationFast), value: isIndicatorVisible)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DesignTokens.trafficLightHotspotHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isBottomBarHovered = true
            case .ended:
                isBottomBarHovered = false
            }
        }
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
        guard let provider = providers.first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?

            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let urlItem = item as? URL {
                url = urlItem
            } else if let nsURL = item as? NSURL {
                url = nsURL as URL
            } else {
                url = nil
            }

            guard let url = url, url.pathExtension.lowercased() == "pdf" else { return }

            DispatchQueue.main.async { [tabManager, onOpenFile] in
                tabManager.closeFilePicker()
                onOpenFile(url, false, false)
            }
        }

        return true
    }

    private func handleOpenURL(_ url: URL) {
        DispatchQueue.main.async { [tabManager, onOpenFile] in
            tabManager.closeFilePicker()
            onOpenFile(url, true, false)
        }
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
            RoundedRectangle(cornerRadius: DesignTokens.spacingMD)
                .fill(.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.spacingMD)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundStyle(.white.opacity(0.65))
                )

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
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
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
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius)
                    .strokeBorder(.white.opacity(0.22))
                    .allowsHitTesting(false)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.floatingToolbarCornerRadius))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
}

// MARK: - Window Title Updater

/// Sets NSWindow.title for Dock menu display (title bar remains hidden)
struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
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
        isActive: true,
        showingSearch: .constant(false),
        showingToolbar: .constant(true),
        isTopBarHovered: .constant(false),
        tabManager: TabManager(),
        onOpenFile: { _, _, _ in }
    )
}
