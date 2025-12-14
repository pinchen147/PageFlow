//
//  WindowDragArea.swift
//  PageFlow
//
//  Transparent drag handle to move the window from a custom region.
//

import SwiftUI
import AppKit

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragCaptureView()
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}

private final class WindowDragCaptureView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
