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

/// Collects every open row's frame (in the list's coordinate space) so the drag
/// resolver can hit-test the cursor into a drop target.
private struct TabRowFrameKey: PreferenceKey {
    static var defaultValue: [TabRowFrame] = []
    static func reduce(value: inout [TabRowFrame], nextValue: () -> [TabRowFrame]) {
        value += nextValue()
    }
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
    /// Commit a press-and-hold reorder: move `tabID` out of `from` into `to` at
    /// `toIndex`. `from === to` is an in-window reorder; different managers are a
    /// cross-window move. The controller applies it and refreshes the list.
    let onReorder: (_ tabID: UUID, _ from: TabManager, _ to: TabManager, _ toIndex: Int) -> Void

    @State private var query = ""
    @State private var selection: RowID?
    /// Gate for the auto-scroll: true for keyboard nav / filtering (keep the
    /// cursor visible), false for hover — so moving the mouse never yanks the
    /// list around under the pointer.
    @State private var scrollToSelection = true
    /// In-flight press-and-hold reorder drag (nil when not dragging).
    @State private var reorder: TabReorderDrag?
    /// Live open-row frames in `listSpace`, collected via a preference — the
    /// drop-target resolver reads these.
    @State private var rowFrames: [TabRowFrame] = []

    /// Named coordinate space the row frames and the drag location share.
    private static let listSpace = "tabSwitcherList"

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
        .onAppear { selection = defaultSelection }
        .onChange(of: query) { _, _ in
            scrollToSelection = true
            selection = defaultSelection
        }
    }

    /// Groups that still have tabs. A cross-window move of the last tab can leave
    /// a transiently-empty source group in the snapshot (the window closes
    /// asynchronously); excluding it keeps headers/height/multi-window logic
    /// correct until the next snapshot.
    private var openGroups: [WindowTabGroup] { groups.filter { !$0.tabs.isEmpty } }

    /// The list's pinned height: content sized from the unfiltered set (so the
    /// panel doesn't resize while typing), clamped to the controller's budget.
    /// Derived from the same metrics the rows render with — no estimate drift.
    private var listHeight: CGFloat {
        let openCount = openGroups.reduce(0) { $0 + $1.tabs.count }
        let closedCount = closed.count
        let sectionCount = (openCount > 0 ? 1 : 0) + (closedCount > 0 ? 1 : 0)
        let windowHeaderCount = openGroups.count > 1 ? openGroups.count : 0
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
            .coordinateSpace(name: Self.listSpace)
            .onPreferenceChange(TabRowFrameKey.self) { rowFrames = $0 }
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
                if openGroups.count > 1 {
                    windowHeader(for: entry.group)
                }
                let groupID = entry.group.id
                ForEach(entry.tabs) { tab in
                    let realIndex = entry.group.tabs.firstIndex { $0.id == tab.id } ?? 0
                    if isDropSlot(groupID, realIndex) { dropIndicator }
                    openTabRow(entry: entry, tab: tab, realIndex: realIndex)
                }
                if isDropSlot(groupID, entry.group.tabs.count) { dropIndicator }
            }
        }
    }

    // MARK: - Reorder (press-and-hold)

    @ViewBuilder
    private func openTabRow(entry: (group: WindowTabGroup, tabs: [TabModel]), tab: TabModel, realIndex: Int) -> some View {
        let groupID = entry.group.id
        let isLifted = reorder?.tabID == tab.id
        row(
            id: .open(tab.id),
            icon: Self.contentIcon(for: entry.group.tabManager.contentKind(for: tab.id)),
            title: tab.displayTitle,
            subtitle: Self.prettyPath(tab.documentURL),
            isDirty: entry.group.dirtyTabIDs.contains(tab.id),
            isActiveInWindow: tab.id == entry.group.activeTabID,
            action: { onJump(tab.id, entry.group.tabManager) }
        )
        .background(frameReporter(groupID: groupID, tabID: tab.id, index: realIndex))
        .opacity(isLifted ? 0.92 : 1)
        .scaleEffect(isLifted ? 1.02 : 1)
        .offset(y: isLifted ? (reorder?.translationY ?? 0) : 0)
        .shadow(color: .black.opacity(isLifted ? 0.22 : 0), radius: isLifted ? 8 : 0, y: isLifted ? 4 : 0)
        .zIndex(isLifted ? 1 : 0)
        // Reorder only when unfiltered — a filtered list is a subset and its
        // indices don't map to the real order. `.subviews` disables THIS gesture
        // while leaving the row's inner tap (jump) working; `.none` would mask the
        // tap too.
        .gesture(reorderGesture(groupID: groupID, tabID: tab.id),
                 including: trimmedQuery.isEmpty ? .all : .subviews)
    }

    private var dropIndicator: some View {
        Capsule()
            .fill(DesignTokens.glassTextPrimary.opacity(0.55))
            .frame(height: 2)
            .padding(.horizontal, DesignTokens.spacingMD)
    }

    private func isDropSlot(_ groupID: ObjectIdentifier, _ index: Int) -> Bool {
        reorder?.target == TabDropTarget(groupID: groupID, index: index)
    }

    private func frameReporter(groupID: ObjectIdentifier, tabID: UUID, index: Int) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TabRowFrameKey.self,
                value: [TabRowFrame(groupID: groupID, tabID: tabID, index: index,
                                    frame: proxy.frame(in: .named(Self.listSpace)))]
            )
        }
    }

    private func reorderGesture(groupID: ObjectIdentifier, tabID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.listSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    // Press-and-hold completed → lift the row.
                    if reorder == nil {
                        reorder = TabReorderDrag(tabID: tabID, sourceGroupID: groupID)
                        scrollToSelection = false
                        selection = .open(tabID)
                    }
                case .second(true, let drag):
                    guard var current = reorder, let drag else { return }
                    current.translationY = drag.translation.height
                    current.target = TabSwitcherReorderGeometry.dropTarget(at: drag.location, frames: rowFrames)
                    reorder = current
                default:
                    break
                }
            }
            .onEnded { _ in commitReorder() }
    }

    private func commitReorder() {
        defer { withAnimation(.easeOut(duration: 0.15)) { reorder = nil } }
        guard let drag = reorder, let target = drag.target,
              let source = groups.first(where: { $0.id == drag.sourceGroupID }),
              let dest = groups.first(where: { $0.id == target.groupID }),
              source.tabs.contains(where: { $0.id == drag.tabID }) else { return }
        // commitTabReorder / cross-window moveTab both no-op a same-slot move, so
        // no explicit no-op guard is needed here.
        onReorder(drag.tabID, source.tabManager, dest.tabManager, target.index)
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
        openGroups.compactMap { group in
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

    /// The tab the user is on: the frontmost window's active tab.
    static func currentTabID(in groups: [WindowTabGroup]) -> UUID? {
        guard let group = groups.first(where: \.isFrontmost),
              let active = group.activeTabID,
              group.tabs.contains(where: { $0.id == active }) else { return nil }
        return active
    }

    /// Where the highlight starts: on the tab the user is on, so Return stays
    /// put and Up/Down step from it; on the top match once they type.
    private var defaultSelection: RowID? {
        if trimmedQuery.isEmpty, let current = Self.currentTabID(in: openGroups) {
            return .open(current)
        }
        return orderedRowIDs.first
    }

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

    /// The row icon that distinguishes content type in the tab search, keyed off
    /// the session's real discriminator (`TabSession.contentKind`) — never the URL
    /// extension, so untitled Markdown tabs get the right icon too. `nil` (tab
    /// vanished mid-render) falls back to the plain page.
    private static func contentIcon(for kind: ContentKind?) -> String {
        (kind ?? .pdf).tabIconSystemName
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
