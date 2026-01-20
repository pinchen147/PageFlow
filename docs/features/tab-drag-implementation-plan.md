# Tab Drag Implementation Plan

## Problem Analysis

### Current State: Tab Dragging is Completely Broken

When attempting to drag a tab:
1. Nothing happens - the tab doesn't move
2. Window may move instead (if dragging in wrong area)
3. Clicking still works (tab selection)

### Root Cause: SwiftUI Gesture Priority Conflict

**The Conflict Chain:**

```
MainView.swift (lines 112-121)
├── HStack with .contentShape(Rectangle()) + .onContinuousHover
│   └── TabBarView.swift (line 47-58)
│       └── .gesture(DragGesture(...)) ← OUTER gesture
│           └── TabItemView.swift (line 65-67)
│               └── .onTapGesture { onSelect() } ← INNER gesture (WINS!)
```

**SwiftUI's Default Gesture Priority:**
- Inner gestures ALWAYS win over outer gestures by default
- `onTapGesture` in TabItemView is **inner**
- `DragGesture` in TabBarView is **outer**
- Result: `onTapGesture` claims the touch, drag never fires

**Why This Happens:**
1. User touches tab → TabItemView's `onTapGesture` begins recognition
2. User drags (moves > 8px) → DragGesture should activate BUT
3. `onTapGesture` already owns the gesture sequence
4. DragGesture's `onChanged` never fires

---

## Solution Architecture

### Principle: Single Gesture Owner Per Tab

Instead of layered gestures (tap in child, drag in parent), use a **unified gesture handler** at the tab level.

```
TabBarView
└── ForEach(tabs)
    └── TabContainer (NEW - owns ALL gestures)
        ├── TabItemView (display only, no gestures)
        ├── TapGesture (for selection)
        └── DragGesture (for reordering)
```

### Key Changes

| File | Change |
|------|--------|
| `TabItemView.swift` | Remove `.onTapGesture`, make display-only |
| `TabBarView.swift` | Add unified gesture handling per tab |
| `MainView.swift` | No changes needed |

---

## Implementation Plan

### Phase 1: Make TabItemView Gesture-Free

**File:** `PageFlow/Views/TabItemView.swift`

**Remove:**
```swift
// DELETE lines 65-67:
.onTapGesture {
    onSelect()
}
```

**Keep:** The `onSelect` callback parameter (TabBarView will call it)

**Result:** TabItemView becomes a pure display component

---

### Phase 2: Unified Gesture Handling in TabBarView

**File:** `PageFlow/Views/TabBarView.swift`

**Strategy:** Use `simultaneousGesture` with custom state to differentiate tap vs drag

```swift
// Replace lines 28-60 with:

TabItemView(
    tab: tab,
    isActive: tab.id == tabManager.activeTabID,
    isDirty: isDirty,
    onSelect: { },  // Not used - handled below
    onClose: { tabManager.closeTab(tab.id) }
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
.zIndex(isDragging ? 1 : 0)
.scaleEffect(isDragging ? 1.02 : 1.0)
.shadow(color: isDragging ? .black.opacity(0.2) : .clear, radius: 8, y: 4)
.contentShape(Rectangle())  // ADD: Ensure entire area is tappable/draggable
.gesture(
    DragGesture(minimumDistance: 0)  // CHANGE: Start immediately
        .onChanged { value in
            handleDragChanged(value, for: tab.id)
        }
        .onEnded { value in
            handleDragEnded(value, for: tab.id)
        }
)
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
```

**New State Variables:**
```swift
@State private var draggingTabID: UUID?
@State private var dragOffset: CGFloat = 0
@State private var dragStartLocation: CGPoint?  // NEW: Track start
@State private var isDragCommitted: Bool = false  // NEW: Past threshold?
@State private var tabFrames: [UUID: CGRect] = [:]

private let dragThreshold: CGFloat = 5  // Pixels before drag activates
```

**New Gesture Handlers:**
```swift
private func handleDragChanged(_ value: DragGesture.Value, for tabID: UUID) {
    // First touch - record start location
    if dragStartLocation == nil {
        dragStartLocation = value.startLocation
    }

    let translation = value.translation.width

    // Check if drag threshold exceeded
    if !isDragCommitted && abs(translation) > dragThreshold {
        isDragCommitted = true
        draggingTabID = tabID
        NSCursor.closedHand.push()
    }

    // Only update offset if drag is committed
    if isDragCommitted {
        dragOffset = translation
    }
}

private func handleDragEnded(_ value: DragGesture.Value, for tabID: UUID) {
    let translation = value.translation.width

    if isDragCommitted {
        // Was dragging - commit the reorder
        NSCursor.pop()
        commitDrag(for: tabID)
    } else if abs(translation) <= dragThreshold {
        // Was a tap - select the tab
        tabManager.selectTab(tabID)
    }

    // Reset all state
    resetDragState()
}

private func resetDragState() {
    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
        draggingTabID = nil
        dragOffset = 0
    }
    dragStartLocation = nil
    isDragCommitted = false
}
```

---

### Phase 3: Improved Shift Calculation

**Current Problem:** Tabs shift too aggressively

**Fix:** Add dead zone threshold

```swift
private func shiftOffset(for tabID: UUID) -> CGFloat {
    guard let draggingID = draggingTabID,
          draggingID != tabID,
          let draggingFrame = tabFrames[draggingID],
          let thisFrame = tabFrames[tabID] else {
        return 0
    }

    let draggingCenter = draggingFrame.midX + dragOffset
    let thisCenter = thisFrame.midX

    guard let draggingIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingID }),
          let thisIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
        return 0
    }

    let tabWidth = thisFrame.width + DesignTokens.tabSpacing
    let threshold = tabWidth * 0.3  // NEW: 30% dead zone

    if draggingIndex < thisIndex && draggingCenter > thisCenter - threshold {
        return -tabWidth
    } else if draggingIndex > thisIndex && draggingCenter < thisCenter + threshold {
        return tabWidth
    }

    return 0
}
```

---

### Phase 4: Spring Animations

Replace all `.easeInOut` with spring physics:

| Animation | Parameters |
|-----------|------------|
| Tab lift (drag start) | `.spring(response: 0.2, dampingFraction: 0.8)` |
| Other tabs shifting | `.spring(response: 0.3, dampingFraction: 0.7)` |
| Tab drop | `.spring(response: 0.35, dampingFraction: 0.65)` |
| Cancel (return) | `.spring(response: 0.25, dampingFraction: 0.8)` |

---

## Complete Code

### TabItemView.swift (After Changes)

```swift
//
//  TabItemView.swift
//  PageFlow
//
//  Individual tab component - display only, no gesture handling
//

import SwiftUI

struct TabItemView: View {
    let tab: TabModel
    let isActive: Bool
    let isDirty: Bool
    let onSelect: () -> Void  // Kept for API compatibility
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            HStack(spacing: DesignTokens.spacingXS) {
                if isDirty {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: DesignTokens.tabDirtyIndicatorSize, height: DesignTokens.tabDirtyIndicatorSize)
                }
                Text(tab.displayTitle)
                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                    .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: DesignTokens.tabMaxWidth - DesignTokens.tabCloseButtonSize - DesignTokens.spacingSM)
            }

            if isHovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.tabCloseButtonSize, height: DesignTokens.tabCloseButtonSize)
                .onHover { hovering in
                    (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
            }
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, DesignTokens.spacingXS)
        .frame(height: DesignTokens.tabHeight)
        .frame(minWidth: DesignTokens.tabMinWidth, maxWidth: DesignTokens.tabMaxWidth)
        .background(.ultraThinMaterial)
        .background(DesignTokens.floatingToolbarBase.opacity(isActive ? 0.2 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius)
                .strokeBorder(.white.opacity(isActive ? 0.3 : 0.18))
        )
        .shadow(color: .black.opacity(0.1), radius: isActive ? 8 : 4, y: isActive ? 4 : 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        // NO .onTapGesture - parent handles all gestures
    }
}
```

### TabBarView.swift (After Changes)

```swift
//
//  TabBarView.swift
//  PageFlow
//
//  Chrome-style tabs with unified gesture handling
//

import SwiftUI

struct TabBarView: View {
    @Bindable var tabManager: TabManager
    @Binding var isHovering: Bool

    // Drag state
    @State private var draggingTabID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dragStartLocation: CGPoint?
    @State private var isDragCommitted: Bool = false
    @State private var tabFrames: [UUID: CGRect] = [:]

    private let dragThreshold: CGFloat = 5

    var body: some View {
        HStack(spacing: DesignTokens.tabSpacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignTokens.tabSpacing) {
                    ForEach(tabManager.tabs) { tab in
                        tabView(for: tab)
                    }

                    newTabButton
                }
                .padding(.horizontal, DesignTokens.spacingXS)
            }
            .coordinateSpace(name: "tabBar")
            .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                tabFrames = frames
            }
        }
        .frame(height: DesignTokens.trafficLightHotspotHeight)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: isHovering)
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
            onSelect: { },
            onClose: { tabManager.closeTab(tab.id) }
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
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDragChanged(value, for: tab.id)
                }
                .onEnded { value in
                    handleDragEnded(value, for: tab.id)
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
    }

    // MARK: - New Tab Button

    private var newTabButton: some View {
        Button {
            tabManager.createNewTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial)
                .background(DesignTokens.floatingToolbarBase.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.22))
                )
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .onHover { hovering in
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }

    // MARK: - Gesture Handlers

    private func handleDragChanged(_ value: DragGesture.Value, for tabID: UUID) {
        if dragStartLocation == nil {
            dragStartLocation = value.startLocation
        }

        let translation = value.translation.width

        if !isDragCommitted && abs(translation) > dragThreshold {
            isDragCommitted = true
            draggingTabID = tabID
            NSCursor.closedHand.push()
        }

        if isDragCommitted {
            dragOffset = translation
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, for tabID: UUID) {
        let translation = value.translation.width

        if isDragCommitted {
            NSCursor.pop()
            commitDrag(for: tabID)
        } else if abs(translation) <= dragThreshold {
            tabManager.selectTab(tabID)
        }

        resetDragState()
    }

    // MARK: - Drag Helpers

    private func shiftOffset(for tabID: UUID) -> CGFloat {
        guard let draggingID = draggingTabID,
              draggingID != tabID,
              let draggingFrame = tabFrames[draggingID],
              let thisFrame = tabFrames[tabID] else {
            return 0
        }

        let draggingCenter = draggingFrame.midX + dragOffset
        let thisCenter = thisFrame.midX

        guard let draggingIndex = tabManager.tabs.firstIndex(where: { $0.id == draggingID }),
              let thisIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }) else {
            return 0
        }

        let tabWidth = thisFrame.width + DesignTokens.tabSpacing
        let threshold = tabWidth * 0.3

        if draggingIndex < thisIndex && draggingCenter > thisCenter - threshold {
            return -tabWidth
        } else if draggingIndex > thisIndex && draggingCenter < thisCenter + threshold {
            return tabWidth
        }

        return 0
    }

    private func commitDrag(for tabID: UUID) {
        guard let sourceIndex = tabManager.tabs.firstIndex(where: { $0.id == tabID }),
              let sourceFrame = tabFrames[tabID] else {
            resetDragState()
            return
        }

        let draggedCenter = sourceFrame.midX + dragOffset

        var targetIndex = sourceIndex
        for (index, tab) in tabManager.tabs.enumerated() {
            guard let frame = tabFrames[tab.id], tab.id != tabID else { continue }

            if sourceIndex < index && draggedCenter > frame.midX {
                targetIndex = index
            } else if sourceIndex > index && draggedCenter < frame.midX {
                targetIndex = index
            }
        }

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
        dragStartLocation = nil
        isDragCommitted = false
    }
}

// MARK: - Preference Key

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
```

---

## Testing Checklist

After implementation:

1. **Tap to select**: Click tab → should switch to that tab
2. **Drag to reorder**: Drag tab left/right → should reorder tabs
3. **Drag threshold**: Small movement (< 5px) → should be tap, not drag
4. **Close button**: Hover → X appears, click → closes tab
5. **Visual feedback**: Dragged tab lifts (scale 1.03), has shadow
6. **Other tabs shift**: As dragged tab moves past, others slide over
7. **Spring animations**: All movements use spring physics, no sudden jumps
8. **Cursor change**: Drag → closed hand cursor
9. **Multiple tabs**: Test with 2, 3, 5+ tabs
10. **Edge cases**: Drag to far left, far right

---

## Future: Cross-Window Tab Merge (PAG-8)

This plan covers PAG-22 (same-window reordering). PAG-8 (cross-window merge) requires:

1. **NSWindow tabbing API** - macOS native window tabbing
2. **Drag outside window detection** - monitor when drag leaves bounds
3. **Window creation/merging** - create new window or merge into existing

This is a separate implementation phase.
