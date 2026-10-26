//
//  TableFullWidthModeTests.swift
//  MarkdownEngineTests
//
//  The overlay mode PageFlow ACTUALLY runs since the side-margin change:
//  readingWidth == nil (full-width container, textInsets = margins). Every
//  other table test exercises the reading-column breakout path — this suite
//  pins the non-breakout path with real edits through the real wrapper.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table overlay full-width mode", .serialized)
struct TableFullWidthModeTests {

    final class Host {
        var text: String
        var sideMargin: CGFloat = 24
        init(_ t: String) { text = t }
    }

    struct Harness: View {
        let host: Host
        // VALUE property: SwiftUI diffs rootView memberwise — a harness whose
        // only stored property is a reference-type Host makes rootView
        // reassignment a NO-OP (identical reference short-circuits updateNSView;
        // this trap made the first margin-drag test vacuous). Mutated config
        // must live in stored VALUE properties.
        var sideMargin: CGFloat
        var body: some View {
            NativeTextViewWrapper(
                text: Binding(get: { host.text }, set: { host.text = $0 }),
                configuration: {
                    // PageFlow's ACTUAL config since the margin slider: NO
                    // reading column; margins are text-container insets.
                    var c = MarkdownEditorConfiguration.default
                    c.textInsets = TextInsets(horizontal: sideMargin, vertical: 0)
                    c.safeAreaInsets = SafeAreaInsets(top: 90, leading: 0, trailing: 0, bottom: 0)
                    return c
                }(),
                fontSize: 16,
                documentId: "fullwidth",
                isEditable: true
            )
        }
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    private func settle(_ rounds: Int = 8) async {
        for _ in 0..<rounds {
            spin()
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    private func overlapViolations(textView: NativeTextView) -> [String] {
        guard let bridge = textView.layoutBridge,
              let container = bridge.firstTextContainer,
              let storage = textView.textStorage else { return ["no layout stack"] }
        var violations: [String] = []
        let ns = storage.string as NSString
        storage.enumerateAttribute(.scrollableBlockSourceID, in: NSRange(location: 0, length: storage.length), options: []) { value, attrRange, _ in
            guard let sourceID = value as? Int else { return }
            guard let overlay = textView.wideTableOverlays[sourceID] else {
                // Overlays exist only inside the laid-out viewport band;
                // an offscreen table legitimately has none.
                if let band = textView.viewportCharacterRange,
                   NSLocationInRange(attrRange.location, band) {
                    violations.append("no overlay for \(sourceID)")
                }
                return
            }
            let fullRange = (storage.attribute(.scrollableBlockFullRange, at: attrRange.location, effectiveRange: nil) as? NSValue).map { AnchorRelativeRange.decode($0, anchorLocation: attrRange.location) }
                ?? ns.paragraphRange(for: attrRange)
            if fullRange.location > 1 {
                let above = ns.paragraphRange(for: NSRange(location: fullRange.location - 2, length: 0))
                let aboveRect = bridge.boundingRect(forCharacterRange: above, in: container)
                let aboveMaxY = textView.textContainerOrigin.y + aboveRect.maxY
                if overlay.frame.minY < aboveMaxY - 1.0 {
                    violations.append("overlay minY \(overlay.frame.minY) < above maxY \(aboveMaxY)")
                }
            }
            if NSMaxRange(fullRange) < ns.length - 1 {
                let below = ns.paragraphRange(for: NSRange(location: NSMaxRange(fullRange) + 1, length: 0))
                let belowRect = bridge.boundingRect(forCharacterRange: below, in: container)
                let belowMinY = textView.textContainerOrigin.y + belowRect.minY
                if overlay.frame.maxY > belowMinY + 1.0 {
                    violations.append("overlay maxY \(overlay.frame.maxY) > below minY \(belowMinY)")
                }
            }
        }
        return violations
    }

    /// The user's ACTUAL document (repro.md as of the field report), verbatim.
    static let fieldDoc: String = (try? String(
        contentsOf: URL(fileURLWithPath: "/tmp/pageflow-repro/repro.md"), encoding: .utf8
    )) ?? ""

    // Local repro-only: exercises the user's real field doc. Skipped gracefully
    // when /tmp/pageflow-repro/repro.md is absent (fresh checkout / CI / after a
    // /tmp cleanup) rather than hard-failing on a missing local fixture — the peer
    // field-doc suites (Resize/UndoRedo) instead embed a fallback copy.
    @Test("field doc: typing anywhere keeps every overlay on its band",
          .enabled(if: !TableFullWidthModeTests.fieldDoc.isEmpty))
    func fieldDocTypingKeepsBands() async throws {
        let host = Host(Self.fieldDoc)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: Harness(host: host, sideMargin: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        defer { window.orderOut(nil) }
        let textView = try #require(findEditor(in: hosting))
        await settle()
        print("FWREPRO overlays after mount: \(textView.wideTableOverlays.count)")
        print("FWREPRO baseline: \(overlapViolations(textView: textView))")

        // Real keystroke in the paragraph above the wide table.
        let ns = textView.string as NSString
        let loc = ns.range(of: "独特贡献").location
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.insertText("编", replacementRange: textView.selectedRange())
        await settle()
        print("FWREPRO after edit: \(overlapViolations(textView: textView))")
        #expect(overlapViolations(textView: textView).isEmpty)

        // FIELD SUSPECT: drag the margins slider — updateNSView reconciles
        // textContainerInset LIVE, reflowing ALL text, with no overlay
        // reconcile trigger. The overlay must follow its anchor.
        hosting.rootView = Harness(host: host, sideMargin: 120)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        print("FWREPRO after margin drag 24→120: \(overlapViolations(textView: textView))")
        #expect(overlapViolations(textView: textView).isEmpty, "margin change must not strand the overlay")

        hosting.rootView = Harness(host: host, sideMargin: 8)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        print("FWREPRO after margin drag 120→8: \(overlapViolations(textView: textView))")
        #expect(overlapViolations(textView: textView).isEmpty)

        // And an edit AFTER the margin change (the field "any edit").
        textView.insertText("辑", replacementRange: textView.selectedRange())
        await settle()
        print("FWREPRO edit after margin: \(overlapViolations(textView: textView))")
        #expect(overlapViolations(textView: textView).isEmpty)
    }
}
