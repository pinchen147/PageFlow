//
//  TabBarGestureView.swift
//  PageFlow
//
//  NSView overlay that prevents window dragging and handles tab drag gestures
//  at the AppKit level for immediate response.
//

import SwiftUI
import AppKit
import os.log

private let gestureLogger = Logger(subsystem: "com.pageflow", category: "TabBarGesture")

/// Callbacks for gesture events
struct TabBarGestureCallbacks {
    var onDragStarted: (CGFloat) -> Void = { _ in }  // x position
    var onDragChanged: (CGFloat, CGFloat) -> Void = { _, _ in }  // x position, translation
    var onDragEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onClick: (CGFloat) -> Void = { _ in }  // x position
    var onHoverChanged: (CGFloat?) -> Void = { _ in }  // x position, nil on exit
}

/// NSView overlay that handles gestures at AppKit level
struct TabBarGestureView: NSViewRepresentable {
    var callbacks: TabBarGestureCallbacks

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TabBarGestureNSView {
        let view = TabBarGestureNSView()
        context.coordinator.callbacks = callbacks
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TabBarGestureNSView, context: Context) {
        // Always update coordinator's callbacks - this ensures the NSView uses current closures
        context.coordinator.callbacks = callbacks
    }

    /// Coordinator holds callbacks and persists across view updates
    class Coordinator {
        var callbacks = TabBarGestureCallbacks()
    }
}

final class TabBarGestureNSView: NSView {
    /// Coordinator provides always-current callbacks (updated by SwiftUI on each render)
    weak var coordinator: TabBarGestureView.Coordinator?

    private var mouseDownLocation: NSPoint?
    private var isDragging = false
    private let dragThreshold: CGFloat = 5
    private var trackingArea: NSTrackingArea?

    /// Access callbacks through coordinator to ensure we always have current closures
    private var callbacks: TabBarGestureCallbacks {
        coordinator?.callbacks ?? TabBarGestureCallbacks()
    }

    // CRITICAL: Prevent window dragging
    override var mouseDownCanMoveWindow: Bool { false }

    override var isFlipped: Bool { true }

    // Accept first mouse so clicks work even when window is inactive
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        callbacks.onHoverChanged(point.x)
    }

    override func mouseExited(with event: NSEvent) {
        callbacks.onHoverChanged(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        callbacks.onHoverChanged(point.x)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        gestureLogger.debug("⬇️ mouseDown: point=(\(point.x), \(point.y)), bounds=\(self.bounds.width)x\(self.bounds.height)")
        mouseDownLocation = point
        isDragging = false
        callbacks.onHoverChanged(point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = mouseDownLocation else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translationX = currentPoint.x - startPoint.x

        if !isDragging && abs(translationX) > dragThreshold {
            isDragging = true
            gestureLogger.debug("🟢 DRAG THRESHOLD MET: startX=\(startPoint.x), translation=\(translationX)")
            NSCursor.closedHand.push()
            callbacks.onDragStarted(startPoint.x)
        }

        if isDragging {
            callbacks.onDragChanged(currentPoint.x, translationX)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let startPoint = mouseDownLocation else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translationX = currentPoint.x - startPoint.x

        if isDragging {
            NSCursor.pop()
            callbacks.onDragEnded(currentPoint.x, translationX)
        } else {
            // It was a click
            callbacks.onClick(startPoint.x)
        }

        mouseDownLocation = nil
        isDragging = false
    }
}
