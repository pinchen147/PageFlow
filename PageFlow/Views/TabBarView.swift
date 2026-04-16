//
//  TabBarView.swift
//  PageFlow
//
//  Chrome-style tabs with AppKit-level gesture handling for immediate response.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.pageflow", category: "TabBarView")

struct TabBarView: View {
    @Bindable var tabManager: TabManager

    // Drag state
    @State private var draggingTabID: UUID? {
        didSet {
            logger.debug("draggingTabID changed: \(oldValue?.uuidString ?? "nil") -> \(draggingTabID?.uuidString ?? "nil")")
        }
    }
    @State private var dragOffset: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var originalTabFrames: [UUID: CGRect] = [:]  // Snapshot at drag start
    @State private var hoveredTabID: UUID?
    @State private var newTabFrame: CGRect?

    var body: some View {
        ZStack {
            // Tab content
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.tabSpacing) {
                    ForEach(tabManager.tabs, id: \.id) { tab in
                        tabView(for: tab)
                    }

                    newTabButton
                }
                .padding(.horizontal, DesignTokens.spacingXS)
            }
            .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                // Defer to avoid "Modifying state during view update"
                DispatchQueue.main.async {
                    tabFrames = frames
                }
            }
            .onPreferenceChange(NewTabButtonFramePreferenceKey.self) { frame in
                DispatchQueue.main.async {
                    newTabFrame = frame
                }
            }

            // AppKit gesture layer - handles mouse events directly
            // Note: Gesture callbacks come from AppKit mouse events (not during SwiftUI view updates)
            // so they can safely modify state synchronously. Only preference changes need async.
            TabBarGestureView(callbacks: TabBarGestureCallbacks(
                onDragStarted: { x in
                    // MUST be sync so draggingTabID is set before onDragChanged fires
                    logger.debug("Drag start at x=\(x)")
                    if let tabID = findTab(at: x) {
                        let isClose = isCloseHit(for: tabID, x: x)
                        logger.debug("Found tab: \(tabID), isCloseHit=\(isClose)")
                        if !isClose {
                            originalTabFrames = tabFrames
                            draggingTabID = tabID
                            logger.debug("Started dragging tab, snapshotted \(originalTabFrames.count) frames")
                        } else {
                            logger.debug("Blocked by close button")
                        }
                    } else {
                        logger.debug("No tab found at this position")
                    }
                },
                onDragChanged: { _, translation in
                    // Sync for smooth visual feedback
                    if draggingTabID != nil {
                        dragOffset = translation
                    }
                },
                onDragEnded: { _, translation in
                    // Sync to ensure state is consistent
                    if let tabID = draggingTabID {
                        commitDrag(for: tabID, translation: translation)
                    }
                    resetDragState()
                },
                onClick: { x in
                    DispatchQueue.main.async {
                        if isNewTabHit(x) {
                            tabManager.createNewTab()
                            return
                        }

                        if let tabID = findTab(at: x) {
                            if isCloseHit(for: tabID, x: x) {
                                tabManager.closeTab(tabID)
                            } else {
                                tabManager.selectTab(tabID)
                            }
                        }
                    }
                },
                onHoverChanged: { x in
                    DispatchQueue.main.async {
                        hoveredTabID = x.flatMap { findTab(at: $0) }
                    }
                }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(true)
        }
        .coordinateSpace(name: "tabBar")
    }

    // MARK: - Tab View

    @ViewBuilder
    private func tabView(for tab: TabModel) -> some View {
        let isDirty = tabManager.isTabDirty(tab.id)
        let isDragging = draggingTabID == tab.id


        TabItemView(
            tab: tab,
            isActive: tab.id == tabManager.activeTabID,
            isDirty: isDirty,
            isHovering: hoveredTabID == tab.id
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [tab.id: geo.frame(in: .named("tabBar"))]
                )
            }
        )
        .offset(x: isDragging ? dragOffset : shiftOffset(for: tab.id))
        .zIndex(isDragging ? 100 : 0)
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .shadow(color: isDragging ? .black.opacity(0.25) : .clear, radius: 10, y: 5)
        .allowsHitTesting(false)  // Gesture overlay handles all input
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
    }

    // MARK: - New Tab Button

    private var newTabButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 24, height: 24)
            .background(.ultraThinMaterial)
            .background(DesignTokens.floatingToolbarBase.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
                    .strokeBorder(.white.opacity(0.22))
            )
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: NewTabButtonFramePreferenceKey.self,
                        value: geo.frame(in: .named("tabBar"))
                    )
                }
            )
    }

    // MARK: - Hit Testing

    private func findTab(at x: CGFloat) -> UUID? {
        // Sort by minX to ensure consistent left-to-right hit testing
        let sortedFrames = tabFrames.sorted { $0.value.minX < $1.value.minX }

        for (_, entry) in sortedFrames.enumerated() {
            let (tabID, frame) = entry
            if x >= frame.minX && x <= frame.maxX {
                return tabID
            }
        }
        return nil
    }

    private func isCloseHit(for tabID: UUID, x: CGFloat) -> Bool {
        guard let frame = tabFrames[tabID] else { return false }

        let closeWidth = DesignTokens.tabCloseButtonSize
        let paddingX = DesignTokens.spacingSM
        let closeMinX = frame.maxX - paddingX - closeWidth
        let closeMaxX = frame.maxX - paddingX
        let isCloseVisible = hoveredTabID == tabID || tabManager.activeTabID == tabID

        return isCloseVisible && x >= closeMinX && x <= closeMaxX
    }

    private func isNewTabHit(_ x: CGFloat) -> Bool {
        guard let frame = newTabFrame else { return false }
        return x >= frame.minX && x <= frame.maxX
    }

    // MARK: - Drag Helpers

    private func shiftOffset(for tabID: UUID) -> CGFloat {
        guard let draggingID = draggingTabID,
              draggingID != tabID,
              let originalDraggingFrame = originalTabFrames[draggingID],
              let originalThisFrame = originalTabFrames[tabID] else {
            return 0
        }

        // Use ORIGINAL frame positions (snapshotted at drag start) + current dragOffset
        // This avoids circular dependency from shifting frames
        let draggingCenter = originalDraggingFrame.midX + dragOffset
        let thisCenter = originalThisFrame.midX

        guard let draggingIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingID }),
              let thisIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
            return 0
        }

        let tabWidth = originalThisFrame.width + DesignTokens.tabSpacing
        let threshold = tabWidth * 0.3

        if draggingIndex < thisIndex && draggingCenter > thisCenter - threshold {
            return -tabWidth
        } else if draggingIndex > thisIndex && draggingCenter < thisCenter + threshold {
            return tabWidth
        }

        return 0
    }

    private func commitDrag(for tabID: UUID, translation: CGFloat) {
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }),
              let originalSourceFrame = originalTabFrames[tabID] else {
            logger.debug("commitDrag: missing sourceIndex or originalSourceFrame")
            return
        }

        // Use ORIGINAL frame position + translation for accurate target calculation
        let draggedCenter = originalSourceFrame.midX + translation
        logger.debug("commitDrag: sourceIndex=\(sourceIndex), originalMidX=\(originalSourceFrame.midX), translation=\(translation), draggedCenter=\(draggedCenter)")

        var targetIndex = sourceIndex
        for (index, tab) in tabManager.tabs.enumerated() {
            guard let originalFrame = originalTabFrames[tab.id], tab.id != tabID else { continue }

            // Use same threshold as shiftOffset for consistent visual-to-commit behavior
            // When a tab visually shifts to make room, releasing should place the tab there
            let tabWidth = originalFrame.width + DesignTokens.tabSpacing
            let threshold = tabWidth * 0.3
            let tabName = tab.title
            logger.debug("   Comparing with tab[\(index)] '\(tabName)': midX=\(originalFrame.midX), threshold=\(threshold)")

            if sourceIndex < index && draggedCenter > originalFrame.midX - threshold {
                // Dragging RIGHT: take the rightmost tab we've passed (largest index)
                // Matches shiftOffset condition: draggingCenter > thisCenter - threshold
                logger.debug("Moving RIGHT: draggedCenter(\(draggedCenter)) > midX-threshold(\(originalFrame.midX - threshold))")
                targetIndex = index
            } else if sourceIndex > index && draggedCenter < originalFrame.midX + threshold {
                // Dragging LEFT: take the leftmost tab we've passed (smallest index)
                // Matches shiftOffset condition: draggingCenter < thisCenter + threshold
                if index < targetIndex {
                    logger.debug("Moving LEFT: draggedCenter(\(draggedCenter)) < midX+threshold(\(originalFrame.midX + threshold))")
                    targetIndex = index
                }
            }
        }

        logger.debug("commitDrag result: sourceIndex=\(sourceIndex) -> targetIndex=\(targetIndex)")

        if targetIndex != sourceIndex {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                tabManager.moveTab(fromIndex: sourceIndex, toIndex: targetIndex)
            }
        }
    }

    private func resetDragState() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            draggingTabID = nil
            dragOffset = 0
        }
        // Clear snapshot to free memory (not animated)
        originalTabFrames = [:]
    }
}

// MARK: - Preference Key

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct NewTabButtonFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
