# Pan Grab Cursor Implementation for macOS PDFView - Refined Plan

This document outlines the refined plan for implementing a "select vs. pan" tool in the PageFlow application, allowing users to toggle between a default selection cursor and a pan (hand) cursor via a toolbar button.

## Viability Assessment

The proposed implementation is highly viable and well-suited for the existing architecture of the `PageFlow` project. The project's use of a custom `PDFView` subclass (`StablePDFView`), wrapped in SwiftUI (`PDFViewWrapper`), and central state management via `PDFManager`, provide ideal integration points for this feature.

## Detailed Plan of Action

### 1. Define `InteractionMode` Enum

*   **Location:** `PageFlow/PageFlow/Managers/PDFManager.swift` (outside the `PDFManager` class, at the top of the file).
*   **Content:**
    ```swift
    enum InteractionMode {
        case select // Default mode for text selection, annotation interaction
        case pan    // Mode for dragging/panning the PDF view
    }
    ```
*   **Rationale:** Centralizes the definition of interaction states, making it accessible to both the `PDFManager` (for state management) and `StablePDFView` (for behavior).

### 2. Add `interactionMode` State to `PDFManager`

*   **Location:** `PageFlow/PageFlow/Managers/PDFManager.swift` (inside the `PDFManager` class).
*   **Change:** Add a new `@Observable` property:
    ```swift
    var interactionMode: InteractionMode = .select
    ```
*   **Rationale:** `PDFManager` is the application's central state manager. Storing the active interaction mode here ensures a single source of truth that can be observed and propagated throughout the UI.

### 3. Implement Cursor and Panning Logic in `StablePDFView`

*   **Location:** `PageFlow/PageFlow/Views/StablePDFView.swift` (This class already subclasses `PDFView`).
*   **Changes:**
    *   **Property:** Add a `var interactionMode: InteractionMode` property. This property will receive its value from the `PDFManager` via the `PDFViewWrapper`.
    *   **`didSet` Observer:** Implement a `didSet` observer for `interactionMode` to call `window?.invalidateCursorRects(for: self)`. This is crucial for macOS to re-evaluate and apply the correct cursor.
    *   **`private var lastPanLocation: NSPoint?`:** Add this private property to store the initial mouse down location during a pan gesture.
    *   **Override `resetCursorRects()`:**
        *   If `interactionMode` is `.pan`, use `addCursorRect(self.bounds, cursor: .openHand)` to set the open-hand cursor across the entire view.
        *   If `interactionMode` is `.select`, call `super.resetCursorRects()` to allow `PDFKit` to manage its default cursors (I-beam for text, arrow for links, etc.).
    *   **Override `cursorUpdate(with event: NSEvent)`:**
        *   If `interactionMode` is `.select`, determine the `PDFAreaOfInterest` (using `areaOfInterest(for:)`) and call `setCursorFor(_:)` to let `PDFKit` apply its standard cursors.
        *   If `interactionMode` is `.pan`, and a mouse drag/down event is active, set `NSCursor.closedHand`. Otherwise, set `NSCursor.openHand`.
    *   **Override `mouseDown(with event: NSEvent)`:**
        *   If `interactionMode` is `.pan`, store the `event.locationInWindow` (converted to view coordinates) in `lastPanLocation` and push `NSCursor.closedHand` to visually indicate dragging.
        *   Otherwise, call `super.mouseDown(with: event)` to preserve default selection behavior.
    *   **Override `mouseDragged(with event: NSEvent)`:**
        *   If `interactionMode` is `.pan` and `lastPanLocation` is set, calculate the `dx` and `dy` based on the current mouse position. Adjust the `scrollView.contentView.bounds.origin` to pan the view. Update `lastPanLocation` with the current mouse position.
        *   Otherwise, call `super.mouseDragged(with: event)`.
    *   **Override `mouseUp(with event: NSEvent)`:**
        *   If `interactionMode` is `.pan`, set `lastPanLocation` to `nil` and pop `NSCursor.openHand` to restore the open-hand cursor.
        *   Otherwise, call `super.mouseUp(with: event)`.
    *   **Rationale:** `StablePDFView` is the direct `PDFView` subclass, making it the correct place to override low-level mouse event handling and cursor management.

### 4. Bind `interactionMode` in `PDFViewWrapper`

*   **Location:** `PageFlow/PageFlow/Views/PDFViewWrapper.swift` (the `NSViewRepresentable` responsible for integrating `StablePDFView` into SwiftUI).
*   **Change:** In the `updateNSView` function, add logic to update `StablePDFView`'s `interactionMode` property whenever `pdfManager.interactionMode` changes:
    ```swift
    if pdfView.interactionMode != pdfManager.interactionMode {
        pdfView.interactionMode = pdfManager.interactionMode
    }
    ```
*   **Rationale:** This establishes the one-way data flow from the SwiftUI state (`PDFManager`) down to the AppKit view (`StablePDFView`), keeping the view's behavior synchronized with the application state.

### 5. Add Toolbar Toggle Button

*   **Location:** `PageFlow/PageFlow/Views/FloatingToolbar.swift`
*   **Changes:**
    *   Introduce a new `toolbarButton` (or similar UI component) within the `expandedToolbar`'s `HStack`. The button should be placed strategically, for example, as the most right icon as per the initial request.
    *   **Icon:** Choose appropriate `SF Symbols` to visually represent the "select" and "pan" modes. The icon should dynamically change based on `pdfManager.interactionMode`. For instance, `cursorarrow.rays` for select and `hand.raised` or `hand.draw` for pan.
    *   **Action:** The button's action should toggle `pdfManager.interactionMode` between `.select` and `.pan`.
*   **Rationale:** Provides the user with a direct and intuitive way to switch between the interaction modes, integrated into the existing toolbar.

---

This comprehensive plan ensures that the pan grab cursor functionality is robustly implemented, integrated cleanly into the `PageFlow` codebase, and provides a good user experience.