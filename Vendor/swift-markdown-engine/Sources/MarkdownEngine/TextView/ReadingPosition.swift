//
//  ReadingPosition.swift
//  MarkdownEngine
//
//  Where the reader is, expressed in the document's own terms: the source line at
//  the top of the viewport and how far into the viewport its top sits. Unlike a
//  raw scroll offset it survives everything that reflows the text above it — a
//  font change, a window resize, an edit, a zoom step, a remount that styles
//  the note again — so a tab switch, a split, a tear-off, a reload or a relaunch
//  can land on the same line. The host persists it; the engine reads and
//  restores it through `MarkdownEditorController`.
//

import AppKit

public struct ReadingPosition: Codable, Equatable, Sendable {
    /// Document UTF-16 offset of the source line at the top of the viewport.
    /// Older persisted paragraph starts remain valid first-line anchors.
    public var anchorOffset: Int
    /// Distance from the viewport's top edge down to the containing line's top,
    /// in document points (negative when the line starts above the viewport). That
    /// edge is the clip's, which runs on above the text under the host's bars, so a
    /// note a little way down from its top reads as far as it has moved.
    public var offsetInViewport: CGFloat
    /// The view magnification the position was read at.
    public var magnification: CGFloat

    public init(anchorOffset: Int, offsetInViewport: CGFloat, magnification: CGFloat = 1) {
        self.anchorOffset = anchorOffset
        self.offsetInViewport = offsetInViewport
        self.magnification = magnification
    }
}

/// A restore the host asks for once: the same position handed to the editor a
/// second time (a SwiftUI update with an unchanged prop) must not scroll again,
/// so every request carries its own token.
public struct ReadingPositionRequest: Equatable, Sendable {
    public var position: ReadingPosition
    public var token: UUID

    public init(_ position: ReadingPosition, token: UUID = UUID()) {
        self.position = position
        self.token = token
    }
}

extension NativeTextView {
    /// The reading position of the current viewport, or nil when nothing is
    /// laid out or the view is hidden, which has no viewport to read: the first
    /// laid-out source line whose frame reaches below the viewport's top edge
    /// (plus a small tolerance), and its top relative to that edge.
    /// O(visible fragments); never forces layout.
    func readingPosition(probeY requestedProbeY: CGFloat? = nil) -> ReadingPosition? {
        guard !isHiddenOrHasHiddenAncestor, let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let scrollView = enclosingScrollView else { return nil }
        let visible = visibleRect
        let origin = textContainerOrigin
        let probeY = requestedProbeY ?? visible.minY + 8
        let clip = scrollView.contentView
        let clipTop = convert(clip.bounds, from: clip).minY
        var found: ReadingPosition?
        let start = tlm.textViewportLayoutController.viewportRange?.location ?? tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard fragment.state == .layoutAvailable else { return true }
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.maxY <= probeY { return true }
            if frame.minY > visible.maxY { return false }
            guard let line = fragment.textLineFragment(
                forVerticalOffset: probeY - frame.minY, requiresExactMatch: false
            ), let elementRange = fragment.textElement?.elementRange,
               line.characterRange.location != NSNotFound,
               let lineLocation = tcm.location(elementRange.location, offsetBy: line.characterRange.location) else { return true }
            let anchor = tcm.offset(from: tcm.documentRange.location, to: lineLocation)
            guard anchor != NSNotFound else { return true }
            found = ReadingPosition(
                anchorOffset: anchor,
                offsetInViewport: frame.minY + line.typographicBounds.minY - min(visible.minY, clipTop),
                magnification: scrollView.magnification
            )
            return false
        }
        return found
    }

    /// How far the clip moves to put a line at `offset` below the viewport's top edge,
    /// from where the clip is: an editor just built rests above the text. A place of
    /// exactly 0 is what a position saved before that edge was the clip's reads for
    /// anywhere from the bars down to the text's top: it leaves a clip already there
    /// where it is, and brings any other back to the bars.
    private func restoreDelta(toLineAt lineTop: CGFloat, offsetInViewport: CGFloat) -> CGFloat {
        let target = lineTop - offsetInViewport
        guard let scrollView = enclosingScrollView else { return target - visibleRect.minY }
        let clip = scrollView.contentView
        let clipTop = convert(clip.bounds, from: clip).minY
        if abs(target) > 0.01 { return target - clipTop }
        return clipTop <= 0 ? 0 : -scrollView.contentInsets.top / max(scrollView.magnification, 0.01) - clip.bounds.minY
    }

    /// The source offset of the line a quarter of the way down the text's
    /// visible area (below the top inset): Find and outline jumps land a
    /// heading just above it, so the host's "current section" reads here.
    func readingLineOffset() -> Int? {
        guard let scrollView = enclosingScrollView else { return nil }
        let visible = visibleRect
        let top = visible.minY + scrollView.contentInsets.top
        return readingPosition(probeY: top + max(0, visible.maxY - top) * 0.25)?.anchorOffset
    }

    /// Scrolls so the anchor's containing line sits `offsetInViewport` below the
    /// viewport's top edge after reflow, landing through `scroll(by:landing:)`
    /// so a far anchor is not left on estimates. Returns false when the anchor
    /// is out of range.
    @discardableResult
    func restore(_ position: ReadingPosition) -> Bool {
        let length = (string as NSString).length
        guard position.anchorOffset >= 0, position.anchorOffset <= length else { return false }
        _ = (delegate as? NativeTextViewCoordinator)?.revealFoldedSource(NSRange(location: position.anchorOffset, length: 0))
        let anchor = min(position.anchorOffset, max(0, length - 1))
        guard let top = lineFrame(at: anchor)?.minY else { return false }
        ScrollTrace.stamp(String(format: "readingPositionRestore(anchor=%d)", position.anchorOffset))
        scroll(by: restoreDelta(toLineAt: top, offsetInViewport: position.offsetInViewport), landing: anchor)
        return true
    }
}
