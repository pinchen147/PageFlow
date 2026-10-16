//
//  MarkdownTypingPerfTests.swift
//  MarkdownEngineTests
//
//  Guards the per-keystroke "fast typing" optimizations:
//   1. The selection-handler syntax probes (`hrLineRange` / `taskSyntaxRange` /
//      `bulletSyntaxRange`) take `NSString` now so the document is bridged once
//      per caret move — these pin their behavior is unchanged after the switch.
//   2. `baseFontAndStyle()` memoizes the base font + 24-tab paragraph style so it
//      isn't rebuilt on every keystroke.
//   3. A plain insertion stays O(edit): its cost must not scale with document
//      length (ADR-0007 invariant (i)).
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Typing performance")
@MainActor
struct MarkdownTypingPerfTests {

    private final class TextBox {
        var text: String
        init(_ text: String = "") { self.text = text }
    }

    private func makeCoordinator() -> NativeTextViewCoordinator {
        let box = TextBox()
        return NativeTextViewCoordinator(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
    }

    /// A text view inside a fixed-size scroll view, so `visibleRect` is clipped to a
    /// realistic viewport (a screenful) rather than the full document height. Without
    /// the clip, a headless `NSTextView` reports `visibleRect == bounds`, which makes
    /// TextKit-2 lay out the whole document on every edit — a test artifact that does
    /// not occur in the app (it always runs inside `ClampedScrollView`).
    private func makeHarness(text: String) -> (NativeTextViewCoordinator, NSTextView) {
        let coordinator = makeCoordinator()
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let scrollView = NSScrollView(frame: frame)
        let textView = NSTextView(frame: frame)
        textView.isEditable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.layoutSubtreeIfNeeded()
        textView.string = text
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView)
    }

    private func type(
        _ replacement: String,
        at location: Int,
        in textView: NSTextView,
        using coordinator: NativeTextViewCoordinator
    ) {
        let range = NSRange(location: location, length: 0)
        _ = coordinator.textView(textView, shouldChangeTextIn: range, replacementString: replacement)
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(NSRange(location: location + (replacement as NSString).length, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    // MARK: - Syntax-probe correctness (NSString refactor + static HR regex)

    @Test func hrLineRangeMatchesThematicBreakLineOnly() {
        let text = "alpha\n---\nbeta" as NSString
        // Caret on the "---" line (chars 6...8) is a thematic break.
        #expect(MarkdownStyler.hrLineRange(at: 7, in: text) != nil)
        // Caret inside "alpha" is not.
        #expect(MarkdownStyler.hrLineRange(at: 1, in: text) == nil)
        // Two dashes is not an HR.
        #expect(MarkdownStyler.hrLineRange(at: 0, in: "--" as NSString) == nil)
    }

    @Test func taskSyntaxRangeDetectsCheckbox() {
        #expect(MarkdownStyler.taskSyntaxRange(at: 0, in: "- [ ] do it" as NSString) != nil)
        #expect(MarkdownStyler.taskSyntaxRange(at: 0, in: "hello world" as NSString) == nil)
    }

    @Test func bulletSyntaxRangeDetectsMarker() {
        #expect(MarkdownStyler.bulletSyntaxRange(at: 0, in: "- item" as NSString) != nil)
        // No space after the dash → not a bullet marker.
        #expect(MarkdownStyler.bulletSyntaxRange(at: 0, in: "-no space" as NSString) == nil)
    }

    // MARK: - Base-style memoization

    @Test func baseStyleIsMemoizedAndInvalidatedOnInputChange() {
        let coordinator = makeCoordinator()

        let first = coordinator.baseFontAndStyle()
        let second = coordinator.baseFontAndStyle()
        // Same inputs → the exact same cached instances are reused (no rebuild).
        #expect(first.style === second.style)
        #expect(first.font === second.font)
        #expect(first.style.tabStops.count == 24)

        // Changing an input that affects the style forces a rebuild.
        coordinator.fontSize = 22
        let third = coordinator.baseFontAndStyle()
        #expect(third.style !== first.style)
        #expect(third.font.pointSize == 22)
    }

    // MARK: - O(edit) algorithmic guarantee (deterministic)

    /// The strong, wall-clock-independent guarantee: a plain prose insertion takes the
    /// fast path — no whole-document reparse — at any document size. The fast path
    /// records the insertion in `plainInsertionsSinceParse` (it never calls
    /// `parsedDocument(for:)`), whereas the Tier-C fallback re-parses and clears it. So
    /// a recorded insertion after a keystroke proves the O(edit) path ran.
    @Test func plainInsertionTakesFastPathRegardlessOfDocumentLength() {
        for lineCount in [40, 3000] {
            let line = "The quick brown fox jumps over the lazy dog.\n"
            let (coordinator, textView) = makeHarness(text: String(repeating: line, count: lineCount))
            // After rebuild, the cache holds the full source units (non-nil).
            #expect(coordinator.cachedParsedChars != nil)
            type("x", at: 5, in: textView, using: coordinator)
            #expect(coordinator.plainInsertionsSinceParse == [NSRange(location: 5, length: 1)],
                    "plain insertion fell off the fast path at \(lineCount) lines")
        }
    }

    // MARK: - O(edit) scaling guard (wall-clock, pure functions)

    /// The selection handler runs these three membership probes twice on every caret
    /// move. They are line-scoped (a single `lineRange` + one-line regex), so their cost
    /// must not grow with document length. This pins that invariant without any AppKit
    /// layout in the loop, so it is reliable in CI (a full-keystroke wall-clock test
    /// would instead measure headless TextKit-2 layout, which has no bounded viewport
    /// off-screen; real-app per-keystroke timing is captured via os_signpost instead).
    @Test func syntaxProbesAreLineScopedNotDocumentScoped() {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        func probeMedianMs(lineCount: Int) -> Double {
            let line = "The quick brown fox jumps over the lazy dog.\n"
            let doc = String(repeating: line, count: lineCount) as NSString
            let caret = doc.length / 2
            for _ in 0..<50 {
                _ = MarkdownStyler.taskSyntaxRange(at: caret, in: doc)
                _ = MarkdownStyler.hrLineRange(at: caret, in: doc)
                _ = MarkdownStyler.bulletSyntaxRange(at: caret, in: doc)
            }
            var samples: [Double] = []
            for _ in 0..<200 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = MarkdownStyler.taskSyntaxRange(at: caret, in: doc)
                _ = MarkdownStyler.hrLineRange(at: caret, in: doc)
                _ = MarkdownStyler.bulletSyntaxRange(at: caret, in: doc)
                let end = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(end &- start) / 1_000_000.0)
            }
            return median(samples)
        }

        let small = probeMedianMs(lineCount: 40)
        let large = probeMedianMs(lineCount: 6000)

        // 150x longer document → the line-scoped probes must stay essentially flat.
        // Generous bound tolerates CI noise; an O(document) regression fails loudly.
        #expect(large < small * 8 + 0.5,
                "syntax probes scaled with doc length: small=\(small)ms large=\(large)ms")
    }
}
