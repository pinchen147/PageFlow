//
//  NativeTextViewCoordinator+HostPresence.swift
//  MarkdownEngine
//
//  What the host tells the editor about its place on screen — displayed or
//  warm-but-hidden, keyboard owner or not, and where the reader should land —
//  and the viewport observers those states switch on and off. A hidden editor
//  costs nothing per scroll tick and never grabs the keyboard; a shown editor
//  catches up on the geometry it missed in one pass.
//

import AppKit

extension NativeTextViewCoordinator {

    // MARK: - Displayed / hidden

    /// Hides or shows the editor at the AppKit level. Hidden: no draw, no
    /// hit-testing, observers off, idle restyle paused, keyboard released.
    /// Shown: observers back on, the geometry the view missed reconciled, the
    /// idle restyle resumed and any reading position it was waiting to land on
    /// applied.
    func applyDisplayed(_ displayed: Bool, scrollView: ClampedScrollView, textView: NativeTextView) {
        guard displayed != lastDisplayed || scrollView.isHidden == displayed else { return }
        lastDisplayed = displayed
        if displayed {
            scrollView.isHidden = false
            installViewObservers(scrollView: scrollView, textView: textView)
            viewportFrameDidChange(scrollView: scrollView, textView: textView)
            textView.resumeDeferredLayoutWork(for: scrollView)
            enqueueDeferredRestyle([])
            applyPendingReadingPosition(scrollView: scrollView, textView: textView)
        } else {
            tableEditingSession.finishInput()
            commitTextSync(for: textView)
            if textView.window?.firstResponder === textView
                || textView.window?.firstResponder === tableEditingSession.editor {
                textView.window?.makeFirstResponder(nil)
            }
            removeViewObservers()
            textView.pauseDeferredLayoutWork()
            scrollView.isHidden = true
        }
    }

    /// The keyboard follows the host's active tab: the editor takes first
    /// responder one turn after it is asked to (a responder change inside a
    /// SwiftUI update re-enters AppKit), and only while it is displayed.
    func applyFocused(_ focused: Bool, textView: NativeTextView) {
        guard focused != lastFocused else { return }
        lastFocused = focused
        guard focused else { return }
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, self.lastFocused, let textView, let window = textView.window,
                  textView.enclosingScrollView?.isHidden == false,
                  window.firstResponder !== textView else { return }
            window.makeFirstResponder(self.tableEditingSession.preferredResponder ?? textView)
        }
    }

    // MARK: - Reading position

    /// Lands the pending request once the editor is styled, displayed and has
    /// a viewport to land in. A request handed over before that waits here.
    func applyPendingReadingPosition(scrollView: ClampedScrollView, textView: NativeTextView) {
        guard let request = pendingReadingPositionRequest, didInitialFormatting,
              !scrollView.isHidden, scrollView.contentView.bounds.height > 1 else { return }
        pendingReadingPositionRequest = nil
        appliedReadingPositionToken = request.token
        textView.restore(request.position)
    }

    // MARK: - Viewport geometry

    /// The frame observer's work, also run once when a hidden editor is shown
    /// (its observers were off while the window may have been resized).
    func viewportFrameDidChange(scrollView: ClampedScrollView, textView: NativeTextView) {
        // Refresh code-block overlays only on real viewport width changes, not
        // on TextKit height-only echoes during typing.
        let newWidth = scrollView.contentView.bounds.width
        let widthChanged = abs(newWidth - lastObservedViewportWidth) > 0.5
        let positionBeforeResize = lastReadingPosition
        if widthChanged {
            lastObservedViewportWidth = newWidth
            // Re-center the column by position (no redraw) so it stays smooth during live resize.
            if configuration.readingWidth != nil {
                textView.centerReadingColumn(forClipWidth: newWidth)
            } else if !scrollView.isZoomInProgress {
                // A zoomed document can keep its wider frame after the clip
                // view shrinks, so its normal width propagation never runs.
                textView.applyZoomContainerGeometry()
            }
            didEnsureLayoutForCurrentDocument = false
            updateCodeBlockSelection(textView: textView)
        }
        // Only react with an overscroll recalc when the viewport itself resizes
        // (window resize). Without this guard, TextKit-induced frame changes
        // echo back here and re-trigger recalcOverscroll, causing a 149 pt
        // height oscillation after clicks. Compare the CONTAINER (the document
        // view) height to the viewport — it tracks the viewport for short docs.
        if let container = scrollView.documentView as? NativeTextViewContainer,
           abs(container.frame.height - scrollView.contentView.bounds.height) > 1 {
            textView.recalcOverscroll(for: scrollView)
            scrollView.clampToInsets()
        }
        // A new width re-wrapped everything: the raw scroll offset now points at
        // a different source line. Land the one the reader was on (D7 — location,
        // not offset, is what survives a reflow).
        if widthChanged, pendingReadingPositionRequest == nil, !scrollView.isZoomInProgress,
           let position = positionBeforeResize {
            textView.restore(position)
        }
        applyPendingReadingPosition(scrollView: scrollView, textView: textView)
        foldControls?.refresh()
    }

    // MARK: - Observers

    /// The frame and bounds observers on the clip view. Installed at mount and
    /// whenever a hidden editor is shown again; removed on dismantle and while
    /// the editor is hidden, so a warm off-screen tab does no per-scroll work.
    func installViewObservers(scrollView: ClampedScrollView, textView: NativeTextView) {
        removeViewObservers()
        scrollView.contentView.postsBoundsChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak scrollView, weak textView, weak coordinator = self] _ in
            guard let scrollView, let textView, let coordinator else { return }
            coordinator.viewportFrameDidChange(scrollView: scrollView, textView: textView)
        }
        let boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak scrollView, weak textView, weak coordinator = self] _ in
            guard let scrollView, let textView, let coordinator else { return }
            MainActor.assumeIsolated { ScrollTrace.observe(scrollView) }
            // ZOOM frames are frozen (ADR-0019): during a pinch / zoom-tick
            // burst / AppKit's past-the-limit magnification bounce, the clip
            // bounds change on every frame, and each ensureVisibleLayout /
            // realign / clamp pass below either forces TextKit 2 layout (whose
            // estimate revisions MOVE the content under the fixed scroll
            // origin) or fights AppKit's own re-anchoring — the "jumps
            // erratically" field bug. Detection is VALUE-based (the live-magnify
            // notifications proved unreliable in the field): any magnification
            // mutation opens the freeze window and pushes the settle out, so
            // the one clean pass always runs after the LAST mutation — gesture,
            // tick, or bounce animation alike.
            if scrollView.detectMagnificationMutation() {
                textView.magnificationDidSettle()
                return
            }
            if scrollView.isZoomInProgress { return }
            textView.ensureVisibleLayout()
            coordinator.lastReadingPosition = textView.readingPosition() ?? coordinator.lastReadingPosition
            if coordinator.isWritingToolsActive {
                coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
            }
            // No clamp per tick: the clip view keeps its own bounds inside the
            // document (and its rubber band past it); an origin snapped back on
            // every tick cut the elastic overshoot the moment it appeared. A
            // height measured too small still needs a rescue — remeasure, never
            // move the origin.
            scrollView.rescueStaleHeightIfNeeded()
            coordinator.refreshActiveLinkCaretRect()
            coordinator.updateCodeBlockSelection(textView: textView)
            // Keep breakout wide-table overlays glued to their anchor lines while
            // scrolling — heals any frame that went stale through a missed
            // reconcile trigger (see realignWideTableOverlays).
            textView.realignWideTableOverlays()
            coordinator.selectionBar?.reposition()
            coordinator.foldControls?.refresh()
        }
        viewObserverTokens = [frameObserver, boundsObserver]
    }
}
