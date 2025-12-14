//
//  SearchBar.swift
//  PageFlow
//
//  Floating search bar with result navigation
//

import SwiftUI

struct SearchBar: View {
    @Bindable var searchManager: SearchManager
    var pdfManager: PDFManager
    @FocusState private var isSearchFieldFocused: Bool
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchManager.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(width: 200)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    handleSearchSubmit()
                }
                .onChange(of: searchManager.searchQuery) { _, newValue in
                    if newValue.isEmpty {
                        searchManager.clearSearch()
                    } else {
                        performSearch()
                    }
                }

            if searchManager.hasResults {
                Text("\(searchManager.currentResultNumber) of \(searchManager.totalResults)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)

                Divider().frame(height: 16)

                Button {
                    searchManager.previousResult()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!searchManager.hasResults)

                Button {
                    searchManager.nextResult()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(!searchManager.hasResults)
            } else if !searchManager.searchQuery.isEmpty && !searchManager.hasResults {
                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 16)

            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
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
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
        .onAppear {
            isSearchFieldFocused = true
        }
    }

    private func handleSearchSubmit() {
        if searchManager.hasResults {
            searchManager.nextResult()
        } else {
            performSearch()
        }
    }

    private func performSearch() {
        guard let document = pdfManager.document else { return }
        searchManager.search(searchManager.searchQuery, in: document)
    }

    private func closeSearch() {
        searchManager.clearSearch()
        isVisible = false
    }
}
