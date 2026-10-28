import SwiftUI

/// Shared Find controls, with source replacement for backends that support it.
struct SearchBar: View {
    let driver: any FindDriving
    @Binding var isVisible: Bool
    let focusRequest: Int
    @FocusState private var isSearchFieldFocused: Bool

    private var replacementDriver: (any FindReplacing)? { driver as? any FindReplacing }
    private var queryBinding: Binding<String> {
        Binding(get: { driver.query }, set: { driver.setQuery($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacingSM) {
            queryRow
            if let replacementDriver, replacementDriver.showsReplacement {
                replacementRow(replacementDriver)
            }
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .pageFlowLiquidGlassPanel(.glassPanel)
        .task(id: focusRequest) {
            await Task.yield()
            if !Task.isCancelled && isVisible { isSearchFieldFocused = true }
        }
    }

    private var queryRow: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            if let replacementDriver {
                Button {
                    replacementDriver.setShowingReplacement(!replacementDriver.showsReplacement)
                } label: {
                    Image(systemName: replacementDriver.showsReplacement ? "chevron.down" : "chevron.right")
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .accessibilityLabel(replacementDriver.showsReplacement ? "Hide replacement" : "Show replacement")
                .help("Show or hide replacement controls")
            }
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .frame(width: DesignTokens.searchBarWidth)
                .focused($isSearchFieldFocused)
                .accessibilityLabel("Find text")
                .onSubmit { driver.next() }
                .onChange(of: driver.query) { _, _ in driver.scheduleSearch() }

            if !driver.query.isEmpty {
                Text(driver.hasResults ? "\(driver.currentMatch) of \(driver.resultCount)" : "No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)
                Divider().frame(height: 16)
                navigationButton("Previous match", symbol: "chevron.up", action: driver.previous)
                navigationButton("Next match", symbol: "chevron.down", action: driver.next)
            }
            Divider().frame(height: 16)
            Button { isVisible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Find")
        }
    }

    private func navigationButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .accessibilityLabel(label)
        .help(label)
    }

    private func replacementRow(_ replacement: any FindReplacing) -> some View {
        HStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)
                .frame(width: 40)
            TextField("Replace with", text: Binding(
                get: { replacement.replacementText }, set: { replacement.setReplacement($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .frame(width: DesignTokens.searchBarWidth)
            .accessibilityLabel("Replacement text")
            .onSubmit { replacement.replaceCurrent() }
            Button("Replace") { replacement.replaceCurrent() }
                .pageFlowClickCursor()
                .disabled(driver.query.isEmpty)
                .help("Replace the current match and find the next")
            Button("Replace All") { replacement.replaceAll() }
                .pageFlowClickCursor()
                .disabled(driver.query.isEmpty)
                .help("Replace every current match in this document")
        }
    }
}

// MARK: - Shared Find overlay

/// The bottom-anchored Find bar overlay shared by every content view (PDF `PDFTabView`
/// and `MarkdownTabView`): the active tab presents the shared `SearchBar` over its
/// content with the same slide-in animation and padding. `showingSearch` is
/// window-level state shared by every warm tab, so only the active tab presents the
/// bar — an inactive tab can't grab focus.
struct FindOverlay: View {
    let driver: any FindDriving
    let isActive: Bool
    @Binding var showingSearch: Bool
    let focusRequest: Int

    var body: some View {
        ZStack(alignment: .bottom) {
            if isActive && showingSearch {
                SearchBar(
                    driver: driver,
                    isVisible: $showingSearch,
                    focusRequest: focusRequest
                )
                .padding(.bottom, DesignTokens.spacingXS)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Fill the host and pin the bar to its bottom center, whatever the
        // host's own alignment (the Markdown tab stacks from the top).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: showingSearch)
    }
}
