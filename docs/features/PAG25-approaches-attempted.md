# PAG-25: Sidebar Toggle Keyboard Shortcut - Approaches Attempted

## Issue
Cmd+Option+S keyboard shortcut for toggling sidebar only works once, then stops responding.

---

## Approach 1: Complex FocusedValue Bindings
**Status:** ❌ Failed

Added separate FocusedValue keys for `showingOutline` and `showingComments`:
```swift
// FocusedValues.swift
private struct FocusedShowingOutlineKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

// TabContainerView.swift
private var showingOutlineBinding: Binding<Bool> {
    Binding(get: { tabManager.showingOutline }, set: { tabManager.showingOutline = $0 })
}
.focusedSceneValue(\.showingOutline, showingOutlineBinding)

// PageFlowApp.swift
@FocusedValue(\.showingOutline) private var focusedShowingOutline
focusedShowingOutline?.wrappedValue.toggle()
```

**Why it failed:** Computed Binding properties create NEW Binding objects each render. SwiftUI can't track identity across renders.

---

## Approach 2: Direct Dictionary Access
**Status:** ❌ Failed

Changed MainView to access TabManager's dictionary directly instead of through tuple-returning function:
```swift
// Before (broken)
private var showingOutline: Bool {
    get { tabManager.sidebarState(for: tabID).showingOutline }
}

// After (still broken)
private var showingOutline: Bool {
    get { tabManager.showingOutlineState[tabID] ?? false }
}
```

**Why it failed:** Even with direct dictionary access, @Observable tracking through computed properties in a different view doesn't trigger re-renders reliably.

---

## Approach 3: Simplified Toggle Pattern
**Status:** ❌ Failed (for sidebar)

Removed `withAnimation` wrapper from toggle actions to match working Go To Page pattern:
```swift
// PageFlowApp.swift
Button(showingSidebarLabel) {
    focusedTabManager?.showingOutline.toggle()  // No withAnimation
}
```

Added `.animation(value:)` modifier to view instead:
```swift
// MainView.swift
.animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline)
```

**Why it failed:** The issue isn't animation - it's that state changes don't trigger view updates.

---

## Key Observations

### Working Patterns
| Feature | State Location | Access Pattern | Works |
|---------|---------------|----------------|-------|
| Search | `@State` in TabContainerView | Direct Binding via focusedSceneValue | ✅ |
| Toolbar | `@State` in TabContainerView | Direct Binding via focusedSceneValue | ✅ |
| Go To Page | Dictionary in TabManager | `.sheet(isPresented:)` binding | ✅ |

### Broken Pattern
| Feature | State Location | Access Pattern | Works |
|---------|---------------|----------------|-------|
| Sidebar | Dictionary in TabManager | Computed property in MainView body | ❌ |

### Root Cause Hypothesis
The `.sheet(isPresented:)` modifier has special SwiftUI integration that properly observes Binding changes. The `if showingOutline` conditional in view body relies on @Observable tracking which breaks across the FocusedValue → TabManager → MainView chain.

---

---

## Approach 4: Pass Binding from TabContainerView to MainView
**Status:** ❌ Failed

Match the working search/toolbar pattern exactly:

**TabContainerView.swift:**
```swift
private func showingOutlineBinding(for tabID: UUID) -> Binding<Bool> {
    Binding(
        get: { tabManager.showingOutlineState[tabID] ?? false },
        set: { tabManager.showingOutlineState[tabID] = $0 }
    )
}

MainView(
    ...
    showingOutline: showingOutlineBinding(for: tab.id),
    showingComments: showingCommentsBinding(for: tab.id),
    ...
)
```

**MainView.swift:**
```swift
@Binding var showingOutline: Bool
@Binding var showingComments: Bool
```

**Why it failed:** Although MainView now receives @Binding, the keyboard shortcut in PageFlowApp still accesses `focusedTabManager?.showingOutline.toggle()` which goes through the @Observable TabManager. The FocusedValue → @Observable path is the bug.

---

## Approach 5: FocusedSceneValue with Binding<Bool> (Same as Search/Toolbar)
**Status:** ❌ Failed

**Root Cause Discovery:** Web search revealed a known bug - as of Xcode 15.2, `@FocusedValue` cannot properly observe `@Observable` instances.

**Why it failed:** Even with Binding<Bool> via FocusedSceneValue, MainView still used @Binding which doesn't establish @Observable observation. The Binding's value changes but MainView doesn't re-render because it doesn't observe the underlying TabManager dictionary.

---

## Approach 6: MainView reads directly from TabManager
**Status:** ❌ Failed (Partial)

**Key insight:** The issue is that MainView doesn't observe TabManager's dictionary. When using `@Binding var showingOutline`, MainView reads from the Binding, not from TabManager, so no @Observable observation is established.

**Solution:** MainView uses a computed property that reads directly from TabManager, establishing @Observable observation.

**MainView.swift:**
```swift
// Remove @Binding, use computed property instead
private var showingOutline: Bool {
    tabManager.showingOutlineState[tabID] ?? false
}

private var showingOutlineBinding: Binding<Bool> {
    Binding(
        get: { tabManager.showingOutlineState[tabID] ?? false },
        set: { tabManager.showingOutlineState[tabID] = $0 }
    )
}
```

**Why it partially failed:** MainView now correctly observes the dictionary, BUT the keyboard shortcut in PageFlowApp still goes through `@FocusedValue → @Observable`, which is the broken path. The toolbar button works (direct Binding mutation), but keyboard shortcut fails.

---

## Approach 7: NotificationCenter Workaround
**Status:** ❌ Failed

**Hypothesis:** Bypass the broken `@FocusedValue → @Observable` path entirely. Use `NotificationCenter` to signal the toggle, then have MainView handle it from within its own context where @Observable tracking should work.

**SaveNotifications.swift:**
```swift
extension Notification.Name {
    static let toggleSidebar = Notification.Name("ToggleSidebarNotification")
}
```

**PageFlowApp.swift:**
```swift
Button(showingSidebarLabel) {
    // Post notification instead of direct @Observable mutation
    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
}
.keyboardShortcut("s", modifiers: [.command, .option])
```

**MainView.swift:**
```swift
.onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
    // Check active tab directly instead of relying on isActive parameter
    let isActiveTab = tabManager.activeTabID == tabID
    guard isActiveTab, pdfManager.hasDocument else { return }
    let current = tabManager.showingOutlineState[tabID] ?? false
    withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
        tabManager.showingOutlineState[tabID] = !current
    }
}
```

**Why it failed:** Even though the notification is received and the state is mutated from within MainView's context, the @Observable tracking still doesn't trigger a re-render. The mutation happens but SwiftUI doesn't invalidate the view body.

**Variations tried:**
- Using `isActive` parameter vs checking `tabManager.activeTabID == tabID` directly
- With and without `withAnimation` wrapper
- With and without `DispatchQueue.main.async` deferral

---

## Summary: All Approaches Failed

The fundamental issue appears to be that **SwiftUI's @Observable macro does not reliably track dictionary property access** when:
1. The mutation originates from outside the observing view (even via NotificationCenter)
2. The state is accessed via computed property that reads from a dictionary
3. The conditional `if showingOutline` is inside a closure (like `.overlay`)

### What Works
- **Toolbar button**: Direct Binding mutation from child view (FloatingToolbar)
- **Go To Page**: Uses `.sheet(isPresented:)` which has special SwiftUI integration
- **Search/Toolbar toggle**: Uses `@State` in TabContainerView (not per-tab dictionary)

### What Doesn't Work
- Any approach that tries to toggle per-tab dictionary state via keyboard shortcut from PageFlowApp

### Potential Solutions Not Yet Tried
1. ~~**Move sidebar state to `@State` in TabContainerView**~~ - Tried in Approach 8, failed
2. **Use `.popover(isPresented:)` instead of conditional** - Might have same special integration as `.sheet()`
3. **Migrate away from @Observable** - Use ObservableObject with explicit `objectWillChange.send()`
4. **Force view identity change** - Use `.id()` modifier that changes when sidebar state changes

---

## Approach 8: @State in TabContainerView with Sync
**Status:** ❌ Failed

**Hypothesis:** Match exactly how `showingSearch` and `showingToolbar` work - use `@State` in TabContainerView exposed via `focusedSceneValue`, with `onChange` handlers to sync with per-tab dictionary.

**FocusedValues.swift:**
```swift
private struct FocusedShowingOutlineKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var showingOutline: Binding<Bool>? {
        get { self[FocusedShowingOutlineKey.self] }
        set { self[FocusedShowingOutlineKey.self] = newValue }
    }
}
```

**TabContainerView.swift:**
```swift
@State private var showingOutline = false  // Synced with per-tab dictionary

// In body:
.focusedSceneValue(\.showingOutline, $showingOutline)
// Sync @State with per-tab dictionary when keyboard shortcut toggles it
.onChange(of: showingOutline) { _, newValue in
    guard let activeID = tabManager.activeTabID else { return }
    if tabManager.showingOutlineState[activeID] != newValue {
        tabManager.showingOutlineState[activeID] = newValue
    }
}
// Sync @State from dictionary when active tab changes
.onChange(of: tabManager.activeTabID) { _, newActiveID in
    guard let newActiveID else { return }
    showingOutline = tabManager.showingOutlineState[newActiveID] ?? false
}
// Sync @State from dictionary when dictionary value changes (e.g., toolbar button)
.onChange(of: tabManager.showingOutlineState) { _, newState in
    guard let activeID = tabManager.activeTabID else { return }
    let newValue = newState[activeID] ?? false
    if showingOutline != newValue {
        showingOutline = newValue
    }
}
```

**PageFlowApp.swift:**
```swift
@FocusedValue(\.showingOutline) private var focusedShowingOutline

private var showingSidebarLabel: String {
    (focusedShowingOutline?.wrappedValue == true) ? "Hide Sidebar" : "Show Sidebar"
}

Button(showingSidebarLabel) {
    focusedShowingOutline?.wrappedValue.toggle()
}
.keyboardShortcut("s", modifiers: [.command, .option])
```

**Why it failed:** Even though this exactly mirrors the working `showingSearch` pattern:
- The @State toggles correctly in TabContainerView
- The onChange syncs it to the per-tab dictionary
- BUT MainView still doesn't re-render

The difference: `showingSearch` is passed directly to MainView as `@Binding var showingSearch`, while sidebar state is read via computed property from the dictionary. The @Observable dictionary tracking is still broken even when the mutation originates from @State sync.

**Key insight:** The problem isn't WHERE the mutation happens (PageFlowApp vs TabContainerView). The problem is that **MainView reads `showingOutline` via computed property from `tabManager.showingOutlineState[tabID]`**, and @Observable doesn't reliably track dictionary subscript access for view invalidation.

---

## Approach 9: Pass @Binding directly to MainView (Match showingSearch exactly)
**Status:** ❌ Failed

**Hypothesis:** The working `showingSearch` pattern passes `$showingSearch` directly from TabContainerView to MainView as `@Binding`. If we do the same for `showingOutline`, MainView should observe the Binding and re-render when it changes.

**MainView.swift:**
```swift
// Changed from computed property to @Binding
@Binding var showingOutline: Bool  // Passed from TabContainerView

// FloatingToolbar now uses $showingOutline directly
FloatingToolbar(
    ...
    showingOutline: $showingOutline,
    ...
)

// onClose uses binding
onClose: { showingOutline = false }
```

**TabContainerView.swift:**
```swift
@State private var showingOutline = false

MainView(
    ...
    showingOutline: $showingOutline,
    ...
)
```

**Why it failed:** Even with @Binding passed directly to MainView (exactly mirroring how `showingSearch` works), the keyboard shortcut still doesn't work after the first toggle. The state changes in TabContainerView's @State, but MainView doesn't re-render.

**Critical observation:** This is now IDENTICAL to how `showingSearch` works:
- `@State` in TabContainerView ✅
- Passed as `@Binding` to MainView ✅
- Exposed via `focusedSceneValue` ✅
- Keyboard shortcut toggles via `focusedShowingOutline?.wrappedValue.toggle()` ✅

Yet `showingSearch` works and `showingOutline` doesn't. The ONLY difference is:
- `showingSearch` controls `SearchPanel` visibility (rendered in a different location in view hierarchy)
- `showingOutline` controls `SidebarView` visibility (rendered inside `.overlay`)

**New hypothesis:** The issue may be related to how the sidebar is rendered inside `.overlay(alignment: .topLeading)`. The overlay closure might not be re-evaluated when the binding changes.

---

## Summary: 9 Approaches Failed

### Patterns Compared
| Feature | State Type | Passed As | View Location | Works |
|---------|-----------|-----------|---------------|-------|
| showingSearch | @State | @Binding | Body conditional | ✅ |
| showingToolbar | @State | @Binding | Body conditional | ✅ |
| showingOutline | @State | @Binding | `.overlay` closure | ❌ |

### Potential Solutions Not Yet Tried
1. **Move SidebarView outside of `.overlay`** - Render in main body like Search/Toolbar
2. **Use `.popover(isPresented:)` or `.sheet(isPresented:)`** - Has special SwiftUI binding observation
3. **Use `@ViewBuilder` conditional** - Instead of `if` inside overlay closure
4. **Force view identity with `.id()` modifier** - `id(showingOutline)` on parent view

---

## Approach 10: Clean @Binding Implementation (Match showingSearch exactly)
**Status:** ❌ Failed

**Hypothesis:** Previous Approach 9 may have had implementation issues. Re-implement cleanly ensuring `showingOutline` works **identically** to `showingSearch`:

**MainView.swift:**
```swift
// Parameter (same pattern as showingSearch)
@Binding var showingOutline: Bool
@Binding var showingComments: Bool
@Binding var showingSearch: Bool

// Removed computed property entirely
// (no more: private var showingOutline: Bool { tabManager.showingOutlineState[tabID] ?? false })

// All usages now use the binding directly
if showingOutline, pdfManager.hasDocument { ... }
onClose: { showingOutline = false }
showingOutline: $showingOutline  // to FloatingToolbar
```

**TabContainerView.swift:**
```swift
@State private var showingOutline = false

MainView(
    ...
    showingOutline: $showingOutline,  // Pass binding
    showingSearch: $showingSearch,
    ...
)

.focusedSceneValue(\.showingOutline, $showingOutline)

// onChange handlers sync with per-tab dictionary
.onChange(of: showingOutline) { ... }
.onChange(of: tabManager.activeTabID) { ... }
.onChange(of: tabManager.showingOutlineState) { ... }
```

**Why it failed:** Even with `showingOutline` implemented IDENTICALLY to `showingSearch`:
- Both are `@State` in TabContainerView ✅
- Both passed as `@Binding` to MainView ✅
- Both exposed via `focusedSceneValue` ✅
- Both toggled via `focusedValue?.wrappedValue.toggle()` ✅

Yet `showingSearch` works and `showingOutline` doesn't.

**Remaining differences:**
1. `showingSearch` → SearchBar in `.overlay(alignment: .bottom)`
2. `showingOutline` → SidebarView in `.overlay(alignment: .topLeading)`
3. `showingSearch` has no sync with per-tab dictionary (global per window)
4. `showingOutline` has onChange sync with per-tab dictionary

**New hypothesis:** The onChange handlers that sync showingOutline with the per-tab dictionary may be causing issues. When the binding changes, the onChange fires and writes to the dictionary, which may trigger another onChange, creating a feedback loop or race condition that prevents the view from updating correctly.

---

## Approach 11: Remove onChange Sync Handlers
**Status:** ❌ Failed

Removed all three onChange handlers from TabContainerView to make `showingOutline` 100% identical to `showingSearch`:

```swift
// BEFORE: Had 3 onChange handlers
.onChange(of: showingOutline) { ... }
.onChange(of: tabManager.activeTabID) { ... }
.onChange(of: tabManager.showingOutlineState) { ... }

// AFTER: No onChange handlers (same as showingSearch)
.focusedSceneValue(\.showingOutline, $showingOutline)
// That's it - no onChange handlers
```

**Why it failed:** Even with showingOutline implemented 100% identically to showingSearch (same @State, same @Binding, same focusedSceneValue, no onChange handlers), the keyboard shortcut still doesn't work after first toggle.

---

## Approach 12: Force View Identity with .id() Modifier
**Status:** ❌ Failed

Added `.id(showingOutline)` after the overlay to force SwiftUI to completely recreate the view when state changes:

```swift
.overlay(alignment: .topLeading) {
    if showingOutline, pdfManager.hasDocument {
        SidebarView(...)
    }
}
.id(showingOutline)  // Force view recreation
.animation(...)
```

**Why it failed:** The .id() modifier forces complete view recreation, bypassing SwiftUI's change detection. This should have worked if the issue was SwiftUI not detecting the state change. The fact that it didn't work suggests the binding itself is not being toggled after the first use.

---

## Summary: 12 Approaches Failed

**Critical insight from Approach 12:** The `.id()` modifier forces SwiftUI to recreate the view regardless of change detection. If the state was actually changing, the view would update. The fact that it doesn't suggests **the FocusedValue binding is becoming stale or nil after first use**.

---

## Approach 13: Toggle via TabManager Directly (Like showingComments)
**Status:** ❌ Failed

Made `showingOutline` work **exactly** like `showingComments`:

**PageFlowApp.swift:**
```swift
// Changed from FocusedValue binding to TabManager property
Button(showingSidebarLabel) {
    focusedTabManager?.showingOutline.toggle()  // Same as showingComments
}

private var showingSidebarLabel: String {
    (focusedTabManager?.showingOutline == true) ? "Hide Sidebar" : "Show Sidebar"
}
```

**TabContainerView.swift:**
```swift
// Removed @State showingOutline
// Added binding function (same as showingComments)
private func showingOutlineBinding(for tabID: UUID) -> Binding<Bool> {
    Binding(
        get: { tabManager.showingOutlineState[tabID] ?? false },
        set: { tabManager.showingOutlineState[tabID] = $0 }
    )
}

// Pass binding to MainView (same as showingComments)
MainView(
    showingOutline: showingOutlineBinding(for: tab.id),
    showingComments: showingCommentsBinding(for: tab.id),
    ...
)

// Removed focusedSceneValue for showingOutline
```

**TabManager already had:**
```swift
var showingOutline: Bool {
    get { showingOutlineState[activeTabID] ?? false }
    set { showingOutlineState[activeTabID] = newValue }
}
```

**Why it failed:** `showingOutline` is now implemented 100% identically to `showingComments`:
- Both toggle via `focusedTabManager?.property.toggle()`
- Both use computed properties in TabManager
- Both use binding functions in TabContainerView
- Both pass bindings to MainView

Yet `showingComments` works and `showingOutline` doesn't.

**The ONLY remaining difference is the VIEW itself:**
- `showingComments` → `CommentsSidebar` in `.overlay(alignment: .topTrailing)`
- `showingOutline` → `SidebarView` in `.overlay(alignment: .topLeading)`

---

## Summary: 13 Approaches Failed

At this point, `showingOutline` has been implemented identically to:
1. `showingSearch` (Approach 11) - Failed
2. `showingComments` (Approach 13) - Failed

The issue must be something specific to either:
1. **SidebarView itself** - Some internal state or behavior
2. **The overlay position** - `.topLeading` vs `.topTrailing` or `.bottom`
3. **The condition** - `if showingOutline, pdfManager.hasDocument`
4. **View hierarchy** - Something about where this overlay appears in the modifier chain

---

## Approach 14: Swap Overlay Order
**Status:** ❌ Failed

Swapped the order of overlays so showingComments comes BEFORE showingOutline in the modifier chain.

**Why it failed:** The position in the modifier chain doesn't affect the bug.

---

## Approach 15: Replace SidebarView with Simple Text
**Status:** ❌ Failed

Replace SidebarView with a simple `Text("SIDEBAR VISIBLE")` to isolate if the issue is SidebarView itself.

```swift
.overlay(alignment: .topLeading) {
    if showingOutline, pdfManager.hasDocument {
        Text("SIDEBAR VISIBLE")
            .padding()
            .background(Color.red)
            .padding(.top, 100)
            .padding(.leading, 20)
    }
}
```

**Why it failed:** Even a simple Text view shows once but doesn't toggle on subsequent Cmd+Option+S presses. This proves the issue is NOT in SidebarView itself.

**Critical insight:** The issue must be related to:
1. The `.topLeading` alignment specifically
2. Something about how this particular overlay is positioned in the view hierarchy
3. The combination of conditions used

---

## Approach 16: Change Overlay Alignment from .topLeading to .bottom
**Status:** ❌ Failed

Change the overlay alignment from `.topLeading` to `.bottom` to match the working `showingSearch` overlay.

**Why it failed:** Alignment doesn't matter. The red text appears at bottom but further Cmd+Option+S presses do nothing.

---

## Approach 17: Add Debug Prints to Trace State
**Status:** ✅ ROOT CAUSE FOUND

Add print statements to trace what's happening when the keyboard shortcut is pressed.

**Debug output revealed:**
```
[DEBUG] After toggle: showingOutline = true
[deinit] TabManager    <-- TABMANAGER IS BEING DESTROYED!
[deinit] PDFManager
[deinit] SearchManager
...
```

**ROOT CAUSE:** The TabManager is being **deallocated** immediately after the first toggle. When `showingOutline` changes, something causes the view hierarchy to recreate TabContainerView, which recreates its `@State private var tabManager`. The `@FocusedValue` then references a stale/deallocated TabManager.

This explains why:
- First press works (TabManager exists)
- Second press fails (TabManager was destroyed and recreated, but FocusedValue may reference old one)

**Why showingComments works:** It might not trigger the same view recreation pattern, or the timing is different.

---

## Approach 18: Make showingSidebarLabel Static
**Status:** ✅ SUCCESS

Instead of moving TabManager, the fix was simpler: make `showingSidebarLabel` NOT read from `focusedTabManager?.showingOutline`.

**The Bug:**
```swift
// BEFORE (broken) - causes PageFlowApp body re-evaluation on state change
private var showingSidebarLabel: String {
    (focusedTabManager?.showingOutline == true) ? "Hide Sidebar" : "Show Sidebar"
}
```

When `showingOutline` changes:
1. `focusedTabManager?.showingOutline` value changes
2. SwiftUI detects dependency in `showingSidebarLabel` computed property
3. PageFlowApp's body is invalidated and re-evaluated
4. WindowGroup recreates TabContainerView
5. TabContainerView's `@State tabManager` is recreated (NEW instance)
6. FocusedValue now references the OLD destroyed TabManager
7. Subsequent keyboard shortcuts fail

**The Fix:**
```swift
// AFTER (working) - no dependency on @Observable state
private var showingSidebarLabel: String {
    "Toggle Sidebar"
}
```

**Why This Works:**
- The label no longer depends on `focusedTabManager?.showingOutline`
- PageFlowApp's body is NOT re-evaluated when sidebar state changes
- TabManager instance remains stable
- FocusedValue continues to reference the same valid TabManager

**Why showingComments Worked:**
The `showingCommentsLabel` also reads from `focusedTabManager?.showingComments`, but it works because:
1. When comments toggle, the same body re-evaluation happens
2. BUT the CommentsSidebar uses a different code path that doesn't trigger the same cascade
3. The timing/order of SwiftUI's view identity resolution differs

---

# SOLUTION SUMMARY

## Root Cause
Reading `@Observable` state in a Scene body's computed property causes the Scene to re-evaluate on state change, which can recreate child views and their `@State`, destroying the instance that `@FocusedValue` references.

## Fix Applied
Changed `showingSidebarLabel` from dynamic ("Hide Sidebar"/"Show Sidebar") to static ("Toggle Sidebar").

## Files Modified
- `PageFlowApp.swift`: Made `showingSidebarLabel` return static string
- `MainView.swift`: Restored SidebarView (was replaced with test Text during debugging)
- `TabManager.swift`: Removed debug prints

## Lessons Learned
1. **Never read @Observable state in Scene body computed properties** if that state will change frequently
2. **@FocusedValue + @Observable** has a fragile interaction - the FocusedValue can reference stale/destroyed instances
3. **Debug prints in getters/setters** are invaluable for tracing state flow and identifying deallocation issues
4. **SwiftUI view identity** is subtle - seemingly innocuous computed properties can trigger cascading view recreations
