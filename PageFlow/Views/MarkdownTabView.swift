//
//  MarkdownTabView.swift
//  PageFlow
//
//  The view a Markdown tab mounts — the peer of `PDFTabView` for `.pdf` content.
//  A Live Preview editor plus the Markdown side of the shared chrome (S7): the
//  format toolbar lives in the shared top chrome (TopChromeView), a collapsible
//  heading outline (the sidebar's markdown content), a word-count chip that
//  mirrors the PDF page indicator (same glass surface, same hover-reveal strip,
//  same "always visible" setting), and the shared Find bar. Routed to from the
//  window's `TabRender` switch (`TabRenderView`, mounted by `TabContainerView`).
//
//  Color scheme (Feature 2): the FORCED Markdown scheme is applied here, at the
//  tab-surface boundary — a scheme-resolved reading background behind the clear
//  engine editor plus `.environment(\.colorScheme)` over the whole surface
//  (editor, chip, outline, Find). The engine's `forcedAppearanceName` knob is
//  the AppKit leg of the same setting. Window chrome (tab bar / toolbar)
//  deliberately keeps following the system.
//

import SwiftUI
import MarkdownEngine

@MainActor
struct MarkdownTabView: View {
    /// Stable per-tab id (= `TabSession.id`), handed to the engine for scroll
    /// retention and the scoped bus.
    let tabID: UUID

    /// This tab's Markdown backend — the durable text document, save-time
    /// controller (fork P1), scoped bus (fork P2), and Find backend (S7a). `@Bindable`
    /// so the editor binds to `content.documentManager.text` and the chrome reacts
    /// to edits; the view reaches its collaborators through it rather than taking
    /// each unpacked as a separate parameter.
    @Bindable var content: MarkdownContent

    /// Whether this is the active tab. Only the active tab shows the Find bar and
    /// the bottom hover strip (window-level `showingSearch` is shared across warm tabs).
    let isActive: Bool

    /// Whether this tab is on-screen (S8 P2): the warm ZStack shows only the active
    /// tab. A NOT-displayed warm editor is hidden at
    /// the AppKit level by the engine (no draw, no hit-testing, no keyboard) — the
    /// markdown peer of PDFViewWrapper's warm gate.
    var isDisplayed: Bool = true

    /// A click inside the editor makes this tab active (PDF parity: the same
    /// wiring `PDFTabView` gets from `TabRenderView`).
    var onRequestFocus: (() -> Void)? = nil

    /// The window's warm-set `documentId`s (S8 P2), forwarded to the engine so each
    /// mounted markdown tab keeps its own scroll offset across switches.
    var retainedScrollDocumentIds: Set<String>? = nil

    /// Window-level Find visibility, shared by every warm tab (peer of `PDFTabView`).
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int

    /// Canonical per-tab UI state (`TabSession.uiState`) — the sidebar toggle binds
    /// the SAME slot the PDF sidebar uses (PDFTabView pattern), so "outline is open"
    /// has exactly one home per tab across content types.
    let tabManager: TabManager

    /// Reading-margin + color-scheme settings (Features 1/2). Observed so toggling a
    /// preference (or resizing the toolbar) re-lays the editor live.
    @State private var settingsManager = SettingsManager.shared

    /// Mirrors `PDFTabView.isHoveringPageIndicator`: the bottom strip reveals the
    /// word-count chip on hover.
    @State private var isHoveringWordCount = false

    /// The system scheme from above, so forcing `.system` puts back exactly the
    /// inherited value (one stable view tree — no remount on scheme toggles).
    @Environment(\.colorScheme) private var systemColorScheme

    private var outline: [MarkdownOutlineItem] { content.documentManager.outline }
    private var wordCount: WordCount { content.documentManager.wordCount }

    private var showingOutline: Bool {
        get { tabManager.showingOutline(for: tabID) }
        nonmutating set { tabManager.setShowingOutline(newValue, for: tabID) }
    }

    /// Top clearance so the editor's first line scrolls out from under the floating
    /// tab-bar/toolbar chrome it sits beneath (`TopChromeView`), plus 24pt breathing
    /// room above the H1. Tracks `toolbarScale` live (Feature 1).
    private var topInset: CGFloat {
        TopChromeView.height(toolbarScale: settingsManager.toolbarScale) + DesignTokens.markdownFirstLineGap
    }

    /// The PDF page indicator's visibility rule, verbatim (`PDFTabView`): the shared
    /// "always visible" setting, else the bottom hover strip.
    private var isWordCountVisible: Bool {
        settingsManager.isPageIndicatorAlwaysVisible || isHoveringWordCount
    }

    /// Two-way binding onto the durable text. Built by hand because
    /// `MarkdownContent.documentManager` is a `let`, so `$content.documentManager.text`
    /// can't chain a `ReferenceWritableKeyPath` through it. Edits flow straight into
    /// the durable buffer, exactly as the former `$documentManager.text` did.
    private var textBinding: Binding<String> {
        Binding(
            get: { [weak content] in content?.documentManager.text ?? "" },
            set: { [weak content] in content?.documentManager.text = $0 }
        )
    }

    var body: some View {
        let _ = PerfTrace.stamp("tabView.body")
        ZStack(alignment: .top) {
            // The reading surface: the engine editor is deliberately
            // transparent, so the scheme-resolved background lives here.
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            MarkdownEditorSurface(content: content, tabManager: tabManager, tabID: tabID, editor: MarkdownEditorView(
                text: textBinding,
                documentId: content.documentId,
                editorController: content.editorController,
                bus: content.bus,
                fontName: settingsManager.markdownFontFamily,
                fontSize: settingsManager.markdownFontSize,
                isDisplayed: isDisplayed,
                isFocused: isActive && isDisplayed,
                onRequestFocus: onRequestFocus,
                readingPositionRequest: content.pendingReadingPosition,
                imageProvider: content.imageProvider,
                onPasteImage: { [weak content, weak tabManager] pasteboard in
                    guard let content else { return nil }
                    return PastedImageStore.shared.markdownLinks(
                        for: pasteboard, documentURL: content.documentManager.documentURL,
                        report: { tabManager?.postTransientToast($0) }
                    )
                },
                // The editor is the deepest drop target over the text and its
                // gutters, so the tab's own drop target never sees these files
                // (doc 26 §9.1): documents open as tabs, images are copied
                // beside the note and land where the drop line showed.
                onDropDocuments: { [weak tabManager] urls in
                    guard let tabManager else { return false }
                    DispatchQueue.main.async { tabManager.openDroppedFiles(urls) }
                    return true
                },
                opensDroppedFile: { $0.pageFlowIsOpenableDocument },
                onImportImages: { [weak content, weak tabManager] drop, completion in
                    guard let content else { return completion([]) }
                    PastedImageStore.shared.importImages(
                        drop.fileURLs, data: drop.imageData,
                        documentURL: { [weak content] in content?.documentManager.documentURL }
                    ) { imported in
                        if let message = imported.message { tabManager?.postTransientToast(message) }
                        completion(imported.links)
                    }
                },
                // The window overlay stays for documents; for images the
                // editor's drop line shows instead, unblurred.
                onFileDragHover: { [weak tabManager] kind in
                    tabManager?.editorFileDragShowsOverlay = kind.map { $0 == .documents }
                },
                onOpenLocalLink: { [weak tabManager, weak content] link in
                    guard let tabManager, let content else { return }
                    tabManager.openLocalLink(link, from: content)
                },
                retainedScrollDocumentIds: retainedScrollDocumentIds,
                topInset: topInset,
                sideMargin: settingsManager.markdownSideMargin,
                centersZoomedOut: settingsManager.markdownCentersZoomedOut,
                pageLook: settingsManager.markdownPageLook,
                showsHiddenContentRow: settingsManager.markdownShowsHiddenContentRow,
                forcedAppearanceName: settingsManager.markdownColorScheme.forcedAppearanceName,
                undoManager: content.undoManager,
                zoomScale: content.zoomScale,
                onZoomChanged: { [weak content] in content?.handleMagnificationChanged($0) }
            ), railEnabled: isActive && isDisplayed && settingsManager.showNavigationRail && !showingOutline,
                railTopInset: TopChromeView.height(toolbarScale: settingsManager.toolbarScale),
                onShowSidebar: { showingOutline = true })
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FindOverlay(
                driver: content.searchManager,
                isActive: isActive,
                showingSearch: $showingSearch,
                focusRequest: searchFocusRequest
            )
        }
        // The outline floats over the editor exactly like the PDF sidebar
        // floats over the document (PDFTabView.outlineSidebarOverlay).
        .overlay(alignment: .topLeading) {
            outlineSidebarOverlay
        }
        // the reference editor's comment toasts ("Link copied") show as this window's toast.
        .onAppear {
            content.showCommentToasts { [weak tabManager] message in tabManager?.postTransientToast(message) }
        }
        .pageFlowFileDropTarget(tabManager: tabManager, hintsImagesGoInTheNote: true)
        .sheet(isPresented: showingGoToLineBinding) {
            goToLineDialog
        }
        .overlay(alignment: .bottom) {
            // isActive gate: keeps inactive warm tabs' hover tracking out of the
            // window (same gate as PDFTabView's bottomPageBar).
            if isActive {
                bottomWordBar
            }
        }
        // Feature 2: the forced scheme covers the WHOLE tab surface (editor
        // background, chip, outline, Find) — window chrome stays system.
        .environment(\.colorScheme, settingsManager.markdownColorScheme.forcedColorScheme ?? systemColorScheme)
    }

    private var outlineSidebarOverlay: some View {
        ZStack(alignment: .topLeading) {
            // Same gate as the PDF sidebars: no overlays mounted in inactive warm tabs.
            if isActive, showingOutline {
                MarkdownOutlineSidebar(
                    items: outline,
                    onSelect: { content.scrollToOutlineItem($0) },
                    onClose: { showingOutline = false }
                )
                .onExitCommand { showingOutline = false }
                .padding(.top, TopChromeView.height(toolbarScale: settingsManager.toolbarScale) + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.leading, DesignTokens.spacingXS)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline)
    }

    // MARK: - Go to Line (the MD side of the PDF's Go to Page dialog)

    /// Gated on isActive like the PDF's: a hidden warm tab's window-modal sheet
    /// would strand over the visible tab and navigate the wrong document.
    private var showingGoToLineBinding: Binding<Bool> {
        Binding(
            get: { isActive && tabManager.showingGoToPage(for: tabID) },
            set: { tabManager.setShowingGoToPage($0, for: tabID) }
        )
    }

    private var goToLineDialog: some View {
        GoToDialog(
            title: "Go to Line",
            prompt: "Line number",
            onSubmit: { line in
                let count = content.lineCount
                guard line > 0, line <= count else {
                    return "Line must be between 1 and \(count)."
                }
                content.scrollToLine(line - 1)
                return nil
            },
            isPresented: showingGoToLineBinding
        )
    }

    // MARK: - Word-count chip (the bottom-bar slot, mirroring the PDF page indicator)

    private var bottomWordBar: some View {
        HStack {
            Spacer()
            if isWordCountVisible {
                wordCountChip
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: TopChromeView.height(toolbarScale: settingsManager.toolbarScale))
        .overlay(ChromeHoverSensor(isHovered: $isHoveringWordCount))
    }

    /// Same glass surface, shadow, and paddings as `PDFTabView.pageIndicator` —
    /// but inert: word count has no click target.
    private var wordCountChip: some View {
        Text(wordCount.label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
            .padding(.horizontal, DesignTokens.spacingSM + 2)
            .padding(.vertical, DesignTokens.spacingSM)
            .pageFlowLiquidGlassSurface(.pageIndicator)
            .shadow(color: .black.opacity(DesignTokens.glassElevationShadowOpacity), radius: 10, y: -3)
            .padding(.bottom, DesignTokens.spacingXS)
            .padding(.trailing, DesignTokens.spacingMD)
    }

}
