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
        .overlay(alignment: .topLeading) {
            TrafficLightsView()
                .padding(DesignTokens.floatingToolbarPadding)
        }
        .overlay(alignment: .topTrailing) {
            FloatingToolbar(pdfManager: pdfManager, showingFileImporter: $showingFileImporter)
                .padding(DesignTokens.floatingToolbarPadding)
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
            handleOpenURL(url)
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
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.spacingMD)
                .fill(DesignTokens.floatingToolbarBase.opacity(0.12))
                .allowsHitTesting(false)
        )
        .cornerRadius(DesignTokens.spacingMD)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.spacingMD)
                .strokeBorder(.white.opacity(0.22))
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .padding(DesignTokens.spacingMD)
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
        .frame(width: DesignTokens.dialogWidth)
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

    private func handleOpenURL(_ url: URL) {
        DispatchQueue.main.async { [pdfManager] in
            _ = pdfManager.loadDocument(from: url, isSecurityScoped: true)
        }
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
