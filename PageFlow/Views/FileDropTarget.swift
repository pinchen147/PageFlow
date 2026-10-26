//
//  FileDropTarget.swift
//  PageFlow
//
//  The ONE file-drop surface for a tab, shared by PDF (`PDFTabView`) and
//  Markdown (`MarkdownTabView`): drop .pdf/.md files anywhere on the document
//  to open them in this window — same batch-open semantics (dedup, empty-tab
//  reuse, failure rollback + toast) for both content types. The hover
//  indicator is drawn once per window (`FileDropOverlay`, mounted by
//  `TabContainerView`), so it can outline the whole window above the chrome.
//  Over a Markdown note's text and gutters the editor owns the drag instead
//  (doc 26 §9.1): it opens documents through the same batch, copies images
//  into the note, and tells `TabManager` whether the overlay should show.
//

import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Makes this tab surface a drop target for openable documents. A Markdown
    /// tab passes `hintsImagesGoInTheNote`: images dropped here, outside the
    /// note's text (over the top chrome), add nothing and say where they go;
    /// over the text the editor takes them (doc 26 §9.1).
    func pageFlowFileDropTarget(tabManager: TabManager, hintsImagesGoInTheNote: Bool = false) -> some View {
        modifier(FileDropTarget(tabManager: tabManager, hintsImagesGoInTheNote: hintsImagesGoInTheNote))
    }
}

private struct FileDropTarget: ViewModifier {
    let tabManager: TabManager
    let hintsImagesGoInTheNote: Bool
    @State private var isDragHovering = false

    static let imageHint = "Drop over the note to add images. Nothing was added."

    func body(content: Content) -> some View {
        content
            .onDrop(of: hintsImagesGoInTheNote ? [.fileURL, .image] : [.fileURL], isTargeted: $isDragHovering) { providers in
                handleDrop(providers: providers)
            }
            .onChange(of: isDragHovering) { _, hovering in
                tabManager.isTabSurfaceDropHovering = hovering
            }
            .onDisappear {
                if isDragHovering { tabManager.isTabSurfaceDropHovering = false }
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        // Image data or a promised image (a browser, Photos): only ever a hint.
        let carriesImageData = hintsImagesGoInTheNote && providers.contains {
            !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !fileProviders.isEmpty || carriesImageData else { return false }

        // Resolve every dropped file URL in drop order, then open them as tabs in
        // this window in one batch (TabManager.openDroppedDocuments handles dedup,
        // empty-tab reuse, failed-file rollback, and a single bring-to-front).
        let tabManager = self.tabManager
        let hintsImages = hintsImagesGoInTheNote
        Task { @MainActor in
            var urls: [URL] = []
            var droppedImages = carriesImageData
            for provider in fileProviders {
                guard let url = await provider.loadDroppedFileURL() else { continue }
                if url.pageFlowIsOpenableDocument {
                    urls.append(url)
                } else if hintsImages, PastedImageStore.isImage(url) {
                    droppedImages = true
                }
            }
            if !urls.isEmpty { tabManager.openDroppedFiles(urls) }
            if droppedImages { tabManager.postTransientToast(Self.imageHint) }
        }

        return true
    }
}

/// The window-wide drop indicator: the window behind softened by a thin material
/// (so the label reads over any page), a dashed outline just inside the window
/// edge, and the app's document glyphs (PDF, documents, Markdown) fanned over
/// "Drop files here". Everything is drawn in the primary label colour: black in
/// light mode, white in dark.
struct FileDropOverlay: View {
    let isVisible: Bool

    var body: some View {
        ZStack {
            if isVisible {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignTokens.fileDropOutlineCornerRadius, style: .continuous)
                        .strokeBorder(
                            .primary,
                            style: StrokeStyle(
                                lineWidth: DesignTokens.fileDropOutlineWidth,
                                lineCap: .round,
                                dash: DesignTokens.fileDropOutlineDash
                            )
                        )
                        .padding(DesignTokens.fileDropOutlineInset)
                    VStack(spacing: DesignTokens.spacingMD) {
                        HStack(alignment: .bottom, spacing: DesignTokens.fileDropGlyphSpacing) {
                            glyph(ContentKind.pdf.tabIconSystemName, tilt: -DesignTokens.fileDropGlyphTilt)
                            glyph("doc.on.doc", tilt: 0)
                                .offset(y: -DesignTokens.fileDropGlyphLift)
                            // The app's Markdown-file glyph ("Copy Page as Markdown"); the
                            // Markdown tab's bare lines don't read as a file in the fan.
                            glyph("doc.text", tilt: DesignTokens.fileDropGlyphTilt)
                        }
                        Text("Drop files here")
                            .font(.body.weight(.medium))
                    }
                }
                .foregroundStyle(.primary)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isVisible)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func glyph(_ systemName: String, tilt: Double) -> some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.fileDropGlyphSize, weight: .light))
            .rotationEffect(.degrees(tilt))
    }
}
