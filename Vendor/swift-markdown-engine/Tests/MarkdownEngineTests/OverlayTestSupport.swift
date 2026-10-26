//
//  OverlayTestSupport.swift
//  MarkdownEngineTests
//
//  Shared helper for the wide-table overlay suites. Grids exist only inside
//  the laid-out viewport band, so tests must bring a table on screen before
//  asserting its overlay. `scrollRangeToVisible` is NOT reliable for far,
//  un-laid-out targets in offscreen harness windows (TextKit 2 has only an
//  estimate to scroll to, and may not move at all) — this helper forces full
//  layout first (fine in tests), then scrolls the clip view to the measured
//  position.
//

import AppKit
@testable import MarkdownEngine

@MainActor
func revealWideTable(_ textView: NativeTextView, needle: String = "| 方法") {
    let loc = (textView.string as NSString).range(of: needle).location
    guard loc != NSNotFound,
          let tlm = textView.textLayoutManager,
          let bridge = textView.layoutBridge,
          let container = bridge.firstTextContainer,
          let scrollView = textView.enclosingScrollView else { return }
    tlm.ensureLayout(for: tlm.documentRange)
    let rect = bridge.boundingRect(forCharacterRange: NSRange(location: loc, length: 1), in: container)
    guard !rect.isEmpty else { return }
    let target = NSPoint(x: scrollView.contentView.bounds.origin.x,
                         y: max(0, rect.minY + textView.textContainerOrigin.y - 250))
    scrollView.contentView.scroll(to: target)
    scrollView.reflectScrolledClipView(scrollView.contentView)
}
