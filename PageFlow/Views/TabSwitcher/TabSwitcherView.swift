//
//  TabSwitcherView.swift
//  PageFlow
//
//  The Tab Switcher dropdown content: a search field over a sectioned list of
//  every open tab (grouped per window, frontmost first) plus recently closed
//  documents. Full keyboard model — type to filter, Up/Down to move, Return to
//  open, Escape to dismiss — with the search field keeping focus throughout.
//

import AppKit
import SwiftUI

enum TabSwitcherMetrics {
    static let panelWidth: CGFloat = 360
    /// Transparent margin around the glass, so the SwiftUI drop shadow isn't
    /// clipped by the borderless panel. The controller offsets anchoring by this.
    static let shadowPadding: CGFloat = 24
    /// Gap between the chevron and the dropdown's glass.
    static let anchorGap: CGFloat = 4
    /// Search-header height — kept in sync with `searchHeader`'s frame.
    static let headerHeight: CGFloat = 48
    /// Row content height and inter-element spacing. The row renders at exactly
    /// `rowHeight` and the list is measured from these same constants, so layout
    /// and sizing can never drift apart (no dead glass strip).
    static let rowHeight: CGFloat = 50
    static let rowSpacing: CGFloat = 2
    static let sectionHeaderHeight: CGFloat = 24
    static let windowHeaderHeight: CGFloat = 18
    static let listVerticalPadding: CGFloat = 8
    static let minListHeight: CGFloat = 120
}

struct TabSwitcherView: View {
    let groups: [WindowTabGroup]
    let closed: [ClosedTabStore.Record]
    /// The tallest the list may be (the controller's on-screen budget). The view
    /// sizes itself to its content, clamped to this.
    let maxListHeight: CGFloat
    let onJump: (UUID, TabManager) -> Void
    let onReopen: (ClosedTabStore.Record) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selection: RowID?
    /// Gate for the auto-scroll: true for keyboard nav / filtering (keep the
    /// cursor visible), false for hover — so moving the mouse never yanks the
    /// list around under the pointer.
    @State private var scrollToSelection = true

    private enum RowID: Hashable {
        case open(UUID)
        case closed(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().opacity(0.4)
            listBody
        }
        .frame(width: TabSwitcherMetrics.panelWidth)
        .pageFlowLiquidGlassPanel(.tabSwitcher)
        .padding(TabSwitcherMetrics.shadowPadding)
        .onAppear { selection = orderedRowIDs.first }
        .onChange(of: query) { _, _ in
            scrollToSelection = true
            selection = orderedRowIDs.first
        }
    }

    /// The list's pinned height: content sized from the unfiltered set (so the
    /// panel doesn't resize while typing), clamped to the controller's budget.
    /// Derived from the same metrics the rows render with — no estimate drift.
    private var listHeight: CGFloat {
        let openCount = groups.reduce(0) { $0 + $1.tabs.count }
        let closedCount = closed.count
        let sectionCount = (openCount > 0 ? 1 : 0) + (closedCount > 0 ? 1 : 0)
        let windowHeaderCount = groups.count > 1 ? groups.count : 0
        let rowCount = openCount + closedCount
        let elementCount = sectionCount + windowHeaderCount + rowCount
        let content = CGFloat(rowCount) * TabSwitcherMetrics.rowHeight
            + CGFloat(sectionCount) * TabSwitcherMetrics.sectionHeaderHeight
            + CGFloat(windowHeaderCount) * TabSwitcherMetrics.windowHeaderHeight
            + CGFloat(max(0, elementCount - 1)) * TabSwitcherMetrics.rowSpacing
            + TabSwitcherMetrics.listVerticalPadding
        return min(content, maxListHeight)
    }

    // MARK: - Header

    private var searchHeader: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.glassTextSecondary)
                .pageFlowGlassTextHalo()

            TabSwitcherSearchField(
                text: $query,
                onMoveUp: { moveSelection(by: -1) },
                onMoveDown: { moveSelection(by: 1) },
                onSubmit: activateSelection,
                onCancel: onClose
            )
            .frame(height: 22)
        }
        .padding(.horizontal, DesignTokens.spacingMD)
        .frame(height: 48)
    }

    // MARK: - List

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if orderedRowIDs.isEmpty {
                        emptyState
                    } else {
                        openTabsSection
                        recentlyClosedSection
                    }
                }
                .padding(.horizontal, DesignTokens.spacingSM)
                .padding(.vertical, DesignTokens.spacingXS)
            }
            .frame(height: listHeight)
            .onChange(of: selection) { _, newValue in
                guard let newValue, scrollToSelection else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var openTabsSection: some View {
        let entries = filteredGroups
        if !entries.isEmpty {
            sectionHeader("Open Tabs")
            ForEach(entries, id: \.group.id) { entry in
                if groups.count > 1 {
                    windowHeader(for: entry.group)
                }
                ForEach(entry.tabs) { tab in
                    row(
                        id: .open(tab.id),
                        icon: "doc.text",
                        title: tab.displayTitle,
                        subtitle: Self.prettyPath(tab.documentURL),
                        isDirty: entry.group.dirtyTabIDs.contains(tab.id),
                        isActiveInWindow: tab.id == entry.group.activeTabID,
                        action: { onJump(tab.id, entry.group.tabManager) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recentlyClosedSection: some View {
        let records = filteredClosed
        if !records.isEmpty {
            sectionHeader("Recently Closed")
            ForEach(records) { record in
                row(
                    id: .closed(record.id),
                    icon: "clock.arrow.circlepath",
                    title: record.title,
                    subtitle: Self.prettyPath(record.url),
                    isDirty: false,
                    isActiveInWindow: false,
                    action: { onReopen(record) }
                )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DesignTokens.glassTextSecondary)
            .pageFlowGlassTextHalo()
            .padding(.horizontal, DesignTokens.spacingSM)
            .padding(.top, DesignTokens.spacingSM)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func windowHeader(for group: WindowTabGroup) -> some View {
        Text(group.isFrontmost ? "This Window" : Self.windowTitle(group))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DesignTokens.glassTextTertiary)
            .pageFlowGlassTextHalo()
            .padding(.horizontal, DesignTokens.spacingSM)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(
        id: RowID,
        icon: String,
        title: String,
        subtitle: String?,
        isDirty: Bool,
        isActiveInWindow: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = selection == id
        HStack(spacing: DesignTokens.spacingSM) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.glassTextSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: isActiveInWindow ? .semibold : .regular))
                    .foregroundStyle(DesignTokens.glassTextPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.glassTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if isDirty {
                Circle()
                    .fill(DesignTokens.glassTextSecondary)
                    .frame(width: 6, height: 6)
            }
        }
        .pageFlowGlassTextHalo()
        .padding(.horizontal, DesignTokens.spacingSM)
        .frame(height: TabSwitcherMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.35 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            // Hover highlights the row (so Return/click target it) but must NOT
            // scroll the list — recentering the row under the pointer is the
            // "auto-scroll when hovering top/bottom" bug. Only keyboard nav and
            // filtering arm scrollToSelection.
            if hovering {
                scrollToSelection = false
                selection = id
            }
        }
        .onTapGesture(perform: action)
        .id(id)
    }

    private var emptyState: some View {
        Text("No matching tabs")
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.glassTextSecondary)
            .pageFlowGlassTextHalo()
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.spacingMD)
    }

    // MARK: - Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matches(_ candidates: [String?]) -> Bool {
        guard !trimmedQuery.isEmpty else { return true }
        let needle = trimmedQuery.lowercased()
        return candidates.lazy.compactMap { $0 }.contains { $0.lowercased().contains(needle) }
    }

    private var filteredGroups: [(group: WindowTabGroup, tabs: [TabModel])] {
        groups.compactMap { group in
            let tabs = group.tabs.filter { matches([$0.displayTitle, $0.documentURL?.path]) }
            return tabs.isEmpty ? nil : (group, tabs)
        }
    }

    private var filteredClosed: [ClosedTabStore.Record] {
        closed.filter { matches([$0.title, $0.url.path]) }
    }

    /// The visible rows in display order — the keyboard-navigation sequence.
    private var orderedRowIDs: [RowID] {
        var ids = filteredGroups.flatMap { $0.tabs.map { RowID.open($0.id) } }
        ids.append(contentsOf: filteredClosed.map { RowID.closed($0.id) })
        return ids
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) {
        scrollToSelection = true
        let ids = orderedRowIDs
        guard !ids.isEmpty else { selection = nil; return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = delta > 0 ? ids.first : ids.last
            return
        }
        let next = (index + delta + ids.count) % ids.count
        selection = ids[next]
    }

    private func activateSelection() {
        guard let selection else { return }
        switch selection {
        case .open(let tabID):
            if let entry = filteredGroups.first(where: { $0.tabs.contains { $0.id == tabID } }) {
                onJump(tabID, entry.group.tabManager)
            }
        case .closed(let recordID):
            if let record = filteredClosed.first(where: { $0.id == recordID }) {
                onReopen(record)
            }
        }
    }

    // MARK: - Display helpers

    private static func windowTitle(_ group: WindowTabGroup) -> String {
        if let activeID = group.activeTabID,
           let tab = group.tabs.first(where: { $0.id == activeID }) {
            return tab.displayTitle
        }
        return "Window"
    }

    private static func prettyPath(_ url: URL?) -> String? {
        guard let url else { return nil }
        return (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Search field

/// A borderless `NSTextField` that auto-focuses when the panel appears and
/// forwards arrow / Return / Escape to SwiftUI while keeping text focus. A plain
/// SwiftUI `TextField` cannot do this on macOS 15: `.searchable` lacks
/// programmatic focus, and a focused `List` would steal the arrow keys.
private struct TabSwitcherSearchField: NSViewRepresentable {
    @Binding var text: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        // The dropdown glass is always light (white tint), so force dark text +
        // a readable placeholder rather than the system label color, which is
        // light in dark mode and would vanish on the glass.
        field.textColor = NSColor(DesignTokens.glassTextPrimary)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search Tabs",
            attributes: [
                .foregroundColor: NSColor(DesignTokens.glassTextTertiary),
                .font: NSFont.systemFont(ofSize: 14)
            ]
        )
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TabSwitcherSearchField
        init(_ parent: TabSwitcherSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

private final class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Defer one turn so the panel is key before we grab first responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
