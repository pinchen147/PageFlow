//
//  NSScreen+Geometry.swift
//  PageFlow
//
//  Canonical point → screen resolution for window placement.
//

import AppKit

extension NSScreen {
    /// The screen whose `frame` contains `point` (a cursor location or a window
    /// position in screen coordinates), falling back to the main screen.
    ///
    /// This is the single canonical helper for "which screen is this point on?",
    /// shared by window positioning (`AppDelegate`) and tab tear-off
    /// (`TabDragController`) so they always resolve the same screen.
    static func containing(_ point: CGPoint) -> NSScreen? {
        screens.first { $0.frame.contains(point) } ?? main
    }

    /// Constrains `frame` to sit fully within `visibleFrame`: shrinks any
    /// dimension larger than the visible frame, then clamps the origin so the
    /// whole rect is on-screen (mirroring AppKit's own `constrainFrameRect`).
    /// Pure so it is unit-testable, and the single clamp shared by tab tear-off
    /// (`TabDragController`) and window positioning (`AppDelegate`).
    static func onScreenFrame(_ frame: NSRect, in visibleFrame: NSRect) -> NSRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
