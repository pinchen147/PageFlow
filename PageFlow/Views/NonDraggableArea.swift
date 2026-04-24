//
//  NonDraggableArea.swift
//  PageFlow
//
//  Small AppKit bridge views for title bar interaction behavior.
//

import SwiftUI
import AppKit

struct NonDraggableArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        NonDraggableNSView()
    }

    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

final class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

struct HoverTrackingArea: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        let isHoveredBinding = _isHovered
        view.onHoverChanged = { hovering in
            if isHoveredBinding.wrappedValue != hovering {
                isHoveredBinding.wrappedValue = hovering
            }
        }
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        let isHoveredBinding = _isHovered
        nsView.onHoverChanged = { hovering in
            if isHoveredBinding.wrappedValue != hovering {
                isHoveredBinding.wrappedValue = hovering
            }
        }
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeAlways,
            .enabledDuringMouseDrag,
            .inVisibleRect,
            .mouseEnteredAndExited
        ]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        if newWindow == nil {
            onHoverChanged?(false)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
