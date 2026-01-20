//
//  NonDraggableArea.swift
//  PageFlow
//
//  NSView wrapper that prevents mouse events from dragging the window.
//  Used in title bar areas where we want gestures to work instead of window dragging.
//

import SwiftUI
import AppKit

/// An NSView that explicitly prevents window dragging from its area.
/// Use this to wrap views in the title bar that should handle their own gestures.
struct NonDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        NonDraggableNSView()
    }

    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

/// Custom NSView that returns false for mouseDownCanMoveWindow.
/// This tells macOS "mouse events in this view should NOT drag the window".
final class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
