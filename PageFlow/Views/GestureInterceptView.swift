//
//  GestureInterceptView.swift
//  PageFlow
//
//  NSView that prevents window dragging while allowing SwiftUI gestures to work.
//  The key is `mouseDownCanMoveWindow = false` - events still flow to SwiftUI.
//

import SwiftUI
import AppKit

struct GestureInterceptView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        GestureInterceptNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class GestureInterceptNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        false  // Prevents window dragging from this area
    }

    // Do NOT override mouseDown/mouseDragged/mouseUp
    // Let events flow through to SwiftUI gesture recognizers
}
