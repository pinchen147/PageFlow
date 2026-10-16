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
    /// in document points (negative when the line starts above the viewport).
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
    /// laid out: the first laid-out source line whose frame reaches below the
    /// viewport's top edge (plus a small tolerance), and its top relative to
    /// that edge. O(visible fragments); never forces layout.
    func readingPosition() -> ReadingPosition? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let scrollView = enclosingScrollView else { return nil }
        let visible = visibleRect
        let origin = textContainerOrigin
        let probeY = visible.minY + 8
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
                offsetInViewport: frame.minY + line.typographicBounds.minY - visible.minY,
                magnification: scrollView.magnification
            )
            return false
        }
        return found
    }

    /// Scrolls so the anchor's containing line sits `offsetInViewport` below the
    /// viewport's top edge after reflow, landing through `scroll(by:landing:)`
    /// so a far anchor is not left on estimates. Returns false when the anchor
    /// is out of range.
    @discardableResult
    func restore(_ position: ReadingPosition) -> Bool {
        let length = (string as NSString).length
        guard position.anchorOffset >= 0, position.anchorOffset <= length else { return false }
        let anchor = min(position.anchorOffset, max(0, length - 1))
        guard let top = lineFrame(at: anchor)?.minY else { return false }
        ScrollTrace.stamp(String(format: "readingPositionRestore(anchor=%d)", position.anchorOffset))
        scroll(by: top - visibleRect.minY - position.offsetInViewport, landing: anchor)
        return true
    }
}
