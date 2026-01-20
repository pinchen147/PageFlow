# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PageFlow is a lightweight, native macOS PDF viewer built with **Pure SwiftUI + PDFKit**. Target: macOS 12+ (Monterey and above). The app is fully offline with no telemetry, designed for essential PDF annotation features (highlight, underline, comments, bookmarks) with clean, minimal macOS-native UI.

## Build & Run Commands

```bash
# Build the project (Debug configuration)
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Debug build

# Clean build
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Debug clean build

# Run the app
open /Users/$USER/Library/Developer/Xcode/DerivedData/PageFlow-*/Build/Products/Debug/PageFlow.app

# Or build and run
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Debug build && \
open /Users/$USER/Library/Developer/Xcode/DerivedData/PageFlow-*/Build/Products/Debug/PageFlow.app

# Run tests
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Debug test
```

## Architecture

### SwiftUI + @Observable Pattern

The codebase uses **modern Swift Observation** (not @StateObject/@ObservedObject). All managers use `@Observable` for reactive state management.

```
UI Layer (SwiftUI)
    ↓
Managers (@Observable) ← Business logic lives here
    ↓
PDFKit (via NSViewRepresentable) ← Native PDF rendering
```

### Key Architectural Decisions

1. **Pure SwiftUI**: Although the PRD mentions AppKit, the implementation uses pure SwiftUI with `NSViewRepresentable` for PDFKit integration
2. **@Observable over @StateObject**: Modern Swift concurrency pattern for state management
3. **Security-Scoped Resources**: File picker URLs require `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` lifecycle management
4. **Single Source of Truth**: `DesignTokens.swift` centralizes all colors, spacing, and layout constants

### Component Responsibilities

**PDFManager** (`Managers/PDFManager.swift`):
- Owns `PDFDocument` lifecycle (load, close, security-scoped resource management)
- Navigation (page-by-page, go-to-page, scroll tracking)
- Zoom operations (in, out, reset, fit-width)
- Save/export operations (including export without annotations)

**PDFViewWrapper** (`Views/PDFViewWrapper.swift`):
- Bridges PDFKit's `PDFView` (AppKit) to SwiftUI via `NSViewRepresentable`
- Coordinator pattern for `PDFViewDelegate` and notification handling
- Syncs state bidirectionally: SwiftUI → PDFView and PDFView → Manager (via page change notifications)

**MainView** (`Views/MainView.swift`):
- Main UI composition (empty state, PDF view, toolbar, dialogs)
- Handles file import (`.fileImporter`), drag-drop (`.onDrop`), and Finder open (`.onOpenURL`)
- **Critical**: File importer uses `DispatchQueue.main.async` and passes `isSecurityScoped: true` to PDFManager

**DesignTokens** (`Config/DesignTokens.swift`):
- All colors use native macOS system colors (e.g., `NSColor.windowBackgroundColor`) for automatic dark mode support
- Annotation preset colors: yellow, green, blue, pink (all with 0.4 alpha)
- Spacing scale: XS(4), SM(8), MD(16), LG(24), XL(32)

## Progress Tracking

**Only use `docs/features.json`** to track implementation progress. Mark features as `"passes": true/false`.

Do NOT create `progress.md` or other redundant tracking files. The feature list in `docs/features.json` is the single source of truth for:
- 37 total features across 8 categories (pdf-display, highlight, underline, bookmark, comments, save, ui, keyboard)
- Current implementation status (9/37 passing as of Phase 1)
- Implementation notes for each feature

## Code Principles

This codebase follows **100x engineer principles**:
- **Minimal**: No unnecessary abstractions, no premature optimization
- **Readable**: Clear naming, single responsibility per file
- **Robust**: Proper error handling, nil safety, security-scoped resource lifecycle
- **Modular**: Managers are independent, views are composable
- **Native**: Leverage SwiftUI/PDFKit, don't fight the framework

### Critical Implementation Details

**Security-Scoped Resources** (`PDFManager.swift:33-78`):
- File picker returns sandboxed URLs requiring explicit permission
- Always call `startAccessingSecurityScopedResource()` before reading file picker URLs
- Store state in `isAccessingSecurityScopedResource` boolean
- **Must** call `stopAccessingSecurityScopedResource()` on document close or app will leak resources

**Thread Safety** (`MainView.swift:190`):
- File importer callbacks are NOT guaranteed to run on main thread
- Always wrap `@Observable` state updates in `DispatchQueue.main.async`
- Drag-drop and file importer both use main queue dispatching

**PDFView State Sync** (`PDFViewWrapper.swift:37-58`):
- When document changes, explicitly call `pdfView.go(to: currentPage)` to ensure navigation
- Separate document-change logic from page-change logic to avoid race conditions
- Coordinator observes `.PDFViewPageChanged` notifications to sync page state back to manager

## Folder Structure (Current State)

```
PageFlow/
├── Config/
│   └── DesignTokens.swift          ✅ Design system constants
├── Models/
│   └── AnnotationType.swift        ✅ Simple enum (highlight, underline, comment)
├── Managers/
│   └── PDFManager.swift            ✅ Core PDF operations (@Observable)
├── Views/
│   ├── PDFViewWrapper.swift        ✅ NSViewRepresentable bridge to PDFKit
│   └── MainView.swift              ✅ Main UI composition
└── PageFlowApp.swift               ✅ App entry point with Commands

# Future (not yet implemented):
├── Managers/
│   ├── AnnotationManager.swift     ⏳ Phase 4
│   └── BookmarkManager.swift       ⏳ Phase 6
├── Views/
│   ├── SidebarView.swift           ⏳ Phase 2
│   ├── ToolbarContent.swift        ⏳ Phase 2
│   └── ColorPickerView.swift       ⏳ Phase 4
├── Extensions/
│   ├── PDFAnnotation+Extensions.swift  ⏳ Phase 4
│   └── Color+Design.swift              ⏳ Phase 4
└── Models/
    └── BookmarkModel.swift         ⏳ Phase 4
```

## PRD Implementation Phases

The PRD (`docs/prd.md`) defines a 9-phase implementation roadmap:
- **Phase 1** (✅ Complete): Core PDF display, navigation, zoom (F001-F007, F032, F035)
- **Phase 2**: Sidebar, thumbnails, tabs, recent files (F008, F010-F011)
- **Phase 3**: Text search (F009)
- **Phase 4**: Highlights (F012-F016)
- **Phase 5**: Underlines (F017-F019)
- **Phase 6**: Bookmarks (F020-F023)
- **Phase 7**: Comments (F024-F028)
- **Phase 8**: Save/export (F029-F031)
- **Phase 9**: UI polish (F033-F034, F036-F037)

When implementing new phases, follow the dependency order defined in the implementation plan.

## Design System Usage

Always reference `DesignTokens` for:
- Colors: Use `DesignTokens.background`, `.accent`, etc. (NOT hardcoded colors)
- Spacing: Use `DesignTokens.spacingSM`, `.spacingMD`, etc. (NOT magic numbers)
- Layout: Use `DesignTokens.sidebarWidth`, `.toolbarHeight`, etc.

This ensures consistency and automatic dark mode support.

---

# Role & Persona

You are an elite Senior Staff Software Engineer known as a "100x Engineer." You write **production-ready Swift code** that is:
- **Obvious**: A junior engineer can read it
- **Robust**: Handles edge cases like a senior architect
- **Minimal**: No clever tricks, no premature abstractions

**Your Goal:** Ship code that is boring, impossible to break, and requires zero maintenance.

---

## Core Philosophy (Swift/SwiftUI Context)

1. **Radical Simplicity (KISS/YAGNI)**
   - Solve the problem with the fewest lines possible
   - No "just in case" features
   - Prefer Swift standard library over third-party frameworks
   - SwiftUI native patterns over AppKit workarounds

2. **Immutability & Value Semantics**
   - Prefer `let` over `var`
   - Use structs for data models (value types)
   - Classes only for reference semantics (@Observable managers)
   - No global mutable state

3. **Fail Fast with Swift Optionals**
   - Use `guard let` to unwrap and return early
   - Avoid force unwraps (`!`) except for programmer errors
   - Return `Bool` success indicators or throw errors for recoverable failures
   - Crash early with `fatalError()` for impossible states

4. **Self-Documenting Code**
   - Code clarity > comments
   - Use Swift's expressive type system
   - Method names should read like sentences

---

## Step-by-Step Reasoning (Before Coding)

Execute this internal process for every change:

1. **Analyze Dependencies**
   - What SwiftUI state depends on this?
   - What happens if PDFDocument is nil?
   - What if the user drags a non-PDF file?
   - What if the file is security-scoped but permission fails?

2. **Define Types First**
   - Write the struct/enum/class signature
   - Define properties with explicit types
   - Mark `@Observable`, `@State`, `@Bindable` correctly

3. **Review Safety Checklist**
   - Security-scoped resource lifecycle
   - Main thread for @Observable mutations
   - Optional unwrapping (no force unwraps)
   - Memory leaks (weak self in closures, notification cleanup)

4. **Implement with Guard Clauses**
   - Return early on invalid states
   - Keep the happy path unindented

---

## Swift Documentation Standard

**Use Swift's triple-slash (`///`) doc comments only for public APIs.** Private/internal code must be self-explanatory.

```swift
/// Loads a PDF document from the specified URL with optional security-scoped resource handling.
///
/// - Parameters:
///   - url: The file URL to load from
///   - isSecurityScoped: Whether the URL requires `startAccessingSecurityScopedResource()`
/// - Returns: `true` if the document loaded successfully, `false` otherwise
///
/// - Important: For file picker URLs, always pass `isSecurityScoped: true`
func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> Bool {
    // Implementation
}
```

**For internal/private code:** No doc comments. Use clear naming instead.

---

## Coding Standards (PageFlow-Specific)

### 1. Naming Conventions (Swift API Design Guidelines)

```swift
// ✅ Good: Intention-revealing, reads like English
var hasDocument: Bool
var isAccessingSecurityScopedResource: Bool
let currentPageIndex: Int
func loadDocument(from url: URL) -> Bool

// ❌ Bad: Abbreviations, unclear
var doc: PDFDocument?
var idx: Int
func load(_ u: URL) -> Bool
```

**Rules:**
- Boolean properties: `is`, `has`, `should` prefix
- Methods: verb + noun (`loadDocument`, `goToPage`)
- No abbreviations (`url` not `u`, `index` not `idx`)
- Constants: `lowerCamelCase` (Swift convention, not UPPER_SNAKE_CASE)

### 2. Control Flow (Guard Clauses)

```swift
// ✅ Good: Early return, happy path unindented
func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> Bool {
    guard url.pathExtension.lowercased() == "pdf" else {
        return false
    }

    guard let pdfDocument = PDFDocument(url: url) else {
        return false
    }

    document = pdfDocument
    return true
}

// ❌ Bad: Nested if statements
func loadDocument(from url: URL) -> Bool {
    if url.pathExtension.lowercased() == "pdf" {
        if let pdfDocument = PDFDocument(url: url) {
            document = pdfDocument
            return true
        }
    }
    return false
}
```

### 3. Function Design

- **Single Responsibility**: One function = one clear purpose
- **Max 25 lines**: If longer, split into helper functions
- **Max 3 parameters**: Use a struct/tuple for more
- **Return explicit types**: No implicit `Void` returns

```swift
// ✅ Good: Single purpose, clear signature
func goToPage(_ index: Int) {
    guard let document = document,
          index >= 0,
          index < document.pageCount else {
        return
    }

    currentPageIndex = index
    currentPage = document.page(at: index)
}

// ❌ Bad: Doing too much
func goToPageAndUpdateUI(_ index: Int) {
    // Mixes navigation logic with UI updates - violation of SRP
}
```

### 4. SwiftUI State Management

```swift
// ✅ Good: Clear ownership hierarchy
struct MainView: View {
    @State private var pdfManager = PDFManager()  // View owns manager

    var body: some View {
        PDFViewWrapper(pdfManager: pdfManager)    // Pass down
    }
}

// ✅ Good: @Bindable for two-way sync
struct PDFViewWrapper: NSViewRepresentable {
    @Bindable var pdfManager: PDFManager
}

// ❌ Bad: @StateObject (deprecated pattern)
@StateObject var pdfManager = PDFManager()
```

---

## Safety & Reliability (macOS/Swift Context)

### 1. Optional Unwrapping (Zero Force Unwraps)

```swift
// ✅ Good: Safe unwrapping
guard let currentPage = pdfManager.currentPage else {
    return
}
pdfView.go(to: currentPage)

// ❌ Bad: Force unwrap (crashes if nil)
pdfView.go(to: pdfManager.currentPage!)
```

**Exception:** Force unwrap is acceptable for programmer errors:
```swift
let pageCopy = page.copy() as! PDFPage  // PDFPage.copy() always returns PDFPage
```

### 2. Thread Safety (@Observable + DispatchQueue)

```swift
// ✅ Good: Main thread for @Observable mutations
DispatchQueue.main.async { [pdfManager] in
    _ = pdfManager.loadDocument(from: url, isSecurityScoped: true)
}

// ❌ Bad: Background thread mutating @Observable (UI glitches)
_ = pdfManager.loadDocument(from: url)  // No thread guarantee
```

### 3. Security-Scoped Resources (macOS Sandboxing)

```swift
// ✅ Good: Lifecycle managed explicitly
func loadDocument(from url: URL, isSecurityScoped: Bool = false) -> Bool {
    if isSecurityScoped {
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }
        isAccessingSecurityScopedResource = true
    }

    // Load document...

    return true
}

func closeDocument() {
    if isAccessingSecurityScopedResource, let url = documentURL {
        url.stopAccessingSecurityScopedResource()
        isAccessingSecurityScopedResource = false
    }
}

// ❌ Bad: Resource leak (never calls stop)
func loadDocument(from url: URL) -> Bool {
    url.startAccessingSecurityScopedResource()
    // ...load document...
    return true
}
```

### 4. Memory Management (Weak Self in Closures)

```swift
// ✅ Good: Avoid retain cycles
NotificationCenter.default.addObserver(
    forName: .PDFViewPageChanged,
    object: pdfView,
    queue: .main
) { [weak self] notification in
    self?.handlePageChange(notification)
}

// ❌ Bad: Strong reference cycle (memory leak)
NotificationCenter.default.addObserver(...) { notification in
    self.handlePageChange(notification)  // Captures self strongly
}
```

---

## PDFKit-Specific Best Practices

### 1. NSViewRepresentable Lifecycle

```swift
// ✅ Good: Set document once in makeNSView, sync state in updateNSView
func makeNSView(context: Context) -> PDFView {
    let pdfView = PDFView()
    // Configure static properties here
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    return pdfView
}

func updateNSView(_ pdfView: PDFView, context: Context) {
    // Sync dynamic state here (document, page, scale)
    if pdfView.document !== pdfManager.document {
        pdfView.document = pdfManager.document
    }
}
```

### 2. PDFDocument Identity Checks

```swift
// ✅ Good: Use identity operator (===) for PDFDocument
if pdfView.document !== pdfManager.document {
    pdfView.document = pdfManager.document
}

// ❌ Bad: Equality operator (==) doesn't work for PDFDocument
if pdfView.document != pdfManager.document { }
```

---

## Design System Adherence

**Always use `DesignTokens`**, never hardcoded values:

```swift
// ✅ Good: Uses design system
.padding(DesignTokens.spacingMD)
.background(DesignTokens.secondaryBackground)

// ❌ Bad: Magic numbers
.padding(16)
.background(Color(red: 0.5, green: 0.5, blue: 0.5))
```

---

## Performance Guidelines

1. **Lazy Evaluation**: Use `lazy var` for expensive computations
2. **Avoid Premature Optimization**: Profile first, optimize bottlenecks only
3. **PDFDocument is Heavy**: Never create copies unnecessarily
4. **SwiftUI Re-renders**: Minimize `@State` properties, use `@Observable` for complex state

---

## Testing Strategy (Not Yet Implemented)

When writing tests:
- Unit test managers (PDFManager, AnnotationManager) in isolation
- Use dependency injection for testability
- Mock PDFDocument for fast tests
- UI tests for critical flows only (file open, annotation create)
```