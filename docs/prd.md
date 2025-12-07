# PageFlow - Product Requirements Document

## Overview

**PageFlow** is a lightweight, native macOS PDF viewer built with Swift and PDFKit. It provides essential PDF annotation features (highlight, underline, comments, bookmarks) without the bloat of Adobe Acrobat. The design follows modern macOS Sequoia aesthetics—clean, minimal, and native.

**Target:** macOS 12 Monterey and above  
**Tech Stack:** Swift, PDFKit, Cocoa/AppKit  
**Distribution:** Direct download from website (one-time license fee)  
**Privacy:** Fully offline, no telemetry

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         PageFlow.app                            │
├─────────────────────────────────────────────────────────────────┤
│  UI Layer (AppKit/SwiftUI)                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │
│  │  MainWindow  │ │   Toolbar    │ │   Sidebar    │            │
│  │  Controller  │ │  (Annotate)  │ │ (Thumbnails/ │            │
│  │              │ │              │ │  Bookmarks)  │            │
│  └──────────────┘ └──────────────┘ └──────────────┘            │
├─────────────────────────────────────────────────────────────────┤
│  Core Layer                                                     │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │
│  │  PDFView     │ │  Annotation  │ │   Bookmark   │            │
│  │  Manager     │ │   Manager    │ │   Manager    │            │
│  └──────────────┘ └──────────────┘ └──────────────┘            │
├─────────────────────────────────────────────────────────────────┤
│  Data Layer                                                     │
│  ┌──────────────┐ ┌──────────────┐                             │
│  │   PDFKit     │ │  UserDefaults│                             │
│  │  (Native)    │ │  (Prefs)     │                             │
│  └──────────────┘ └──────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
PageFlow/
├── PageFlow.xcodeproj
├── PageFlow/
│   ├── App/
│   │   ├── PageFlowApp.swift
│   │   └── AppDelegate.swift
│   ├── Views/
│   │   ├── MainWindowController.swift
│   │   ├── PDFViewerView.swift
│   │   ├── ToolbarView.swift
│   │   ├── SidebarView.swift
│   │   └── ColorPickerView.swift
│   ├── Models/
│   │   ├── AnnotationType.swift
│   │   └── BookmarkModel.swift
│   ├── Managers/
│   │   ├── PDFManager.swift
│   │   ├── AnnotationManager.swift
│   │   └── BookmarkManager.swift
│   ├── Extensions/
│   │   ├── PDFAnnotation+Extensions.swift
│   │   └── NSColor+RGB.swift
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Main.storyboard (optional)
│   └── Config/
│       └── DesignTokens.swift
├── PageFlowTests/
├── features.json
├── progress.md
└── init.sh
```

---

## Design System

```swift
// DesignTokens.swift - Single source of truth

struct DesignTokens {
    // Colors - macOS Sequoia native
    static let background = NSColor.windowBackgroundColor
    static let secondaryBackground = NSColor.controlBackgroundColor
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let accent = NSColor.controlAccentColor
    static let separator = NSColor.separatorColor
    
    // Default annotation colors
    static let highlightYellow = NSColor(red: 1.0, green: 0.95, blue: 0.0, alpha: 0.4)
    static let highlightGreen = NSColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 0.4)
    static let highlightBlue = NSColor(red: 0.0, green: 0.5, blue: 1.0, alpha: 0.4)
    static let highlightPink = NSColor(red: 1.0, green: 0.0, blue: 0.5, alpha: 0.4)
    static let underlineColor = NSColor.black
    
    // Spacing
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32
    
    // Sidebar
    static let sidebarWidth: CGFloat = 200
    static let thumbnailWidth: CGFloat = 120
    
    // Toolbar
    static let toolbarHeight: CGFloat = 38
    
    // Animation
    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.25
}
```

**Design Principles:**
- Use native macOS controls (NSToolbar, NSSplitView, NSOutlineView)
- Follow Apple Human Interface Guidelines
- No custom chrome—rely on system window decorations
- Minimal iconography using SF Symbols
- Respect system appearance (light/dark mode)

---

## Feature List

```json
{
  "project": "PageFlow",
  "version": "1.0.0",
  "features": [
    {
      "id": "F001",
      "category": "pdf-display",
      "description": "Open PDF file via File > Open menu",
      "steps": [
        "Click File > Open from menu bar",
        "Select a PDF file from file picker",
        "PDF renders in main view area",
        "Page count displays in toolbar"
      ],
      "passes": false
    },
    {
      "id": "F002",
      "category": "pdf-display",
      "description": "Open PDF file via drag and drop",
      "steps": [
        "Drag PDF file onto app window",
        "PDF renders in main view area",
        "File name appears in window title"
      ],
      "passes": false
    },
    {
      "id": "F003",
      "category": "pdf-display",
      "description": "Open PDF file via double-click in Finder",
      "steps": [
        "Set PageFlow as default PDF handler",
        "Double-click PDF in Finder",
        "PageFlow opens with PDF loaded"
      ],
      "passes": false
    },
    {
      "id": "F004",
      "category": "pdf-display",
      "description": "Navigate pages using scroll",
      "steps": [
        "Open multi-page PDF",
        "Scroll down with trackpad/mouse",
        "Pages transition smoothly",
        "Current page indicator updates"
      ],
      "passes": false
    },
    {
      "id": "F005",
      "category": "pdf-display",
      "description": "Navigate pages using keyboard",
      "steps": [
        "Open multi-page PDF",
        "Press Page Down or Down Arrow",
        "View advances to next page",
        "Press Page Up or Up Arrow",
        "View returns to previous page"
      ],
      "passes": false
    },
    {
      "id": "F006",
      "category": "pdf-display",
      "description": "Go to specific page number",
      "steps": [
        "Open multi-page PDF",
        "Press Cmd+G or click page indicator",
        "Enter page number in dialog",
        "View jumps to specified page"
      ],
      "passes": false
    },
    {
      "id": "F007",
      "category": "pdf-display",
      "description": "Zoom in and out",
      "steps": [
        "Open PDF",
        "Press Cmd++ to zoom in",
        "PDF renders larger",
        "Press Cmd+- to zoom out",
        "PDF renders smaller",
        "Press Cmd+0 to fit width"
      ],
      "passes": false
    },
    {
      "id": "F008",
      "category": "pdf-display",
      "description": "Display thumbnail sidebar",
      "steps": [
        "Open PDF",
        "Press Cmd+Shift+T or View > Thumbnails",
        "Sidebar appears with page thumbnails",
        "Click thumbnail to navigate to page",
        "Toggle hides sidebar"
      ],
      "passes": false
    },
    {
      "id": "F009",
      "category": "pdf-display",
      "description": "Search text within PDF",
      "steps": [
        "Open PDF",
        "Press Cmd+F",
        "Search bar appears",
        "Type search term",
        "Matching results highlighted",
        "Navigate between results with Enter/Shift+Enter"
      ],
      "passes": false
    },
    {
      "id": "F010",
      "category": "pdf-display",
      "description": "Open multiple PDFs in tabs",
      "steps": [
        "Open first PDF",
        "Press Cmd+T for new tab",
        "Open second PDF in new tab",
        "Click tabs to switch between documents"
      ],
      "passes": false
    },
    {
      "id": "F011",
      "category": "pdf-display",
      "description": "Remember recently opened files",
      "steps": [
        "Open several PDFs",
        "Quit and reopen app",
        "File > Open Recent shows previously opened files",
        "Click recent file to reopen"
      ],
      "passes": false
    },
    {
      "id": "F012",
      "category": "highlight",
      "description": "Highlight selected text with default color",
      "steps": [
        "Open PDF with selectable text",
        "Select text by clicking and dragging",
        "Press Cmd+H or click highlight button",
        "Text is highlighted in yellow (default)"
      ],
      "passes": false
    },
    {
      "id": "F013",
      "category": "highlight",
      "description": "Highlight with custom color via preset",
      "steps": [
        "Select text in PDF",
        "Click highlight dropdown in toolbar",
        "Choose from preset colors (yellow, green, blue, pink)",
        "Text highlighted in chosen color"
      ],
      "passes": false
    },
    {
      "id": "F014",
      "category": "highlight",
      "description": "Highlight with custom RGB color",
      "steps": [
        "Select text in PDF",
        "Click highlight dropdown > Custom Color",
        "Color picker appears",
        "Enter RGB values or use picker",
        "Text highlighted in custom color"
      ],
      "passes": false
    },
    {
      "id": "F015",
      "category": "highlight",
      "description": "Remove highlight from text",
      "steps": [
        "Click on existing highlight",
        "Highlight becomes selected",
        "Press Delete or right-click > Remove",
        "Highlight is removed"
      ],
      "passes": false
    },
    {
      "id": "F016",
      "category": "highlight",
      "description": "Change color of existing highlight",
      "steps": [
        "Click on existing highlight",
        "Right-click > Change Color",
        "Select new color from picker",
        "Highlight updates to new color"
      ],
      "passes": false
    },
    {
      "id": "F017",
      "category": "underline",
      "description": "Underline selected text",
      "steps": [
        "Select text in PDF",
        "Press Cmd+U or click underline button",
        "Text displays underline annotation"
      ],
      "passes": false
    },
    {
      "id": "F018",
      "category": "underline",
      "description": "Underline with custom color",
      "steps": [
        "Select text in PDF",
        "Click underline dropdown > Choose color",
        "Select color from picker",
        "Underline appears in chosen color"
      ],
      "passes": false
    },
    {
      "id": "F019",
      "category": "underline",
      "description": "Remove underline from text",
      "steps": [
        "Click on existing underline annotation",
        "Press Delete or right-click > Remove",
        "Underline is removed"
      ],
      "passes": false
    },
    {
      "id": "F020",
      "category": "bookmark",
      "description": "Add bookmark to current page",
      "steps": [
        "Navigate to desired page",
        "Press Cmd+D or click bookmark icon",
        "Bookmark added with default name (Page X)",
        "Bookmark appears in sidebar"
      ],
      "passes": false
    },
    {
      "id": "F021",
      "category": "bookmark",
      "description": "View bookmarks in sidebar",
      "steps": [
        "Add multiple bookmarks",
        "Press Cmd+Shift+B or View > Bookmarks",
        "Sidebar shows bookmark list",
        "Click bookmark to navigate to page"
      ],
      "passes": false
    },
    {
      "id": "F022",
      "category": "bookmark",
      "description": "Rename bookmark",
      "steps": [
        "Right-click bookmark in sidebar",
        "Select Rename",
        "Enter custom name",
        "Bookmark displays new name"
      ],
      "passes": false
    },
    {
      "id": "F023",
      "category": "bookmark",
      "description": "Delete bookmark",
      "steps": [
        "Right-click bookmark in sidebar",
        "Select Delete",
        "Bookmark removed from list"
      ],
      "passes": false
    },
    {
      "id": "F024",
      "category": "comments",
      "description": "Add comment to text selection",
      "steps": [
        "Select text in PDF",
        "Right-click > Add Comment or press Cmd+Shift+C",
        "Comment popover appears",
        "Type comment text",
        "Press Enter or click away to save",
        "Comment indicator appears on text"
      ],
      "passes": false
    },
    {
      "id": "F025",
      "category": "comments",
      "description": "View existing comment",
      "steps": [
        "Click on comment indicator in PDF",
        "Comment popover displays",
        "Comment text is visible"
      ],
      "passes": false
    },
    {
      "id": "F026",
      "category": "comments",
      "description": "Edit existing comment",
      "steps": [
        "Click on comment indicator",
        "Click edit icon or double-click text",
        "Edit comment text",
        "Click away to save changes"
      ],
      "passes": false
    },
    {
      "id": "F027",
      "category": "comments",
      "description": "Delete comment",
      "steps": [
        "Click on comment indicator",
        "Click delete icon or right-click > Delete",
        "Comment is removed"
      ],
      "passes": false
    },
    {
      "id": "F028",
      "category": "comments",
      "description": "View all comments in sidebar",
      "steps": [
        "Add multiple comments to PDF",
        "View > Comments or Cmd+Shift+A",
        "Sidebar shows list of all comments",
        "Click comment to navigate to its location"
      ],
      "passes": false
    },
    {
      "id": "F029",
      "category": "save",
      "description": "Auto-save annotations to PDF",
      "steps": [
        "Open PDF and add annotations",
        "Wait 3 seconds (autosave interval)",
        "Close and reopen PDF",
        "Annotations persist"
      ],
      "passes": false
    },
    {
      "id": "F030",
      "category": "save",
      "description": "Manual save with Cmd+S",
      "steps": [
        "Open PDF and add annotations",
        "Press Cmd+S",
        "File saves immediately",
        "No unsaved changes indicator"
      ],
      "passes": false
    },
    {
      "id": "F031",
      "category": "save",
      "description": "Save As with new filename",
      "steps": [
        "Open PDF and add annotations",
        "Press Cmd+Shift+S or File > Save As",
        "Choose new filename and location",
        "New file created with annotations"
      ],
      "passes": false
    },
    {
      "id": "F032",
      "category": "save",
      "description": "Export PDF without annotations",
      "steps": [
        "Open annotated PDF",
        "File > Export Without Annotations",
        "Choose filename and location",
        "Exported PDF has no annotations"
      ],
      "passes": false
    },
    {
      "id": "F033",
      "category": "ui",
      "description": "Toggle toolbar visibility",
      "steps": [
        "Open PDF",
        "Press Cmd+Option+T or View > Hide Toolbar",
        "Toolbar hides",
        "Repeat to show toolbar"
      ],
      "passes": false
    },
    {
      "id": "F034",
      "category": "ui",
      "description": "Full screen mode",
      "steps": [
        "Open PDF",
        "Press Cmd+Ctrl+F or green window button",
        "App enters full screen",
        "Press Esc to exit"
      ],
      "passes": false
    },
    {
      "id": "F035",
      "category": "ui",
      "description": "Dark mode support",
      "steps": [
        "Set system to dark mode",
        "Open PageFlow",
        "UI renders in dark theme",
        "Switch to light mode",
        "UI updates to light theme"
      ],
      "passes": false
    },
    {
      "id": "F036",
      "category": "ui",
      "description": "Undo/Redo annotation actions",
      "steps": [
        "Add highlight to text",
        "Press Cmd+Z",
        "Highlight is removed",
        "Press Cmd+Shift+Z",
        "Highlight is restored"
      ],
      "passes": false
    },
    {
      "id": "F037",
      "category": "keyboard",
      "description": "All standard keyboard shortcuts work",
      "steps": [
        "Verify Cmd+O opens file",
        "Verify Cmd+W closes tab",
        "Verify Cmd+Q quits app",
        "Verify Cmd+F opens search",
        "Verify Cmd+P opens print dialog"
      ],
      "passes": false
    }
  ]
}
```

---

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Open File | Cmd+O |
| Close Tab | Cmd+W |
| Save | Cmd+S |
| Save As | Cmd+Shift+S |
| Print | Cmd+P |
| Quit | Cmd+Q |
| New Tab | Cmd+T |
| Find | Cmd+F |
| Go to Page | Cmd+G |
| Zoom In | Cmd++ |
| Zoom Out | Cmd+- |
| Actual Size | Cmd+0 |
| Highlight | Cmd+H |
| Underline | Cmd+U |
| Add Bookmark | Cmd+D |
| Add Comment | Cmd+Shift+C |
| Toggle Thumbnails | Cmd+Shift+T |
| Toggle Bookmarks | Cmd+Shift+B |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Full Screen | Cmd+Ctrl+F |

---

## Init Script

```bash
#!/bin/bash
# init.sh - Development environment setup

echo "=== PageFlow Development Setup ==="

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode not found. Install from App Store."
    exit 1
fi
echo "✓ Xcode installed"

# Check macOS version
MACOS_VERSION=$(sw_vers -productVersion)
echo "✓ macOS version: $MACOS_VERSION"

# Navigate to project
cd "$(dirname "$0")"

# Build project
echo "Building PageFlow..."
xcodebuild -project PageFlow.xcodeproj -scheme PageFlow -configuration Debug build

# Run app
if [ $? -eq 0 ]; then
    echo "✓ Build successful"
    echo "Running PageFlow..."
    open build/Debug/PageFlow.app
else
    echo "❌ Build failed"
    exit 1
fi
```


## Success Criteria

1. App opens PDFs under 1 second for files <50MB
2. All 37 features pass verification
3. Memory usage <200MB for typical PDF
4. App bundle size <20MB
5. Passes App Store review guidelines (for future consideration)
6. Works on macOS 12+