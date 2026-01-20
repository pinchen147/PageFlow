# Edge-Hover Autoscroll for Thumbnail Sidebar

**Linear Issue:** PAG-35

## Summary

When users drag thumbnails to reorder pages in the sidebar, scrolling should automatically occur when the cursor hovers near the top or bottom edges of the visible area. This enables reordering pages to positions that are currently off-screen without requiring manual scrolling.

## Requirements (from Linear PAG-35)

### Edge Zone Detection
- **Edge zones:** Top and bottom regions of the sidebar viewport
- **Zone size:** 40-120px from viewport edge
- **Detection:** Based on cursor pixel coordinates from `DropInfo.location`

### Speed Ramp
- Scroll speed increases smoothly as the pointer gets closer to the edge
- Maximum speed at the viewport boundary
- Minimum speed at the inner edge of the detection zone

### Hysteresis (Jitter Prevention)
- Buffer zone to prevent rapid on/off flickering at the boundary
- Cursor must move a threshold distance (e.g., 10px) back into the safe zone to stop scrolling
- Prevents instability when cursor hovers exactly at the edge boundary

### Dwell Time
- Requires ~50-100ms dwell before activation
- Prevents accidental scrolling when quickly passing through edge zones
- Timer resets if cursor leaves the edge zone

### Stopping Conditions
- Cursor exits the edge zone (respecting hysteresis)
- Reaches document start (scrolling up) or end (scrolling down)
- Drag operation ends (drop or cancel)

## Current Codebase State

### Relevant Files

| File | Purpose |
|------|---------|
| `PageFlow/Views/ThumbnailGridView.swift` | Thumbnail grid with drag-drop reordering |
| `PageFlow/Views/SidebarView.swift` | Container for thumbnail grid |
| `PageFlow/Config/DesignTokens.swift` | Spacing and timing constants |

### Existing Infrastructure

1. **Drag-Drop System**
   - `ThumbnailGridView` uses SwiftUI's `DropDelegate` pattern
   - `ReorderDropDelegate` handles page reordering logic
   - `dragFromIndex` and `dragToIndex` state tracks drag operation

2. **Scroll Infrastructure**
   - `ScrollViewReader` wraps the thumbnail grid
   - `proxy.scrollTo("page-\(index)", anchor:)` for programmatic scrolling
   - Each thumbnail has `.id("page-\(index)")` for targeting

3. **NO autoscroll currently implemented**
   - Previous attempt was removed in commit `3de06d1`
   - See `PAG35-approaches-attempted.md` for history

### Key Integration Points

1. **ThumbnailGridView.swift**
   - Add autoscroll manager (class for timer ownership)
   - Hook into `performDrop` and `dropUpdated` in DropDelegate
   - Access `DropInfo.location` for cursor coordinates

2. **DesignTokens.swift**
   - Add constants for edge zone size, hysteresis, speed curve, dwell time

3. **SidebarView.swift**
   - May need `GeometryReader` to provide viewport bounds to ThumbnailGridView

## Technical Constraints

### Timer Mode (Critical)
```swift
// WRONG - Timer won't fire during drag operations
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { ... }

// CORRECT - Timer fires in all run loop modes including drag tracking
let timer = Timer(timeInterval: 0.25, repeats: true) { ... }
RunLoop.main.add(timer, forMode: .common)
```

During drag operations, the run loop is in `.eventTracking` mode. Default timers only fire in `.default` mode. Using `.common` mode ensures the timer fires in both modes.

### Cursor Coordinates
- `DropInfo.location` provides cursor position in the drop target's coordinate space
- Need `GeometryReader` to get viewport bounds for edge zone calculation
- Coordinates are relative to the view, not the screen

### State Isolation
- Autoscroll manager should be a class (not struct) to survive timer callbacks
- Use `@MainActor` for thread safety
- Weak references in timer callbacks to avoid retain cycles

## Design Token Candidates

```swift
// MARK: - Autoscroll (Thumbnail Drag)

static let autoscrollEdgeZone: CGFloat = 60        // Edge detection zone from viewport edge
static let autoscrollHysteresis: CGFloat = 10     // Buffer to prevent jitter at boundary
static let autoscrollDwellTime: Double = 0.075    // Delay before activation (75ms)
static let autoscrollMinInterval: Double = 0.1    // Fastest scroll speed (at edge)
static let autoscrollMaxInterval: Double = 0.4    // Slowest scroll speed (at zone boundary)
```

## Implementation Notes

### Pixel-Based vs Index-Based Detection

The previous attempt used index-based detection (dragToIndex proximity to visible range). PAG-35 requires pixel-based detection using actual cursor coordinates:

| Aspect | Index-Based (Previous) | Pixel-Based (Required) |
|--------|------------------------|------------------------|
| Detection | Cell position relative to visible range | Cursor Y coordinate vs viewport bounds |
| Speed | Constant | Variable based on edge proximity |
| Precision | Coarse (cell-level) | Fine (pixel-level) |

### Speed Ramp Calculation

```
distance = cursor distance from viewport edge
zoneSize = autoscrollEdgeZone

// Linear interpolation
t = clamp(distance / zoneSize, 0, 1)
interval = autoscrollMinInterval + t * (autoscrollMaxInterval - autoscrollMinInterval)
```

Closer to edge = smaller interval = faster scrolling.

## References

- [PAG-35 Linear Issue](https://linear.app/...)
- `docs/features/PAG35-approaches-attempted.md` - Previous implementation attempts
