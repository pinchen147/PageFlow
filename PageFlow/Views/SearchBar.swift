import SwiftUI

/// Shared Find controls, with source replacement for backends that support it.
struct SearchBar: View {
    let driver: any FindDriving
    @Binding var isVisible: Bool
    let focusRequest: Int

    private var replacementDriver: (any FindReplacing)? { driver as? any FindReplacing }

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
        .background { copyShortcut }
    }

    /// Reached before the Edit menu: its Copy is greyed for a field with nothing
    /// selected. Anywhere else, ⌘C goes on down the responder chain as usual.
    private var copyShortcut: some View {
        Button("Copy Match") {
            if let match = FindQueryField.matchToCopy(firstResponder: NSApp.keyWindow?.firstResponder) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(match, forType: .string)
            } else {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
        }
        .keyboardShortcut("c", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
                .font(.system(size: DesignTokens.searchFieldFontSize, weight: .medium))
                .foregroundStyle(.secondary)
            FindQueryField(driver: driver, isVisible: $isVisible, focusRequest: focusRequest)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: DesignTokens.searchBarWidth)
                .onChange(of: driver.query) { _, _ in driver.scheduleSearch() }

            if !driver.query.isEmpty {
                Text(driver.resultStatus)
                    .font(.system(size: DesignTokens.searchControlFontSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)
                Divider().frame(height: 16)
                navigationButton("Previous match", symbol: "chevron.up", action: driver.previous)
                navigationButton("Next match", symbol: "chevron.down", action: driver.next)
                if let listing = driver as? any FindResultsListing, driver.hasResults {
                    navigationButton("Show All Results", symbol: "list.bullet", action: listing.showResultsList)
                }
            }
            Divider().frame(height: 16)
            Button { isVisible = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: DesignTokens.searchControlFontSize, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .pageFlowClickCursor()
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Find")
            .help("Close Find")
        }
    }

    private func navigationButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.searchControlFontSize, weight: .medium))
                .frame(width: 20, height: 20)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .pageFlowClickCursor()
        .disabled(!driver.hasResults)
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
            .font(.system(size: DesignTokens.searchFieldFontSize))
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
/// content with the same slide-in animation and padding. `showingSearch` is the
/// tab's own (`TabUIState`), and only the active tab presents the bar — an inactive
/// tab can't grab focus.
struct FindOverlay: View {
    /// The one rule for who holds the keyboard when a tab is shown, in every
    /// type: Find if it is open (the bar focuses its field as it mounts), otherwise
    /// the document, which also takes it back as Find closes. A document claiming
    /// it with Find open would race the field, and what is typed for Find could
    /// land in a note.
    static func documentTakesKeyboard(isShown: Bool, findIsOpen: Bool) -> Bool {
        isShown && !findIsOpen
    }

    /// The width a status chip leaves free in the middle of the window beside
    /// a bar this wide; none while the bar isn't shown.
    static func chipReservation(barWidth: CGFloat) -> CGFloat {
        barWidth > 0 ? barWidth + DesignTokens.spacingSM * 2 : 0
    }

    let driver: any FindDriving
    let isActive: Bool
    @Binding var showingSearch: Bool
    let focusRequest: Int
    /// Told the bar's width as it changes, and 0 while it isn't shown, for
    /// chrome that has to stay clear of it.
    var onBarWidthChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isActive && showingSearch {
                SearchBar(
                    driver: driver,
                    isVisible: $showingSearch,
                    focusRequest: focusRequest
                )
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { onBarWidthChange($0) }
                .onDisappear { onBarWidthChange(0) }
                .padding(.bottom, DesignTokens.spacingXS)
                .pageFlowPanelTransition(edge: .bottom)
            }
        }
        // Fill the host and pin the bar to its bottom center, whatever the
        // host's own alignment (the Markdown tab stacks from the top).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: DesignTokens.searchBarAnimationDuration), value: showingSearch)
    }
}
