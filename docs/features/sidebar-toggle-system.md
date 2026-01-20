# Sidebar Toggle System

The sidebar toggle system manages visibility of the outline/thumbnails sidebar via keyboard shortcuts and toolbar buttons.

---

## Overview

| Component | File | Purpose |
|-----------|------|---------|
| TabManager | `Managers/TabManager.swift` | Per-tab state storage |
| MainView | `Views/MainView.swift` | State consumption & rendering |
| PageFlowApp | `PageFlowApp.swift` | Keyboard shortcut commands |
| FloatingToolbar | `Views/FloatingToolbar.swift` | Toolbar toggle button |
| SidebarView | `Views/SidebarView.swift` | Actual sidebar UI |

---

## Architecture

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                      Command Sources                             │
├─────────────────┬─────────────────┬─────────────────────────────┤
│ Keyboard        │ Toolbar         │ Close Button                │
│ Cmd+Option+S    │ Button          │ in SidebarView              │
└────────┬────────┴────────┬────────┴──────────┬──────────────────┘
         │                 │                   │
         ▼                 │                   │
┌─────────────────┐        │                   │
│ PageFlowApp     │        │                   │
│ @FocusedValue   │        │                   │
│ focusedTabManager        │                   │
└────────┬────────┘        │                   │
         │                 │                   │
         ▼                 ▼                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                    TabManager (@Observable)                      │
├─────────────────────────────────────────────────────────────────┤
│ showingOutline (computed) ──► showingOutlineState [UUID: Bool]  │
└────────────────────────────────┬────────────────────────────────┘
                                 │ @Observable notification
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                         MainView                                 │
├─────────────────────────────────────────────────────────────────┤
│ @Binding showingOutline ──► if showingOutline ──► SidebarView   │
└─────────────────────────────────────────────────────────────────┘
```

### State Storage

TabManager stores per-tab sidebar state in dictionaries:

```swift
// TabManager.swift
var showingOutlineState: [UUID: Bool] = [:]
var showingCommentsState: [UUID: Bool] = [:]
```

Active tab accessors (used by keyboard shortcuts):

```swift
// TabManager.swift
var showingOutline: Bool {
    get {
        guard let id = activeTabID else { return false }
        return showingOutlineState[id] ?? false
    }
    set {
        guard let id = activeTabID else { return }
        showingOutlineState[id] = newValue
    }
}
```

---

## Critical Bug Fix (PAG-25)

### The Problem

Keyboard shortcut Cmd+Option+S only worked once, then stopped responding.

### Root Cause

Reading `@Observable` state in PageFlowApp's computed property caused Scene body re-evaluation, which recreated TabContainerView and destroyed the TabManager instance.

**Broken Pattern:**
```swift
// PageFlowApp.swift - BROKEN
private var showingSidebarLabel: String {
    (focusedTabManager?.showingOutline == true) ? "Hide Sidebar" : "Show Sidebar"
}
```

**What happened:**
1. User presses Cmd+Option+S
2. `showingOutline` changes to `true`
3. `showingSidebarLabel` depends on `focusedTabManager?.showingOutline`
4. SwiftUI detects dependency change, invalidates PageFlowApp body
5. PageFlowApp body re-evaluates
6. `WindowGroup { TabContainerView(...) }` recreates content
7. TabContainerView's `@State tabManager` is recreated (NEW instance)
8. Old TabManager is deallocated
9. `@FocusedValue` still references the OLD destroyed TabManager
10. Next keyboard shortcut fails silently

### The Fix

Make the label static to avoid @Observable dependency:

```swift
// PageFlowApp.swift - FIXED
private var showingSidebarLabel: String {
    "Toggle Sidebar"  // Static - no @Observable dependency
}
```

### Key Lesson

**Never read @Observable state in Scene body computed properties** if that state will change frequently. The Scene body re-evaluation can cascade into view recreation that destroys instances referenced by @FocusedValue.

---

## Toggle Flow

### Keyboard Shortcut (Cmd+Option+S)

```
1. User presses Cmd+Option+S
2. PageFlowApp receives via .keyboardShortcut("s", modifiers: [.command, .option])
3. Button action: focusedTabManager?.showingOutline.toggle()
4. TabManager.showingOutline.set() writes to showingOutlineState[activeTabID]
5. @Observable notifies observers
6. MainView's @Binding showingOutline reflects the change
7. SwiftUI re-renders, sidebar appears/disappears
8. .animation(value: showingOutline) animates the transition
```

### Toolbar Button

```
1. User clicks sidebar button in FloatingToolbar
2. Button action: showingOutline.toggle()
3. Binding propagates to TabManager.showingOutlineState
4. Same notification/render flow as keyboard shortcut
```

---

## Files Reference

### TabManager.swift

| Element | Purpose |
|---------|---------|
| `showingOutlineState` | Per-tab dictionary storage `[UUID: Bool]` |
| `showingOutline` | Active tab computed property for keyboard shortcuts |

### TabContainerView.swift

| Element | Purpose |
|---------|---------|
| `showingOutlineBinding(for:)` | Creates Binding for specific tab |

### MainView.swift

| Element | Purpose |
|---------|---------|
| `@Binding var showingOutline` | Receives binding from TabContainerView |
| Sidebar overlay | Conditional rendering with `.topLeading` alignment |
| `.animation(value:)` | Animates sidebar transitions |

### PageFlowApp.swift

| Element | Purpose |
|---------|---------|
| `showingSidebarLabel` | Static "Toggle Sidebar" (must NOT read @Observable state) |
| Sidebar toggle button | Keyboard shortcut Cmd+Option+S |

### FloatingToolbar.swift

| Element | Purpose |
|---------|---------|
| `@Binding var showingOutline` | Receives binding from MainView |
| Sidebar button | Toggle button in toolbar |

---

## Comparison: Working Patterns

| Feature | Pattern | Works? |
|---------|---------|--------|
| Go To Page | `.sheet(isPresented:)` with Binding | ✅ |
| Search | `@State` in TabContainerView, passed as `@Binding` | ✅ |
| Toolbar | `@State` in TabContainerView, passed as `@Binding` | ✅ |
| Sidebar | Dictionary in TabManager, static label in PageFlowApp | ✅ |
| Comments | Dictionary in TabManager, dynamic label (different timing) | ✅ |

---

## Animation Strategy

Animation is applied at the **view level**, not wrapped around state changes:

```swift
// MainView.swift - correct pattern
.overlay(alignment: .topLeading) {
    if showingOutline, pdfManager.hasDocument {
        SidebarView(...)
            .transition(.move(edge: .leading).combined(with: .opacity))
    }
}
.animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline)
```

This ensures animation works regardless of how the state is changed (keyboard, toolbar, or programmatic).

---

## Keyboard Shortcuts

| Shortcut | Action | Notes |
|----------|--------|-------|
| Cmd+Option+S | Toggle sidebar | Label is static "Toggle Sidebar" |
| Cmd+Option+E | Toggle comments | Label is dynamic (works due to different timing) |
| Cmd+G | Toggle Go To Page | Uses `.sheet(isPresented:)` |
| Cmd+F | Toggle search | Uses `@State` binding pattern |
