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
    @State private var pdfManager = PDFManager()
    @State private var showingFileImporter = false
    @State private var showingGoToPage = false
    @State private var goToPageInput = ""

    var body: some View {
        ZStack {
            if pdfManager.hasDocument {
                PDFViewWrapper(pdfManager: pdfManager)
                    .overlay(alignment: .bottomTrailing) {
                        pageIndicator
                    }
            } else {
                emptyState
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showingGoToPage) {
            goToPageDialog
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        .onOpenURL { url in
            _ = pdfManager.loadDocument(from: url)
        }
        .toolbar {
            ToolbarItemGroup {
                toolbarContent
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
                showingFileImporter = true
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
        HStack(spacing: DesignTokens.spacingSM) {
            Text("Page \(pdfManager.currentPageIndex + 1) of \(pdfManager.pageCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                showingGoToPage = true
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignTokens.spacingSM)
        .background(.ultraThinMaterial)
        .cornerRadius(DesignTokens.spacingSM)
        .padding(DesignTokens.spacingMD)
    }

    // MARK: - Toolbar

    private var toolbarContent: some View {
        Group {
            Button {
                showingFileImporter = true
            } label: {
                Label("Open", systemImage: "doc")
            }

            Divider()

            Button {
                pdfManager.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!pdfManager.hasDocument)

            Button {
                pdfManager.resetZoom()
            } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .disabled(!pdfManager.hasDocument)

            Button {
                pdfManager.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!pdfManager.hasDocument)

            Divider()

            Button {
                pdfManager.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!pdfManager.hasDocument || pdfManager.currentPageIndex == 0)

            Button {
                pdfManager.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!pdfManager.hasDocument || pdfManager.currentPageIndex >= pdfManager.pageCount - 1)
        }
    }

    // MARK: - Go To Page Dialog

    private var goToPageDialog: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            Text("Go to Page")
                .font(.headline)

            TextField("Page number", text: $goToPageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit {
                    goToPage()
                }

            HStack {
                Button("Cancel") {
                    showingGoToPage = false
                    goToPageInput = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    goToPage()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.spacingLG)
        .frame(width: 300)
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else {
            return
        }

        // File importer returns security-scoped URLs - need explicit permission
        // Also ensure main thread for @Observable state updates
        DispatchQueue.main.async { [pdfManager] in
            _ = pdfManager.loadDocument(from: url, isSecurityScoped: true)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "pdf" else {
                return
            }

            DispatchQueue.main.async {
                _ = pdfManager.loadDocument(from: url)
            }
        }

        return true
    }

    private func goToPage() {
        guard let pageNumber = Int(goToPageInput),
              pageNumber > 0,
              pageNumber <= pdfManager.pageCount else {
            return
        }

        pdfManager.goToPage(pageNumber - 1)
        showingGoToPage = false
        goToPageInput = ""
    }
}

#Preview {
    MainView()
}
