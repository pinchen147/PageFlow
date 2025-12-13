
• Implemented manual save + save as with feedback and dirty state, aligned with
  - PageFlowApp: added Cmd+S (Save) and Cmd+Shift+S (Save As) commands with simple
    alerts on failure.
  - MainView: listens for save notifications and shows a small glass-style toast;
    added state for toast handling.
  - Dirty indicator: tabs show a small dot when their PDF is marked dirty (via new
    unimplemented by request).

  Notes:

  - No autosave (per your direction).
  - Dirty is currently set on rotation; future annotation/bookmark/comment features
    can call pdfManager.isDirty = true or add markDirty points.
  - Save As updates the document URL and tab title; Save failures surface an alert;
    successes show a toast.

  Files changed: PDFManager.swift, TabManager.swift, PageFlowApp.swift,
  MainView.swift, TabBarView.swift, TabItemView.swift, docs/features.json, added
  SaveNotifications.swift.

  # Save & Export Feature Implementation
Date: December 10, 2025

## Overview
Implemented manual **Save** and **Save As** functionality for PDF documents. Auto-save was explicitly excluded per user requirements in favor of a manual, lightweight approach.

## Features

### 1. Manual Save (Cmd+S)
- **Behavior**: Writes changes to the current file on disk.
- **Feedback**: Shows a non-intrusive "Saved" toast notification at the bottom of the window.
- **Dirty State**: Clears the "dirty" indicator upon success.
- **Error Handling**: Displays an alert if the save fails (e.g., read-only permissions).

### 2. Save As (Cmd+Shift+S)
- **Behavior**: Opens a native macOS `NSSavePanel` to choose a new destination.
- **Logic**:
  - Writes the current PDF state to the new location.
  - Updates the active tab's `documentURL` to point to the new file.
  - Updates the window/tab title.
  - Releases security-scoped access to the old file (if applicable) and establishes it for the new one.
- **Feedback**: Shows a "Saved As" toast notification.

### 3. Dirty State Tracking
- **Indicator**: A small white circle appears next to the tab title when unsaved changes exist.
- **Triggers**:
  - Currently triggered by **Page Rotation**.
  - Infrastructure ready for Annotations, Bookmarks, and Comments (simply set `pdfManager.isDirty = true`).

## Technical Implementation

### Managers
- **`PDFManager`**:
  - Added `isDirty` boolean property.
  - Updated `save()` and `saveAs(to:)` methods to handle `write(to:)` and reset `isDirty`.
  - Added security-scoped resource management in `saveAs` to properly switch file access.
- **`TabManager`**:
  - Added `isTabDirty(_:)` to expose state to UI.
  - Implemented `saveActiveDocument()` and `saveActiveDocumentAs()` logic.
  - Handles `NSSavePanel` presentation (using `allowedContentTypes` for macOS 12+).
  - Posts `Notification.Name.saveResult` for UI feedback.
- **`SaveNotifications.swift`**:
  - Defined `Notification.Name.saveResult`.

### UI Components
- **`PageFlowApp`**:
  - Added menu commands for "Save" (`Cmd+S`) and "Save As…" (`Cmd+Shift+S`).
  - Connects commands to `TabManager`.
- **`MainView`**:
  - Listens for `.saveResult` notifications.
  - Displays a glassmorphism-styled toast overlay.
- **`TabItemView`**:
  - Displays the dirty indicator dot (sized via `DesignTokens.tabDirtyIndicatorSize`).
- **`DesignTokens`**:
  - Added `tabDirtyIndicatorSize`.

### Architecture Notes
- **Modular**: Save logic is decoupled from the View layer (resides in Managers).
- **Reactive**: Uses SwiftUI `@Observable` and `NotificationCenter` for state propagation.
- **Native**: Uses standard `NSSavePanel` and file coordination.

## Future Considerations
- **Auto-save**: Architecture allows enabling auto-save later by observing `isDirty` and triggering `save()` on a timer or debounce.
- **Annotations**: When implementing annotations, ensure `isDirty = true` is set on modification.

## Fix Applied (Dec 11, 2025)
- Changed from `PDFDocument.write(to:)` to `PDFDocument.dataRepresentation()` + `Data.write(to:options:)`
- This fixes annotation saving issues - `write(to:)` can fail silently while `dataRepresentation()` properly serializes all annotations
- Added `.atomic` write option for safer file operations