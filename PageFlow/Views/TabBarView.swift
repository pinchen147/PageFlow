//
//  TabBarView.swift
//  PageFlow
//
//  Pure SwiftUI renderer for one window's tab strip. All drag state lives
//  in `TabDragController.shared`; this view is a projection of it. Mouse
//  events flow through `TabBarMouseView` (an AppKit overlay) so we never
//  re-enter SwiftUI's body during a drag.
//
//  With compact tabs on (Settings, the default) the strip is the Deck: the
//  focused tab at full width, the others tucked under it as slivers
//  (`TabDeckLayout`). The Deck reports each card's SHOWN part
//  as its frame — never overlapping, in tab order — so `TabBarMouseView`'s
//  hit-testing, hover, close and drop-index code serves both layouts.
//

import SwiftUI

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    /// Compact tabs (Settings): show the Deck.
    let compactTabs: Bool
    let isInteractive: Bool
    /// Trailing width covered by the toolbar while it floats open over the
    /// strip. The AppKit overlays give it up so clicks reach the toolbar.
    let occludedTrailingWidth: CGFloat

    @State private var dragController = TabDragController.shared
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var newTabButtonFrame: CGRect = .zero
    @State private var hoveredTabID: UUID?
    /// Tabs run past the strip's trailing edge (under the toolbar).
    @State private var overflowsTrailingEdge = false
    /// The full-width strip's content width, as scrolled.
    @State private var fullContentWidth: CGFloat = 0
    /// Showing the Deck: `compactTabs`, latched while a drag is in flight so
    /// the strip under the cursor never swaps layouts mid-drag.
    @State private var isCompact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the fade where overflowing tabs meet the toolbar.
    private static let trailingFadeWidth: CGFloat = 28

    init(tabManager: TabManager, compactTabs: Bool, isInteractive: Bool = true, occludedTrailingWidth: CGFloat = 0) {
        self.tabManager = tabManager
        self.compactTabs = compactTabs
        self.isInteractive = isInteractive
        self.occludedTrailingWidth = occludedTrailingWidth
        _isCompact = State(initialValue: compactTabs)
    }

    var body: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.tabSpacing) {
                    if isCompact {
                        deck
                    } else {
                        ForEach(tabManager.tabs, id: \.id) { tab in
                            tabView(for: tab)
                        }
                    }
                    newTabButton
                }
                .padding(.horizontal, DesignTokens.spacingXS)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.width - geometry.visibleRect.maxX > 1
            } action: { _, overflows in
                overflowsTrailingEdge = overflows
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.width
            } action: { _, width in
                // The Deck's width animates with every slid-out sliver and
                // `neededWidth` doesn't read it; don't re-render per frame.
                guard !isCompact else { return }
                fullContentWidth = width
            }
            .mask(trailingFadeMask)
            .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                guard isInteractive, tabFrames != frames else { return }
                tabFrames = frames
            }
            .onPreferenceChange(NewTabButtonFramePreferenceKey.self) { frame in
                let newFrame = frame ?? .zero
                guard isInteractive, newTabButtonFrame != newFrame else { return }
                newTabButtonFrame = newFrame
            }

            // AppKit hit-testing reaches these NSViews regardless of SwiftUI's
            // `allowsHitTesting`, so they unmount when the bar is hidden, and
            // give up the width a floating toolbar covers.
            if isInteractive {
                Group {
                    // Empty bar space falls through to here so dragging the
                    // background drags the window — Chrome / Safari behavior.
                    WindowDragArea()

                    TabBarMouseView(
                        tabManager: tabManager,
                        tabFrames: tabFrames,
                        newTabButtonFrame: newTabButtonFrame,
                        hoveredTabID: hoveredTabID,
                        activeTabID: tabManager.activeTabID,
                        onHover: { hoveredTabID = $0 },
                        onClick: handleClick
                    )
                    // Guarantee the AppKit overlay fills the bar — NSViews have
                    // no intrinsic size, and we need it to cover the full ZStack.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.trailing, occludedTrailingWidth)
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .preference(key: TabStripWidthPreferenceKey.self, value: neededWidth)
        .onChange(of: compactTabs) { _, compact in
            setCompact(compact)
        }
        .onChange(of: dragController.isActive) { _, _ in
            setCompact(compactTabs)
        }
        .onChange(of: isInteractive) { _, interactive in
            guard !interactive else { return }
            tabFrames = [:]
            newTabButtonFrame = .zero
            hoveredTabID = nil
        }
    }

    /// Tabs cut off at the trailing edge, or under the toolbar while it floats
    /// open over the strip, fade out instead of ending in a hard edge against
    /// it; a strip that fits is left untouched.
    private var trailingFadeMask: some View {
        let fades = overflowsTrailingEdge || occludedTrailingWidth > 0
        return HStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, fades ? .clear : .black],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: Self.trailingFadeWidth)
            // Under a toolbar floating open over the strip, nothing shows:
            // the tabs fade out ahead of its leading edge instead of showing
            // through its glass.
            Color.clear
                .frame(width: occludedTrailingWidth)
        }
        .animation(.easeOut(duration: DesignTokens.animationFast), value: fades)
        .animation(DesignTokens.toolbarFoldAnimation(reduceMotion: reduceMotion), value: occludedTrailingWidth)
    }

    // MARK: - Layout Mode

    private func setCompact(_ compact: Bool) {
        guard !dragController.isActive, compact != isCompact else { return }
        withAnimation(DesignTokens.chromeAnimation(reduceMotion: reduceMotion)) {
            isCompact = compact
        }
    }

    /// The width the strip needs to show all its tabs: the Deck at rest (a
    /// slid-out sliver is transient and must not refold the toolbar), or the
    /// full-width tabs as laid out.
    private var neededWidth: CGFloat {
        guard isCompact else { return fullContentWidth }
        let deck = TabDeckLayout(count: tabManager.tabs.count, focusedIndex: 0).width
        return deck + DesignTokens.tabSpacing + DesignTokens.chromeIconSize + 2 * DesignTokens.spacingXS
    }

    // MARK: - Tab View

    @ViewBuilder
    private func tabView(for tab: TabModel) -> some View {
        let isDragging = draggingLocalTabID == tab.id

        TabItemView(
            tab: tab,
            contentKind: tabManager.contentKind(for: tab.id),
            isActive: tab.id == tabManager.activeTabID,
            isDirty: tabManager.isTabDirty(tab.id),
            isHovering: hoveredTabID == tab.id,
            style: dragController.isActive ? .card : .glass
        )
        .background(tabFrameReporter(for: tab.id))
        .offset(x: shiftOffset(for: tab.id))
        // The source tab stays in its layout slot at opacity 0 while the
        // floating preview owns the visible drag affordance.
        .opacity(isDragging ? 0 : 1)
        .allowsHitTesting(false)
        // Animate gap shifts only when the insertion index actually changes.
        // The controller dedupes per-pixel updates, so this fires at most
        // once per tab boundary crossed — not 60 times per second.
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: localInsertionIndex)
    }

    // MARK: - Deck

    private var deck: some View {
        let ids = tabManager.tabs.map(\.id)
        let preview = deckPreview(of: ids)
        let shown = deckLayout(order: preview.order, gap: preview.gap)
        let animation = DesignTokens.chromeAnimation(reduceMotion: reduceMotion)

        return ZStack(alignment: .leading) {
            ForEach(tabManager.tabs, id: \.id) { tab in
                if let index = preview.order.firstIndex(of: tab.id) {
                    deckCard(for: tab, card: shown.cards[index])
                }
            }
        }
        .frame(width: shown.width, height: DesignTokens.tabHeight, alignment: .leading)
        // Hit frames come from the resting order, not the drag preview: the
        // controller's insertion index counts slots in the current order.
        .background(deckFrameReporter(ids: ids, layout: deckLayout(order: ids, gap: nil)))
        .animation(animation, value: shown)
        .animation(animation, value: preview.order)
    }

    private func deckLayout(order: [UUID], gap: TabDeckLayout.Gap?) -> TabDeckLayout {
        let activeTabID = tabManager.activeTabID
        return TabDeckLayout(
            count: order.count,
            focusedIndex: order.firstIndex { $0 == activeTabID } ?? 0,
            // The held tab keeps a full-width slot so the landing spot reads
            // even when it isn't the focused tab (a tab merged in mid-drag).
            expandedIndex: (draggingLocalTabID ?? hoveredTabID).flatMap { order.firstIndex(of: $0) },
            gap: gap
        )
    }

    /// What a drag over the Deck previews: a tab dragged within this strip
    /// moves to its landing slot; a tab from another window opens a gap.
    private func deckPreview(of ids: [UUID]) -> (order: [UUID], gap: TabDeckLayout.Gap?) {
        guard let drag = dragController.activeDrag, let insertionIndex = localInsertionIndex else {
            return (ids, nil)
        }
        if drag.sourceManagerID == ObjectIdentifier(tabManager) {
            return (TabDeckLayout.previewOrder(ids, moving: drag.tabID, toInsertionIndex: insertionIndex), nil)
        }
        return (ids, TabDeckLayout.Gap(index: insertionIndex, width: drag.draggedWidth + DesignTokens.tabSpacing))
    }

    @ViewBuilder
    private func deckCard(for tab: TabModel, card: TabDeckLayout.Card) -> some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)

        if draggingLocalTabID == tab.id {
            // The landing slot: an empty card, so the cards under it don't
            // show through while the floating preview carries the tab.
            shape
                .fill(DesignTokens.contentCardSurface.opacity(0.5))
                .overlay(shape.strokeBorder(.black.opacity(0.08)))
                .frame(width: DesignTokens.tabMaxWidth, height: DesignTokens.tabHeight)
                .offset(x: card.minX)
                .zIndex(card.zIndex)
                .allowsHitTesting(false)
        } else {
            deckTab(tab, card: card, shape: shape)
        }
    }

    private func deckTab(_ tab: TabModel, card: TabDeckLayout.Card, shape: RoundedRectangle) -> some View {
        TabItemView(
            tab: tab,
            contentKind: tabManager.contentKind(for: tab.id),
            isActive: tab.id == tabManager.activeTabID,
            isDirty: tabManager.isTabDirty(tab.id),
            isHovering: hoveredTabID == tab.id,
            style: card.showsWhole ? .card : .sliver(card.side == .leading ? .leading : .trailing)
        )
        .frame(width: DesignTokens.tabMaxWidth)
        // A hairline and a shadow cast away from the focused card mark each
        // card's edge where it lies over the next one.
        .overlay(shape.strokeBorder(.black.opacity(0.08)).allowsHitTesting(false))
        .shadow(
            color: .black.opacity(0.08),
            radius: 2,
            x: card.side == .leading ? -1 : card.side == .trailing ? 1 : 0
        )
        .offset(x: card.minX)
        .zIndex(card.zIndex)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func deckFrameReporter(ids: [UUID], layout: TabDeckLayout) -> some View {
        if isInteractive {
            GeometryReader { geo in
                let origin = geo.frame(in: .named(Self.coordinateSpace)).origin
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: Dictionary(uniqueKeysWithValues: zip(ids, layout.cards).map { id, card in
                        (id, CGRect(
                            x: origin.x + card.visibleMinX,
                            y: origin.y,
                            width: card.visibleWidth,
                            height: geo.size.height
                        ))
                    })
                )
            }
        }
    }

    // MARK: - New Tab Button

    private var newTabButton: some View {
        ChromeGlassIcon(systemName: "plus")
            .background(newTabFrameReporter)
    }

    @ViewBuilder
    private func tabFrameReporter(for tabID: UUID) -> some View {
        if isInteractive {
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFramePreferenceKey.self,
                    value: [tabID: geo.frame(in: .named(Self.coordinateSpace))]
                )
            }
        }
    }

    @ViewBuilder
    private var newTabFrameReporter: some View {
        if isInteractive {
            GeometryReader { geo in
                Color.clear.preference(
                    key: NewTabButtonFramePreferenceKey.self,
                    value: geo.frame(in: .named(Self.coordinateSpace))
                )
            }
        }
    }

    // MARK: - Drag State Projections

    private var draggingLocalTabID: UUID? {
        guard let drag = dragController.activeDrag,
              drag.sourceManagerID == ObjectIdentifier(tabManager) else {
            return nil
        }
        return drag.tabID
    }

    private var localInsertionIndex: Int? {
        guard let drag = dragController.activeDrag,
              drag.insertionTargetID == ObjectIdentifier(tabManager) else {
            return nil
        }
        return drag.insertionIndex
    }

    private func shiftOffset(for tabID: UUID) -> CGFloat {
        guard let drag = dragController.activeDrag,
              drag.tabID != tabID,
              let targetIndex = localInsertionIndex,
              let thisIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
            return 0
        }

        let isLocalDrag = drag.sourceManagerID == ObjectIdentifier(tabManager)
        let sourceIndex = isLocalDrag
            ? tabManager.tabs.firstIndex(where: { $0.id == drag.tabID })
            : nil
        // A local drag whose source row vanished (mid-mutation) shifts
        // nothing — nil sourceIndex means cross-window to TabGapShift.
        if isLocalDrag, sourceIndex == nil { return 0 }

        return TabGapShift.offset(
            index: thisIndex,
            sourceIndex: sourceIndex,
            insertionIndex: targetIndex,
            draggedWidth: drag.draggedWidth,
            tabSpacing: DesignTokens.tabSpacing
        )
    }

    // MARK: - Click Routing

    private func handleClick(_ target: TabBarClickTarget) {
        switch target {
        case .newTab:
            tabManager.createNewTab()
        case .selectTab(let tabID):
            tabManager.selectTab(tabID)
        case .closeTab(let tabID):
            tabManager.closeTab(tabID)
        }
    }

    // MARK: - Constants

    private static let coordinateSpace = "tabBar"
}

// MARK: - Preference Keys

/// The width the tab strip needs to show all its tabs, so the top chrome can
/// fold a pinned toolbar while they wouldn't fit beside it.
struct TabStripWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
