//
//  FileDropTarget.swift
//  PageFlow
//
//  The ONE file-drop surface for a tab, shared by PDF (`PDFTabView`) and
//  Markdown (`MarkdownTabView`): drop .pdf/.md files anywhere on the document
//  to open them in this window — same hover overlay, same batch-open
//  semantics (dedup, empty-tab reuse, failure rollback + toast) for both
//  content types.
//

import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Makes this tab surface a drop target for openable documents.
    func pageFlowFileDropTarget(tabManager: TabManager) -> some View {
        modifier(FileDropTarget(tabManager: tabManager))
    }
}

private struct FileDropTarget: ViewModifier {
    let tabManager: TabManager
    @State private var isDragHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .center) {
                ZStack {
                    if isDragHovering {
                        dropTargetOverlay
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isDragHovering)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragHovering) { providers in
                handleDrop(providers: providers)
            }
    }

    private var dropTargetOverlay: some View {
        VStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .semibold))
            Text("Drop to Open")
                .font(.headline)
            Text("Drag a PDF or Markdown file anywhere in the window")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(DesignTokens.spacingLG)
        .padding(DesignTokens.spacingLG)
        .pageFlowLiquidGlassPanel(.dropZone)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        // Resolve every dropped file URL in drop order, then open them as tabs in
        // this window in one batch (TabManager.openDroppedDocuments handles dedup,
        // empty-tab reuse, failed-file rollback, and a single bring-to-front).
        let tabManager = self.tabManager
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                guard let url = await provider.loadDroppedFileURL(),
                      url.pageFlowIsOpenableDocument else { continue }
                urls.append(url)
            }
            guard !urls.isEmpty else { return }
            tabManager.openDroppedFiles(urls)
        }

        return true
    }
}
