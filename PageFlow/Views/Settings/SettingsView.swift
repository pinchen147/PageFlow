//
//  SettingsView.swift
//  PageFlow
//
//  The Settings window: a sidebar of panes, with a search across all of them.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var selectedPane: SettingsPane = .general
    @State private var query = ""
    @State private var shortcutQuery = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: DesignTokens.settingsSidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: DesignTokens.settingsWindowWidth, height: DesignTokens.settingsWindowHeight)
        .containerBackground(for: .window) {
            Color.clear
                .pageFlowLiquidGlassSurface(.sidebar.with(cornerRadius: 0, strokeOpacity: 0))
                .background(SettingsWindowAccessor())
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.top, DesignTokens.spacingMD)
                .padding(.bottom, DesignTokens.spacingSM)

            if query.isEmpty {
                List(SettingsPane.allCases, selection: paneSelection) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                searchResults
            }
        }
    }

    /// The list clears its selection on an empty click; a pane stays open.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(get: { selectedPane }, set: { pane in
            if let pane { selectedPane = pane }
        })
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.spacingSM))
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = SettingsSearch.results(for: query)
        if results.isEmpty {
            Text("No settings match \u{201C}\(query)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(DesignTokens.spacingMD)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List(results) { result in
                Button {
                    show(result)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                            .lineLimit(2)
                        Text(result.pane.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func show(_ result: SettingsSearchResult) {
        selectedPane = result.pane
        if let shortcutQuery = result.shortcutQuery {
            self.shortcutQuery = shortcutQuery
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane {
        case .general: GeneralSettingsTab()
        case .notes: NotesSettingsTab()
        case .books: BooksSettingsTab()
        case .annotations: AnnotationsSettingsTab()
        case .shortcuts: ShortcutsSettingsTab(query: $shortcutQuery)
        }
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowAccessorView {
        SettingsWindowAccessorView()
    }

    func updateNSView(_ nsView: SettingsWindowAccessorView, context: Context) {
        nsView.configureWindowIfNeeded()
    }
}

final class SettingsWindowAccessorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        guard let closeButton = window.standardWindowButton(.closeButton),
              closeButton.keyEquivalent != "\u{1b}" else {
            return
        }

        closeButton.keyEquivalent = "\u{1b}" // Escape
        closeButton.keyEquivalentModifierMask = []
    }
}
