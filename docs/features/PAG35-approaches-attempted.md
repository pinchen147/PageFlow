# PAG-35: Implementation Attempts

This document records approaches attempted for the edge-hover autoscroll feature.

---

## Approach 1: Index-Based Autoscroll

**Commits:**
- Added: `5b46008` ("thumbnail hover autoscroll 1")
- Removed: `3de06d1` ("cleaned up all hover autoscroll code + working through bugs")

**Status:** Removed

### Implementation Overview

Created an `AutoScrollManager` class to handle timer-based scrolling during drag operations. The manager tracked visible thumbnail indices and triggered scrolling when the drag target was near the visible range edges.

### Key Code

**AutoScrollManager (from commit 5b46008):**

```swift
@MainActor
private final class AutoScrollManager {
    enum Direction: Sendable { case none, up, down }

    // State updated by the view - manager reads these directly in tick()
    var visibleIndices: Set<Int> = []
    var pageCount: Int = 0

    private(set) var direction: Direction = .none
    private var timer: Timer?
    private var scrollAction: ((Int, UnitPoint) -> Void)?

    func start(direction: Direction, scrollAction: @escaping (Int, UnitPoint) -> Void) {
        stop()
        self.direction = direction
        self.scrollAction = scrollAction
        tick()

        // CRITICAL: Use .common mode so timer fires during drag (eventTracking mode)
        // Default scheduledTimer only fires in .default mode, not during drags
        let newTimer = Timer(timeInterval: DesignTokens.autoscrollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        switch direction {
        case .up:
            guard let top = visibleIndices.min() else { return }
            guard top > 0 else { stop(); return }  // Stop at document start
            scrollAction?(top - 1, .top)
        case .down:
            guard let bottom = visibleIndices.max() else { return }
            guard bottom < pageCount - 1 else { stop(); return }  // Stop at document end
            scrollAction?(bottom + 1, .bottom)
        case .none:
            break
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        direction = .none
        scrollAction = nil
    }
}
```

**Edge Detection Logic (index-based):**

```swift
private func updateAutoScroll(for index: Int, proxy: ScrollViewProxy) {
    guard isEditing, dragFromIndex != nil else {
        autoScrollManager.stop()
        return
    }

    // Read current visible range from manager (always fresh)
    let topVisible = autoScrollManager.visibleIndices.min() ?? 0
    let bottomVisible = autoScrollManager.visibleIndices.max() ?? max(0, pdfManager.pageCount - 1)
    let edgeThreshold = 1  // Trigger when within 1 cell of edge

    let isNearTop = index <= topVisible + edgeThreshold
    let isNearBottom = index >= bottomVisible - edgeThreshold
    let canScrollUp = topVisible > 0
    let canScrollDown = bottomVisible < pdfManager.pageCount - 1

    if isNearTop && canScrollUp {
        if autoScrollManager.direction != .up {
            autoScrollManager.start(direction: .up) { target, anchor in
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                    proxy.scrollTo("page-\(target)", anchor: anchor)
                }
            }
        }
    } else if isNearBottom && canScrollDown {
        if autoScrollManager.direction != .down {
            autoScrollManager.start(direction: .down) { target, anchor in
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                    proxy.scrollTo("page-\(target)", anchor: anchor)
                }
            }
        }
    } else {
        autoScrollManager.stop()
    }
}
```

**Visible Index Tracking:**

```swift
ThumbnailCell(...)
    .id("page-\(index)")
    .onAppear { autoScrollManager.visibleIndices.insert(index) }
    .onDisappear { autoScrollManager.visibleIndices.remove(index) }
```

### Design Tokens (removed in 3de06d1)

```swift
// MARK: - Autoscroll (Thumbnail Drag)

static let autoscrollEdgeZone: CGFloat = 70       // Edge detection zone size
static let autoscrollHysteresis: CGFloat = 10    // Jitter prevention buffer
static let autoscrollInterval: Double = 0.25     // Time between scroll steps
```

### What Worked

1. **Timer with `.common` RunLoop mode** - Timer correctly fired during drag operations
2. **Class-based manager** - Survived timer callbacks and maintained state
3. **Visible index tracking** - Accurately tracked which cells were on screen
4. **Document boundary stopping** - Correctly stopped at start/end of document

### Why It Was Removed

The implementation did not meet PAG-35 requirements:

| PAG-35 Requirement | Implementation Status |
|--------------------|----------------------|
| Speed ramp based on edge proximity | Not implemented - constant speed |
| Hysteresis for jitter prevention | Not implemented - no buffer zone |
| Dwell time (50-100ms) before activation | Not implemented - instant activation |
| Edge zones (40-120px from viewport edge) | Partially - used cell index proximity instead of pixel coordinates |

### Specific Issues

1. **Index-based vs Pixel-based Detection**
   - Used `dragToIndex` proximity to visible range (`edgeThreshold = 1`)
   - PAG-35 requires cursor pixel coordinates from `DropInfo.location`
   - Index-based is coarser and doesn't allow smooth speed ramping

2. **No Speed Ramp**
   - Fixed `autoscrollInterval: 0.25` for all scrolling
   - PAG-35 requires speed proportional to edge proximity
   - Closer to edge = faster scroll

3. **No Dwell Time**
   - Scrolling started immediately when entering edge zone
   - PAG-35 requires 50-100ms delay before activation
   - Missing delay causes accidental scrolls

4. **No Hysteresis**
   - Scrolling stopped immediately when leaving edge zone
   - PAG-35 requires buffer zone to prevent jitter
   - Missing hysteresis causes flickering at boundary

### Lessons Learned

1. **RunLoop `.common` mode is essential** - Keep this pattern for any future timer-based drag handling
2. **Pixel coordinates required** - Need `GeometryReader` + `DropInfo.location` for proper edge detection
3. **Class-based manager is correct** - Struct wouldn't work for timer ownership
4. **visibleIndices tracking useful** - Can supplement pixel-based detection for target calculation

---

## Approach 2: Pixel-Based with Coordinate Space Conversion

**Date:** 2026-01-18

**Status:** Partially working - scroll down (dragging bottom pages up) works, scroll up (dragging top pages down) does NOT work

### Implementation Overview

Attempted to fix the index-based approach by using pixel coordinates. Added:
- Named coordinate space on viewport (`"thumbnailViewport"`)
- `GeometryReader` in `DragDropModifier` to get cell's frame in viewport space
- Coordinate conversion: `viewportY = cellFrame.minY + info.location.y`
- Full `AutoScrollManager` with dwell time, speed ramp, and hysteresis

### Key Code

**Coordinate Space Setup:**
```swift
private let viewportCoordinateSpace = "thumbnailViewport"

// In ThumbnailGridView body:
GeometryReader { geo in
    ScrollView { ... }
}
.coordinateSpace(name: viewportCoordinateSpace)
```

**DragDropModifier with Background GeometryReader:**
```swift
private struct DragDropModifier: ViewModifier {
    let coordinateSpaceName: String
    @State private var cellFrame: CGRect = .zero

    func body(content: Content) -> some View {
        if isEditing {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            cellFrame = geo.frame(in: .named(coordinateSpaceName))
                        }
                        .onChange(of: geo.frame(in: .named(coordinateSpaceName))) { _, newFrame in
                            cellFrame = newFrame
                        }
                    }
                )
                .onDrop(of: [UTType.text], delegate: ReorderDropDelegate(
                    cellFrame: cellFrame,
                    // ...
                ))
        }
    }
}
```

**Coordinate Conversion in DropDelegate:**
```swift
func dropUpdated(info: DropInfo) -> DropProposal? {
    let viewportY = cellFrame.minY + info.location.y
    onDragUpdate(viewportY)
    return DropProposal(operation: .move)
}
```

### What Worked

1. **Scroll down works** - Dragging a page from bottom of list upward, when cursor enters top edge zone, autoscroll triggers and scrolls up correctly
2. **Layout preserved** - Using `.background(GeometryReader)` instead of wrapping in `GeometryReader` fixed the collapsed thumbnails bug
3. **Speed ramp, dwell time, hysteresis** - All implemented and functional when scrolling works

### What Failed

**Scroll up does NOT work** - Dragging a page from top of list downward, cursor at bottom edge zone does not trigger autoscroll.

### Root Cause Analysis

The issue is likely related to how `cellFrame` is captured and when it updates:

1. **Stale cellFrame during scroll:** When cells scroll, `cellFrame` might not update fast enough
2. **Coordinate space origin:** The named coordinate space is on the `GeometryReader`, which wraps the `ScrollView`. The ScrollView's content scrolls, but the coordinate space origin stays fixed. This means:
   - Cells at the TOP of viewport have small `cellFrame.minY` values
   - Cells at the BOTTOM of viewport have large `cellFrame.minY` values
   - When scrolling DOWN (content moves up), visible cells' `cellFrame.minY` values DECREASE

3. **Hypothesis:** When dragging downward toward bottom edge:
   - Cursor is over a cell near bottom of viewport
   - That cell has large `cellFrame.minY` (e.g., 400-500px)
   - `info.location.y` is relative to cell (small value, 0-170px)
   - `viewportY = cellFrame.minY + info.location.y` = large value (450-670px)
   - If `viewportHeight` is ~600px, `viewportY > viewportHeight - edgeZone` should trigger
   - BUT: `cellFrame` is captured on `onAppear` and `onChange` - may be stale during drag

4. **The real problem:** `dropUpdated` creates a NEW `ReorderDropDelegate` struct on every call with the CURRENT `cellFrame` value. But `cellFrame` is `@State` in the modifier, and SwiftUI may not be updating it during the drag operation.

### Lessons Learned

1. **`@State` in ViewModifier during drag** - State updates may not propagate correctly to the `DropDelegate` during active drag operations
2. **Coordinate conversion timing** - The cell frame needs to be read at the moment of `dropUpdated`, not cached
3. **ScrollView coordinate spaces** - Content offset affects frame calculations in complex ways

---

## Approach 3: NSEvent.mouseLocation (Initial - Broken)

**Date:** 2026-01-18

**Status:** Broken - downscroll completely fails

### Implementation Overview

Attempted to bypass SwiftUI's stale coordinate caching by reading `NSEvent.mouseLocation` directly during drag.

### Key Code (Broken)

```swift
// ViewportFrameReader captures frame in SwiftUI .global coordinates
private struct ViewportFrameReader: View {
    @Binding var frame: CGRect
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }  // SwiftUI coords
        }
    }
}

// updateAutoScroll used NSEvent.mouseLocation (screen coords)
let mouseScreenLocation = NSEvent.mouseLocation
let viewportY = viewportScreenFrame.maxY - mouseScreenLocation.y  // WRONG!
```

### Root Cause: Coordinate System Mismatch

**Two completely different coordinate systems mixed:**

| Source | Coordinate System | Origin | Y Direction |
|--------|------------------|--------|-------------|
| `NSEvent.mouseLocation` | macOS screen | Bottom-left of SCREEN | Up |
| `geo.frame(in: .global)` | SwiftUI window | Top-left of WINDOW | Down |

The subtraction `viewportScreenFrame.maxY - mouseScreenLocation.y` produces garbage:
- When cursor at bottom of viewport → large negative `viewportY` → never triggers bottom zone
- When cursor at top → accidentally small positive values → sometimes triggers top zone

### Fix Applied: Use Window Coordinates Consistently

```swift
guard let window = NSApp.keyWindow else { return }

// Get mouse in window coordinates (AppKit: origin bottom-left, Y up)
let mouseInWindow = window.mouseLocationOutsideOfEventStream

// Convert to SwiftUI coordinates (origin top-left, Y down)
let mouseWindowY = window.frame.height - mouseInWindow.y

// viewportScreenFrame is in SwiftUI .global coords (window-relative)
let viewportY = mouseWindowY - viewportScreenFrame.minY
```

**Key insight:** `window.mouseLocationOutsideOfEventStream` gives mouse position in the same coordinate system base as the window, which can be properly flipped and compared with SwiftUI's `.global` frame.

---

## Approach 3b: Stale Frame Cache Bug

**Date:** 2026-01-18

**Status:** Still broken - same "works after first upscroll" pattern

### Root Cause

Two separate GeometryReaders were providing viewport info:
1. Outer `geo` in `GeometryReader { geo in ... }` → sets `viewportHeight`
2. `ViewportFrameReader` (background view) → sets `viewportScreenFrame`

The `ViewportFrameReader` used `onAppear` and `onChange` to cache the frame. But:
- `onAppear` fires once
- `onChange` only fires when frame CHANGES
- During initial drag, cached `viewportScreenFrame` could be stale or `.zero`

### Fix Applied: Single Source of Truth

Removed `ViewportFrameReader` entirely. Now pass `geo` directly to `updateAutoScroll`:

```swift
.modifier(DragDropModifier(
    // ...
    onDragUpdate: { updateAutoScroll(proxy: proxy, geo: geo) },  // Pass geo directly
))

private func updateAutoScroll(proxy: ScrollViewProxy, geo: GeometryProxy) {
    // Always read fresh frame (don't rely on cached state)
    let frame = geo.frame(in: .global)
    let viewportY = mouseWindowY - frame.minY
    autoScrollManager.viewportHeight = frame.height  // Update on every call
}
```

**Key changes:**
1. Removed `ViewportFrameReader` struct
2. Pass `GeometryProxy` to `updateAutoScroll`
3. Read `geo.frame(in: .global)` fresh on every `dropUpdated` call
4. Update `viewportHeight` on every call (not just `onAppear`/`onChange`)

---

## Approach 4: Initialization Timing Fixes

**Date:** 2026-01-18

**Status:** Failed - issue persists

### Hypothesis

The bug "autoscroll doesn't work when thumbnail view first opens, only after manual scroll" was hypothesized to be caused by three initialization timing issues:

1. **Empty `visibleIndices`** - `autoScrollManager.visibleIndices` starts empty, populated via `.onAppear` on cells which fires asynchronously. If drag starts before cells' `.onAppear` fires, `visibleIndices.min()` returns `nil` → `stopAll()` called immediately.

2. **Zero frame from GeometryReader** - `geo.frame(in: .global)` can return `.zero` before layout completes. Edge detection `cursorY > viewportHeight - 60` always false if height is 0.

3. **Nil `NSApp.keyWindow`** - On initial sidebar open, `keyWindow` may not be established. SwiftUI overlays don't have guaranteed window access initially.

### Fixes Applied

**Fix 1: Handle empty visibleIndices in `tick()`**
```swift
case .top:
    // Use fallback of 0 if visibleIndices is empty (layout not complete yet)
    let topVisible = visibleIndices.min() ?? 0
    guard topVisible > 0 else {
        stopAll()
        return
    }
    scrollAction(topVisible - 1, .top)

case .bottom:
    // Use fallback of pageCount-1 if visibleIndices is empty (layout not complete yet)
    let bottomVisible = visibleIndices.max() ?? (pageCount - 1)
    guard bottomVisible < pageCount - 1 else {
        stopAll()
        return
    }
    scrollAction(bottomVisible + 1, .bottom)
```

**Fix 2: Guard against zero frame in `updateAutoScroll()`**
```swift
let frame = geo.frame(in: .global)
guard frame.height > 0 else { return }  // Layout not complete yet
```

**Fix 3: Fallback window sources**
```swift
guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
```

### Why It Failed

The fixes addressed defensive edge cases but did not resolve the core issue. The bug pattern remains:
- Autoscroll does NOT work immediately after opening sidebar + clicking Edit
- Autoscroll DOES work after user manually scrolls the thumbnail list

This suggests the root cause is NOT initialization timing of `visibleIndices`, frame, or window. The pattern "works after manual scroll" indicates something about the scroll interaction itself enables the autoscroll system.

### New Hypotheses

1. **ScrollViewReader proxy state** - The `ScrollViewProxy` may not be fully functional until the ScrollView has been interacted with
2. **LazyVStack deferred loading** - `LazyVStack` may not report accurate geometry until content is scrolled into view
3. **Coordinate space establishment** - The `.global` coordinate space relationship may not be established until first scroll
4. **Timer RunLoop mode** - Something about the drag event tracking mode may differ before/after scroll interaction

### Lessons Learned

1. Defensive fallbacks for empty/nil state don't help if the core mechanism is broken
2. The "works after scroll" pattern is the key diagnostic - focus on what scroll interaction changes
3. Need to add logging/debugging to identify exactly where the failure occurs

---

## Approach 5: Debug Logging + Root Cause Analysis

**Date:** 2026-01-18

**Status:** Root cause IDENTIFIED - `visibleIndices` becomes empty during drag due to SwiftUI view recreation

### Debug Logging Added

Added comprehensive debug logging throughout the autoscroll system:

```swift
private let DEBUG_AUTOSCROLL = true

private func debugLog(_ message: String) {
    if DEBUG_AUTOSCROLL {
        print("[AUTOSCROLL] \(message)")
    }
}
```

Logging added to:
- `updateCursor()` - cursor position, viewport height, edge zones
- `activateScrolling()` - timer activation
- `tick()` - scroll targets and blocking conditions
- `startDwell()` - dwell timer start
- `updateAutoScroll()` - all early returns and state
- Cell `onAppear`/`onDisappear` - visibleIndices changes

### Debug Log Analysis

**Critical Discovery from logs:**

```
[AUTOSCROLL] Cell 0 APPEARED, visibleIndices now: [0]
[AUTOSCROLL] Cell 1 APPEARED, visibleIndices now: [0, 1]
[AUTOSCROLL] Cell 2 APPEARED, visibleIndices now: [0, 1, 2]
[AUTOSCROLL] Cell 3 APPEARED, visibleIndices now: [0, 1, 2, 3]
[AUTOSCROLL] Cell 4 APPEARED, visibleIndices now: [0, 1, 2, 3, 4]
...
[AUTOSCROLL] Cell 0 DISAPPEARED, visibleIndices now: [1, 2, 3, 4]
[AUTOSCROLL] Cell 1 DISAPPEARED, visibleIndices now: [2, 3, 4]
[AUTOSCROLL] Cell 2 DISAPPEARED, visibleIndices now: [3, 4]
[AUTOSCROLL] Cell 3 DISAPPEARED, visibleIndices now: [4]
[AUTOSCROLL] Cell 4 DISAPPEARED, visibleIndices now: []
...
[AUTOSCROLL]   visibleIndices=[], pageCount=55
[AUTOSCROLL]   detectedZone=none, activeZone=none, isScrollingActive=false
```

**What the logs show:**
1. Cells 0-4 appear initially → `visibleIndices = [0, 1, 2, 3, 4]`
2. ALL cells DISAPPEAR before drag is processed → `visibleIndices = []`
3. During entire drag operation → `visibleIndices = []` stays empty
4. All autoscroll attempts fail because `visibleIndices` is empty
5. After manual scroll → cells reappear → `visibleIndices` repopulates → autoscroll works

### Root Cause: SwiftUI View Recreation During Drag

**5 parallel investigation agents identified the root cause:**

#### 1. Error Trace Agent Findings

The animation on LazyVStack (line 274) causes view recreation:

```swift
.animation(.easeInOut(duration: 0.15), value: dragToIndex)
```

When `dragToIndex` changes during drag:
- SwiftUI re-evaluates the entire body
- The animation modifier causes a view hierarchy rebuild
- `ForEach(Array(0..<pdfManager.pageCount), id: \.self)` recreates child views
- During animation transition, SwiftUI temporarily unmounts ALL child views
- `.onDisappear` fires on ALL cells
- `visibleIndices` becomes empty `[]`
- Cells should remount after animation, but during active drag the remount happens asynchronously
- `.onAppear` callbacks haven't fired yet when `tick()` is called

#### 2. State Flow Agent Findings

The `.id(refreshID)` on `ThumbnailCellView` (line 518) compounds the issue:

```swift
.id(refreshID)
```

When `pageIndex` changes via `visualIndex()` during drag:
- `onChange(of: pageIndex)` fires
- `.id()` modifier causes cell to be destroyed and recreated
- Rapid `onAppear`/`onDisappear` cycles cause `visibleIndices` inconsistency

#### 3. External Research Findings

**This is a KNOWN SwiftUI limitation:**

From objc.io Swift Talk:
> "onAppear/onDisappear might not be the right tool for tracking visible items in LazyVStack because items may be created before they're visible to the user, and items are pre-loaded in a buffer zone"

From fatbobman.com (SwiftUI lifecycle):
> "In LazyVStack, cells trigger onAppear when entering the display range and onDisappear when leaving, and this can be repeated multiple times during the view's existence"

**Key insight:** `onAppear`/`onDisappear` is NOT reliable for tracking visible items in LazyVStack, especially during gestures.

#### 4. Why Fallback Values Don't Help

The Approach 4 fallbacks:
```swift
let bottomVisible = visibleIndices.max() ?? (pageCount - 1)
guard bottomVisible < pageCount - 1 else { stopAll(); return }
```

When `visibleIndices` is empty:
- `bottomVisible` = 54 (pageCount - 1)
- Guard check: `54 < 55 - 1` → `54 < 54` → FALSE
- Autoscroll immediately stops, thinking we're at document end

### Recommendations from Research

**Option A: PreferenceKey + Anchor (Recommended)**
- Use `Anchor<CGRect>` preference key for each cell
- Check intersection in `overlayPreferenceValue` modifier
- Survives gesture state changes

**Option B: Don't Track Visibility During Drag**
- Cache `visibleIndices` at drag START (before cells disappear)
- Use cached value throughout drag operation
- Update only on drag END

**Option C: Remove Animation from LazyVStack**
- Move animation to individual cell transforms
- Prevent view hierarchy rebuild

**Option D: iOS 18+ APIs (if targeting iOS 18)**
- `onScrollTargetVisibilityChange` directly tracks visible IDs
- More reliable than onAppear/onDisappear

### Files Investigated

| File | Purpose | Key Lines |
|------|---------|-----------|
| `ThumbnailGridView.swift` | Main autoscroll implementation | 23-221 (AutoScrollManager), 254-261 (onAppear/onDisappear), 274 (animation) |
| `DesignTokens.swift` | Autoscroll timing constants | edgeZone, hysteresis, dwell time |

### Hypotheses Ranked by Evidence

1. **CONFIRMED: onAppear/onDisappear unreliable during drag** - All cells disappear when drag starts
2. **CONFIRMED: Animation causes view recreation** - `.animation(..., value: dragToIndex)` rebuilds hierarchy
3. **POSSIBLE: `.id()` modifier compounds issue** - Could cause additional recreation
4. **RULED OUT: Initialization timing** - Cells DO appear initially, then disappear

### Next Steps

1. **Quick fix:** Cache `visibleIndices` at drag start, don't update during drag
2. **Better fix:** Use PreferenceKey approach instead of onAppear/onDisappear
3. **Alternative:** Remove animation from LazyVStack, animate individual cells

---

## Approach 6: onDragStart Early Caching (FIX IMPLEMENTED)

**Date:** 2026-01-19

**Status:** IMPLEMENTED - Fixes the timing race condition

### Root Cause (Confirmed)

The `cacheVisibleIndices()` call was happening TOO LATE:

1. `onDrag` closure fires → sets `dragFromIndex` and `dragToIndex`
2. SwiftUI detects state change → rebuilds LazyVStack
3. All cells fire `onDisappear` → `visibleIndices` becomes `[]`
4. `dropUpdated` fires → calls `updateAutoScroll()` → calls `cacheVisibleIndices()`
5. But `visibleIndices` is already empty → cache fails

### Fix Applied

Added `onDragStart` callback to `DragDropModifier` that fires BEFORE state changes:

```swift
// DragDropModifier now has onDragStart callback
private struct DragDropModifier: ViewModifier {
    let onDragStart: () -> Void  // NEW
    let onDrop: () -> Void
    let onDragUpdate: () -> Void
    let onDragEnd: () -> Void

    func body(content: Content) -> some View {
        content
            .onDrag {
                // Cache visible indices BEFORE state changes trigger view recreation
                onDragStart()  // ← CALLED FIRST
                dragFromIndex = index
                dragToIndex = index
                return NSItemProvider(object: String(index) as NSString)
            }
    }
}

// Usage in ThumbnailGridView:
.modifier(DragDropModifier(
    onDragStart: { autoScrollManager.cacheVisibleIndices() },  // ← NEW
    onDrop: { commitReorder() },
    onDragUpdate: { updateAutoScroll(proxy: proxy, geo: geo) },
    onDragEnd: { autoScrollManager.stopAll() }
))
```

### Why This Works

1. `onDragStart()` fires FIRST in the `onDrag` closure
2. `visibleIndices` is still populated (cells haven't disappeared yet)
3. Cache is successfully set with the current visible indices
4. THEN state changes trigger view recreation
5. When `tick()` runs, `effectiveVisibleIndices` returns the cached values

### Debug Logging Added

Enhanced `cacheVisibleIndices()` to log all cases:
- `SUCCESS` - cached values before view recreation
- `already cached` - cache exists from earlier call
- `FAILED - visibleIndices is empty` - called too late (should not happen with fix)

### Key Files Modified

| File | Change |
|------|--------|
| `ThumbnailGridView.swift:454` | Added `onDragStart` parameter to `DragDropModifier` |
| `ThumbnailGridView.swift:463-464` | Call `onDragStart()` before state mutations |
| `ThumbnailGridView.swift:297` | Pass `cacheVisibleIndices()` as `onDragStart` callback |
| `ThumbnailGridView.swift:102-113` | Enhanced debug logging in `cacheVisibleIndices()` |

### Lessons Learned

1. **Order of operations in closures matters** - Cache BEFORE state mutations, not after
2. **SwiftUI state changes are synchronous** - View recreation happens immediately when `@State` changes
3. **Defensive fallback retained** - `updateAutoScroll()` still calls `cacheVisibleIndices()` as a fallback (will be no-op if already cached)

---

## Approach 7: PreferenceKey-Based Visibility Tracking (FIX IMPLEMENTED)

**Date:** 2026-01-19

**Status:** IMPLEMENTED - Replaces unreliable onAppear/onDisappear with stable PreferenceKey

### Why Approach 6 Still Had Issues

Approach 6 (onDragStart early caching) worked in most cases, but still failed in certain scenarios:

1. **First drag after sidebar opens** - The cache attempt happens AFTER SwiftUI has already started processing state changes
2. **SwiftUI closure execution timing** - Even though `onDragStart()` is called first in the `onDrag` closure, SwiftUI may have already begun the view rebuild by the time it executes
3. **Race condition** - The `onDisappear` callbacks fire synchronously during the same render pass, emptying `visibleIndices` before caching completes

The debug logs showed:
```
[AUTOSCROLL] cacheVisibleIndices: FAILED - visibleIndices is empty (called too late)
```

### Root Cause: onAppear/onDisappear Unreliable During Gestures

`onAppear`/`onDisappear` are **view lifecycle callbacks** that fire when SwiftUI adds/removes views from the hierarchy. During drag gestures:

- State changes (`dragFromIndex`, `dragToIndex`) trigger view rebuilds
- LazyVStack may recreate all child views during animation
- All cells fire `onDisappear` in sequence
- `visibleIndices` becomes empty before any caching can occur

### Solution: PreferenceKey-Based Tracking

PreferenceKey values are computed during the **layout phase**, not during view lifecycle callbacks. This means:

1. Values are aggregated AFTER layout completes
2. They survive view recreation during gestures
3. They provide a reliable snapshot of visible cells

### Implementation

**1. VisibleIndicesPreferenceKey:**

```swift
private struct VisibleIndicesPreferenceKey: PreferenceKey {
    static var defaultValue: Set<Int> = []

    static func reduce(value: inout Set<Int>, nextValue: () -> Set<Int>) {
        value.formUnion(nextValue())
    }
}
```

**2. VisibilityReporter (per-cell visibility detection):**

```swift
private struct VisibilityReporter: View {
    let index: Int
    let viewportHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("thumbnailScrollView"))
            // Cell is visible if any part of it is within the viewport
            let isVisible = frame.maxY > 0 && frame.minY < viewportHeight
            Color.clear
                .preference(
                    key: VisibleIndicesPreferenceKey.self,
                    value: isVisible ? [index] : []
                )
        }
    }
}
```

**3. Cell with PreferenceKey tracking (replaces onAppear/onDisappear):**

```swift
ThumbnailCellView(...)
    .id("page-\(index)")
    .background(
        // PreferenceKey-based visibility tracking survives SwiftUI view recreation
        VisibilityReporter(index: index, viewportHeight: geo.size.height)
    )
```

**4. ScrollView with coordinate space and preference change handler:**

```swift
ScrollView {
    LazyVStack { ... }
}
.coordinateSpace(name: "thumbnailScrollView")
.onPreferenceChange(VisibleIndicesPreferenceKey.self) { indices in
    // PreferenceKey updates happen during layout - reliable even during drag
    if indices != autoScrollManager.visibleIndices {
        autoScrollManager.visibleIndices = indices
    }
}
```

### Why This Works

1. **Layout-phase computation** - PreferenceKey values are computed after the view hierarchy is established
2. **Coordinate space stability** - Named coordinate space on ScrollView provides stable frame reference
3. **Geometric intersection** - Visibility is determined by comparing cell frame to viewport bounds
4. **No dependency on view lifecycle** - Works regardless of when onAppear/onDisappear fire
5. **Continuous updates** - PreferenceKey values update on every layout pass, not just on appear/disappear

### Key Differences from onAppear/onDisappear

| Aspect | onAppear/onDisappear | PreferenceKey |
|--------|---------------------|---------------|
| Timing | View lifecycle events | Layout phase |
| Reliability during gestures | Unreliable (fires during rebuild) | Stable |
| Update frequency | On mount/unmount only | Every layout pass |
| Animation impact | Affected by view recreation | Unaffected |

### Key Files Modified

| File | Change |
|------|--------|
| `ThumbnailGridView.swift:23-54` | Added `VisibleIndicesPreferenceKey` and `VisibilityReporter` |
| `ThumbnailGridView.swift:322-326` | Replaced `onAppear`/`onDisappear` with `VisibilityReporter` background |
| `ThumbnailGridView.swift:345-352` | Added `coordinateSpace` and `onPreferenceChange` to ScrollView |

### Caching Retained as Fallback

The `cacheVisibleIndices()` mechanism from Approach 6 is retained as a fallback:

- With PreferenceKey, `visibleIndices` should remain populated during drag
- The cache provides safety for edge cases where PreferenceKey hasn't computed yet
- `effectiveVisibleIndices` prefers cached values if available

### Lessons Learned

1. **PreferenceKey is more reliable than lifecycle callbacks** for tracking visible items during gestures
2. **Layout-phase vs lifecycle-phase** - Understanding when SwiftUI computes different values is crucial
3. **Named coordinate spaces** enable reliable frame comparisons across view hierarchy
4. **Defense in depth** - Keeping the cache as fallback provides robustness

---

## Future Approaches

See `hover-autoscroll.md` for full requirements and design.
