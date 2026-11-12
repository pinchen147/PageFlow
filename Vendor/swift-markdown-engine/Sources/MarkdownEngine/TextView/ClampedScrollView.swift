//
//  ClampedScrollView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Scroll view that keeps vertical scrolling within a clean top and bottom range.
import AppKit
import QuartzCore

final class ClampedScrollView: NSScrollView {
    /// Native setters can call one another and publish intermediate clip bounds.
    /// Reconcile column geometry only after the outer native operation returns.
    private var nativeMagnificationDepth = 0
    var isApplyingNativeMagnification: Bool { nativeMagnificationDepth > 0 }

    private func applyingNativeMagnification(_ change: () -> Void) {
        nativeMagnificationDepth += 1
        change()
        nativeMagnificationDepth -= 1
        guard nativeMagnificationDepth == 0,
              abs(contentView.bounds.width * magnification - contentView.frame.width) < 0.5 else { return }
        nativeTextView?.centerReadingColumn(forClipWidth: contentView.bounds.width, preservingViewport: true)
    }

    override var magnification: CGFloat {
        get { super.magnification }
        set { applyingNativeMagnification { super.magnification = newValue } }
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        applyingNativeMagnification { super.setMagnification(magnification, centeredAt: point) }
    }

    private var isHandlingMagnifyGesture = false

    private func beginUserMagnification(at anchor: NSPoint?) {
        guard !isHandlingMagnifyGesture else { return }
        isHandlingMagnifyGesture = true
        _ = onUserMagnificationBegan?(anchor)
    }

    override func magnify(with event: NSEvent) {
        beginUserMagnification(at: contentView.convert(event.locationInWindow, from: nil))
        applyingNativeMagnification { super.magnify(with: event) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            isHandlingMagnifyGesture = false
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // NSClipView rejects hits in contentInsets even when scrolling has
        // brought visible document content into that band. Keep native chrome
        // hits, but let actual document descendants receive those clicks.
        guard hit === self, let document = documentView,
              !document.isHiddenOrHasHiddenAncestor, let parent = document.superview,
              contentView.frame.contains(convert(point, from: superview)),
              let descendant = document.hitTest(parent.convert(point, from: superview)),
              descendant !== document else { return hit }
        return descendant
    }

    /// Reports a USER-driven magnification change (pinch gesture end or
    /// Ctrl+scroll) so the host can persist the per-document zoom. Not fired for
    /// host-projected magnification (⌘±, ⌘0, restore), which the host already
    /// knows. `nil` when visual zoom is disabled.
    var onMagnificationChanged: ((CGFloat) -> Void)?
    var onUserMagnificationBegan: ((NSPoint?) -> Bool)?
    /// Per-Ctrl-scroll-tick zoom factor (PDF parity).
    var ctrlScrollZoomFactor: CGFloat = 1.1
    private var liveMagnifyObservers: [NSObjectProtocol] = []
    /// True during a live pinch. The clamp rescue (below) is skipped then:
    /// no restyle runs mid-gesture, so the cached content height cannot go
    /// stale — while the clamp condition can hold on EVERY magnify frame.
    private(set) var isLiveMagnifying = false
    /// Last time the clamp rescue ran a full-layout re-measure (throttle).
    private var lastClampRescue: CFTimeInterval = 0
    /// Timestamp of the last DISCRETE magnification change (Ctrl-scroll tick,
    /// ⌘±/restore projection, pinch end). Together with `isLiveMagnifying`
    /// this defines `isZoomInProgress`.
    private var lastMagnificationChangeAt: CFTimeInterval = 0

    /// Stamp a magnification change from any non-gesture path. Always called
    /// on the main thread (gesture/menu/update paths).
    func noteMagnificationChanged() {
        lastMagnificationChangeAt = CACurrentMediaTime()
    }

    /// A magnification change is in flight: a live pinch, or within 150ms of a
    /// discrete zoom event (tick bursts). Layout-forcing per-frame work (visible
    /// ensureLayout, overlay realign/reconcile) is FROZEN while true — TextKit 2
    /// layout passes revise estimated fragment heights (worst around a tall
    /// collapsed diagram band), which moves content under a fixed scroll origin
    /// on every magnify frame (field: "zooming in on mermaid jumps erratically").
    /// AppKit's own model scales the existing bitmap during the gesture; the
    /// zoom settle (debounced 200ms > this 150ms window) runs the one clean
    /// layout + reconcile pass afterwards.
    var isZoomInProgress: Bool {
        isLiveMagnifying || CACurrentMediaTime() - lastMagnificationChangeAt < 0.15
    }

    /// The magnification the freeze detector last saw. Field forensics showed
    /// the live-magnify NOTIFICATIONS cannot be trusted: willStartLiveMagnify
    /// never fired for pinches forwarded through the text view (isLiveMagnifying
    /// stayed false through entire gestures), and AppKit's past-the-limit
    /// magnification BOUNCE animates `magnification` after didEnd with no
    /// notification at all. So the detector below observes the VALUE itself.
    private var lastDetectedMagnification: CGFloat = 1

    /// Value-based zoom detection, called from the clip-view bounds observer on
    /// every bounds event: any magnification mutation — gesture frame, elastic
    /// bounce frame, tick, or projection — opens/extends the freeze window and
    /// returns true so the caller can skip per-frame work and re-arm the settle.
    func detectMagnificationMutation() -> Bool {
        guard abs(magnification - lastDetectedMagnification) > 0.0001 else { return false }
        lastDetectedMagnification = magnification
        noteMagnificationChanged()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if liveMagnifyObservers.isEmpty {
            liveMagnifyObservers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveMagnifyNotification, object: self, queue: .main
            ) { [weak self] _ in
                self?.beginUserMagnification(at: nil)
                self?.isLiveMagnifying = true
                MainActor.assumeIsolated { ScrollTrace.beginLiveGesture("magnify") }
            })
            // Report the end of a live pinch (native NSScrollView magnify gesture).
            liveMagnifyObservers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isHandlingMagnifyGesture = false
                self.isLiveMagnifying = false
                MainActor.assumeIsolated { ScrollTrace.endLiveGesture("magnify") }
                self.noteMagnificationChanged()
                self.onMagnificationChanged?(self.magnification)
                // Width-fitted blocks (tables/diagrams/images) re-fit to the new
                // effective width once the gesture settles (ADR-0019).
                self.nativeTextView?.magnificationDidSettle()
            })
            // Scroller drags and wheel gestures bracket a live scroll; every
            // origin change inside the bracket is the user's own.
            liveMagnifyObservers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ScrollTrace.beginLiveGesture("scroll") }
            })
            liveMagnifyObservers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: self, queue: .main
            ) { _ in
                MainActor.assumeIsolated { ScrollTrace.endLiveGesture("scroll") }
            })
        }
    }

    deinit {
        for observer in liveMagnifyObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func scrollWheel(with event: NSEvent) {
        ScrollTrace.noteUserGesture("wheel")
        // Ctrl+scroll = zoom around the cursor (PDF parity), when visual zoom is on.
        if allowsMagnification, event.modifierFlags.contains(.control), event.scrollingDeltaY != 0 {
            let leftFit = onUserMagnificationBegan?(contentView.convert(event.locationInWindow, from: nil)) ?? false
            let factor = event.scrollingDeltaY > 0 ? ctrlScrollZoomFactor : 1 / ctrlScrollZoomFactor
            let target = min(max(magnification * factor, minMagnification), maxMagnification)
            if target != magnification {
                // `centeredAt` is in the content (clip) view's coordinate system —
                // convert the cursor there so the zoom anchors under the pointer.
                noteMagnificationChanged()
                ScrollTrace.noteUserGesture("ctrlScrollZoom")
                setMagnification(target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
                onMagnificationChanged?(magnification)
                clampToInsets()
                // Debounced inside the text view — a tick burst re-fits once.
                nativeTextView?.magnificationDidSettle()
            } else if leftFit {
                // Leaving Fit is a manual intent even when its restored normal
                // minimum makes a downward tick numerically unchanged.
                noteMagnificationChanged()
                onMagnificationChanged?(magnification)
                nativeTextView?.magnificationDidSettle()
            }
            return
        }
        super.scrollWheel(with: event)
        // The clip view keeps its own bounds inside the document and owns the
        // rubber band past it; clamping here after every wheel event cut that
        // overshoot on the frame it appeared. Only a height measured too small
        // needs help, and that is a remeasure, not a move.
        rescueStaleHeightIfNeeded()
    }

    /// When the clip sits at (or past) the bottom the engine believes the
    /// document has, remeasure once per 250 ms without touching the origin: a
    /// discrete wheel tick with no relayout otherwise found a stale small
    /// height and could not scroll on ("scroll doesn't work" in the field).
    func rescueStaleHeightIfNeeded() {
        guard !isZoomInProgress, !isLiveMagnifying, let doc = documentView else { return }
        let container = doc as? NativeTextViewContainer
        let realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        let bounds = contentView.bounds
        let maxY = max(restingOriginY, realHeight - bounds.height)
        guard bounds.origin.y >= maxY - 1, let textView = container?.textView,
              CACurrentMediaTime() - lastClampRescue > 0.25 else { return }
        lastClampRescue = CACurrentMediaTime()
        ScrollTrace.stamp("heightRescue")
        textView.pendingFullLayoutMeasure = true
        textView.recalcOverscroll(for: self)
    }

    /// Where the clip rests at the top of the note: the bars' height in the note's
    /// points, as a zoom leaves it (-64 / 1.5625 = -40.96 at 156%, -80 at 80%).
    /// Clamping to -64 at every zoom held a zoomed-out note under the bars and left a
    /// zoomed-in one past its rest for the next scroll to take up.
    var restingOriginY: CGFloat { -contentInsets.top / max(magnification, 0.01) }

    /// Laying out in a new window, AppKit constrains a zoomed-out clip to the insets at
    /// full size (-63.75 at 80%), moving a note at its top down under the bars.
    override func tile() {
        let before = contentView.bounds.minY
        super.tile()
        guard magnification < 1, before < 0, before >= restingOriginY - 1,
              contentView.bounds.minY > before + 0.5 else { return }
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: before))
    }

    /// A magnification set before the clip had its size leaves its bounds at scale 1
    /// until AppKit's next layout, which then rescales the origin too: a landing made
    /// in between ends at 1/zoom of the way down. So a landing brings the scale in first.
    func settleClipScale() {
        let clip = contentView
        guard magnification > 0, abs(clip.bounds.width * magnification - clip.frame.width) > 0.5 else { return }
        clip.setBoundsSize(NSSize(width: clip.frame.width / magnification, height: clip.frame.height / magnification))
    }

    func clampToInsets() {
        // Never fight a zoom in flight. Field forensics: after a pinch past
        // maxMagnification, AppKit ANIMATES the magnification back within
        // limits, re-anchoring the origin each frame — clamping against it
        // produced a ±144pt thrash at 120Hz for half a second ("jumping
        // around"). The zoom settle re-clamps once, after the window closes.
        guard !isZoomInProgress else { return }
        guard let doc = documentView else { return }
        let minY = restingOriginY
        // Use the real content height (not the inflated frame) so small
        // documents can't scroll past their actual content. The document view is
        // always a `NativeTextViewContainer` (header band + text column).
        let container = doc as? NativeTextViewContainer
        var realHeight = container?.scrollableContentHeight ?? doc.bounds.height
        let b = contentView.bounds

        var maxY = max(minY, realHeight - b.height)
        var clampedY = min(max(b.origin.y, minY), maxY)

        // `scrollableContentHeight` comes from a cached TextKit-2 measurement that can
        // under-measure (estimate-based heights after block reveals/collapses). A
        // continuous trackpad refreshes it mid-gesture, but a discrete device (mouse
        // wheel, Ploopy trackball) sends one event with no relayout — so a stale-small
        // height clamps the tick straight back = "scroll doesn't work". When a
        // clamp-back would ACTUALLY happen, force one fresh full-layout re-measure and
        // re-derive the clamp. Three gates keep the full-document measure off hot
        // paths (field: "zooming is very laggy"):
        // - the real clamp, not "imminent": under zoom-out the viewport's doc-point
        //   height can exceed the content height at EVERY scroll position, so the old
        //   proximity test held permanently and the rescue ran per scroll tick;
        // - not during a live pinch: nothing restyles mid-gesture, so the height
        //   cannot be stale — while shrinking maxY clamps on every magnify frame;
        // - 250ms throttle for clamp bursts (zoom-out steps near the bottom).
        if clampedY != b.origin.y, !isLiveMagnifying,
           let textView = container?.textView,
           CACurrentMediaTime() - lastClampRescue > 0.25 {
            lastClampRescue = CACurrentMediaTime()
            ScrollTrace.stamp("clampRescue")
            textView.pendingFullLayoutMeasure = true
            textView.recalcOverscroll(for: self)
            realHeight = container?.scrollableContentHeight ?? doc.bounds.height
            maxY = max(minY, realHeight - b.height)
            clampedY = min(max(b.origin.y, minY), maxY)
        }

        if clampedY != b.origin.y {
            ScrollTrace.stamp(String(format: "clampToInsets(Δ%.1f, minY=%.1f, maxY=%.1f)",
                                     clampedY - b.origin.y, minY, maxY))
            contentView.scroll(to: NSPoint(x: b.origin.x, y: clampedY))
            reflectScrolledClipView(contentView)
        }
    }
}
