//
//  PDFTabView.swift
//  PageFlow
//
//  The view a `.pdf` tab mounts — the PDF branch of `TabRender`, peer of
//  `MarkdownTabView`. Mounted through `TabRenderView`. (Formerly `MainView`.)
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PDFTabView: View {
    let tabID: UUID
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var tabUndoManager: UndoManager
    var isActive: Bool
    var isDisplayed: Bool = true
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int
    @Bindable var tabManager: TabManager
    var onRequestFocus: () -> Void = {}

    @State private var isHoveringPageIndicator = false
    @State private var settingsManager = SettingsManager.shared

    private var showingGoToPage: Bool {
        get { tabManager.showingGoToPage(for: tabID) }
        nonmutating set { tabManager.setShowingGoToPage(newValue, for: tabID) }
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
                    isActive: isActive,
                    isDisplayed: isDisplayed,
                    onRequestFocus: onRequestFocus
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
            FindOverlay(
                driver: pdfFindDriver,
                isActive: isActive,
                showingSearch: $showingSearch,
                focusRequest: searchFocusRequest
            )
        }
        .pageFlowFileDropTarget(tabManager: tabManager)
        .sheet(isPresented: showingGoToPageBinding) {
            goToPageDialog
        }
        .ignoresSafeArea(.all, edges: .all)
        .onChange(of: pdfManager.hasDocument) { _, hasDoc in
            if !hasDoc {
                showingOutline = false
                showingComments = false
                bookmarkManager.clearBookmarks()
            }
        }
        .onChange(of: pdfManager.documentURL) { _, newURL in
            bookmarkManager.loadBookmarks(for: newURL)
        }
        .onChange(of: commentManager.selectedCommentID) { _, newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                    showingComments = true
                }
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

    /// The PDF Find backend as a `FindDriving`. A fresh value each `body` (no
    /// observable-state mutation to build it); it resolves the document and pushes
    /// nav state internally, so PDF find behaves exactly as the old inline bar did.
    /// The PDF search path itself is byte-identical.
    private var pdfFindDriver: PDFFindDriver {
        PDFFindDriver(searchManager: searchManager, pdfManager: pdfManager)
    }

    // MARK: - Empty State

    /// The window's blank-tab state — content-NEUTRAL: an empty tab can become
    /// a PDF or a Markdown document (the picker and the drop target both accept
    /// both), and it can start a fresh Markdown document in place (⌘⇧N's action).
    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingLG) {
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Document Open")
                .font(.title2)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignTokens.spacingMD) {
                Button("Open Document") {
                    tabManager.openFilePicker()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingSM)
                .pageFlowLiquidGlassPanel(.primaryButton)

                Button("New Markdown") {
                    tabManager.newMarkdownDocument()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingSM)
                .pageFlowLiquidGlassPanel(.primaryButton)
            }

            Text("or drag and drop a PDF or Markdown file here")
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
        GoToDialog(
            title: "Go to Page",
            prompt: "Page number",
            onSubmit: { page in
                guard page > 0, page <= pdfManager.pageCount else {
                    return "Page must be between 1 and \(pdfManager.pageCount)."
                }
                pdfManager.goToPage(page - 1)
                return nil
            },
            isPresented: showingGoToPageBinding
        )
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

extension NSItemProvider {
    /// Resolves a dropped file URL, handling the `Data` / `URL` / `NSURL`
    /// representations AppKit may deliver. Returns nil if the item is not a file URL.
    /// Shared by the content-agnostic `FileDropTarget`.
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
    PDFTabView(
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
        tabManager: TabManager()
    )
}
