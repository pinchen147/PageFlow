//
//  ScopedBusTests.swift
//  MarkdownEngineTests
//
//  PageFlow fork patch P2 (doc 16 / ADR-0010 §P2): verifies the scoped editor
//  bus isolates two warm coordinators sharing `NotificationCenter.default`. A
//  Bold posted with `object: idA` mutates only A's storage; B is untouched. Also
//  asserts the default (`scopeByObject == false`) bus preserves the legacy
//  broadcast: a nil-object post reaches every coordinator.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Scoped editor bus (P2)")
struct ScopedBusTests {

    private final class State {
        var text: String
        var isWikiLinkActive = false
        init(text: String) { self.text = text }
    }

    /// Builds a live coordinator + text view, assigns the given configuration
    /// (which re-subscribes the bus observers via the `configuration` didSet) and
    /// documentId. Mirrors `MarkdownInlineFormattingShortcutTests`'s setup.
    private func makeCoordinator(
        text: String,
        documentId: String,
        bus: MarkdownEditorBus
    ) -> (NativeTextViewCoordinator, NativeTextView, State) {
        _ = NSApplication.shared
        let state = State(text: text)
        let coordinator = NativeTextViewCoordinator(
            text: Binding(get: { state.text }, set: { state.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14,
            isWikiLinkActive: Binding(get: { state.isWikiLinkActive }, set: { state.isWikiLinkActive = $0 }),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.bus = bus
        coordinator.documentId = documentId
        // Assigning `configuration` triggers `subscribeToBusNotifications`.
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        textView.string = text
        textView.delegate = coordinator
        coordinator.textView = textView
        _ = coordinator.parsedDocument(for: text)
        return (coordinator, textView, state)
    }

    private func scopedBus(id: String) -> MarkdownEditorBus {
        MarkdownEditorBus(
            applyBoldRequest: Notification.Name("pf.test.bold.\(id)"),
            scopeByObject: true
        )
    }

    @Test("scopeByObject: a Bold posted for tab A leaves tab B unmodified")
    func scopedBoldReachesOnlyTargetTab() {
        let boldName = Notification.Name("pf.test.bold.shared")
        let busA = MarkdownEditorBus(applyBoldRequest: boldName, scopeByObject: true)
        let busB = MarkdownEditorBus(applyBoldRequest: boldName, scopeByObject: true)

        let (coordA, tvA, _) = makeCoordinator(text: "alpha word", documentId: "A", bus: busA)
        let (_, tvB, _) = makeCoordinator(text: "beta word", documentId: "B", bus: busB)

        tvA.setSelectedRange((tvA.string as NSString).range(of: "word"))
        tvB.setSelectedRange((tvB.string as NSString).range(of: "word"))

        // Post the Bold request stamped for A only (shared name, scoped by object).
        NotificationCenter.default.post(name: boldName, object: "A")

        #expect(tvA.string.contains("**word**"))
        #expect(!tvB.string.contains("**word**"))
        #expect(tvB.string == "beta word")
        // Keep the coordinator alive past the assertions.
        withExtendedLifetime(coordA) {}
    }

    @Test("scopeByObject: a non-matching object is dropped (neither tab mutates)")
    func scopedBoldForUnknownTabIsDropped() {
        let boldName = Notification.Name("pf.test.bold.unknown")
        let (_, tvA, _) = makeCoordinator(
            text: "alpha word", documentId: "A",
            bus: MarkdownEditorBus(applyBoldRequest: boldName, scopeByObject: true)
        )
        tvA.setSelectedRange((tvA.string as NSString).range(of: "word"))

        NotificationCenter.default.post(name: boldName, object: "Z")

        #expect(tvA.string == "alpha word")
    }

    @Test("legacy default bus (scopeByObject == false) still broadcasts on nil object")
    func legacyBusBroadcasts() {
        let boldName = Notification.Name("pf.test.bold.legacy")
        // Default scopeByObject == false → object filter always accepts.
        let (_, tvA, _) = makeCoordinator(
            text: "alpha word", documentId: "A",
            bus: MarkdownEditorBus(applyBoldRequest: boldName)
        )
        tvA.setSelectedRange((tvA.string as NSString).range(of: "word"))

        NotificationCenter.default.post(name: boldName, object: nil)

        #expect(tvA.string.contains("**word**"))
    }
}
