//
//  NativeTextView+DragSelectBoost.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Mouse-down entry point for the text view, plus the autoscroll-boost timer
//  that keeps drag-selection moving when the cursor sits near a window edge.
//

import AppKit

extension NativeTextView {
    override func mouseDown(with event: NSEvent) {
        // A click makes this editor's tab the active one (PDF parity): the host
        // switches selection, and the focus knob then hands over the keyboard.
        (delegate as? NativeTextViewCoordinator)?.onRequestFocus?()
        // A click on a comment highlight opens its card; elsewhere it closes the open one.
        let comments = (delegate as? NativeTextViewCoordinator)?.comments
        comments?.documentMouseDown(event)
        if routeMouseDownToTables(event) { comments?.documentClickHandledElsewhere(); return }
        // After the tables, which end any cell editing on a press elsewhere.
        if routeMouseDownToBlocks(event) { comments?.documentClickHandledElsewhere(); return }
        if let toggled = toggleTaskCheckboxIfHit(event: event), toggled {
            comments?.documentClickHandledElsewhere()
            return
        }
        if remapClickInParagraphSpacing(event: event) {
            comments?.documentMouseUp()
            return
        }
        dragStartMouseScreenLoc = NSEvent.mouseLocation
        let boostTimer = Timer(timeInterval: 1.0 / configuration.dragSelection.ticksPerSecond, repeats: true) { [weak self] _ in
            self?.performDragBoostTick()
        }
        RunLoop.current.add(boostTimer, forMode: .common)
        // The selection bar waits for mouse-up (the reference editor shows it ~30 ms after it).
        let bar = (delegate as? NativeTextViewCoordinator)?.selectionBar
        bar?.rightClickSuppressed = false
        bar?.isDragSelecting = true
        defer {
            boostTimer.invalidate()
            dragStartMouseScreenLoc = nil
            bar?.isDragSelecting = false
            comments?.documentMouseUp()
        }

        super.mouseDown(with: event)
    }

    func performDragBoostTick() {
        guard let window = self.window,
              let scrollView = enclosingScrollView,
              let start = dragStartMouseScreenLoc else { return }

        let mouseScreen = NSEvent.mouseLocation
        let dragPolicy = configuration.dragSelection
        // Require real drag movement so a static click at the window edge doesn't scroll.
        guard max(abs(mouseScreen.x - start.x), abs(mouseScreen.y - start.y)) > dragPolicy.movementThreshold else { return }

        let mouseInWin = window.convertPoint(fromScreen: mouseScreen)
        let direction: CGFloat
        if mouseInWin.y <= dragPolicy.edgeTriggerDistance {
            direction = 1.0
        } else if mouseInWin.y >= window.frame.height - dragPolicy.edgeTriggerDistance {
            direction = -1.0
        } else {
            return
        }

        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + dragPolicy.scrollStepPerTick * direction))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }
}
