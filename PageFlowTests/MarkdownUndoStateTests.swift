//
//  MarkdownUndoStateTests.swift
//  PageFlowTests
//
//  The Markdown side of per-tab undo + UI state: `TabSession` must route the
//  undo stack and availability to the CONTENT that owns them (the "undo not
//  wired for MD" field bug — the old forwarders were `content.pdf?…`, nil for
//  Markdown), and `uiState` must actually store for Markdown tabs (the old
//  PDF-only forwarder silently no-op'd the outline toggle).
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
@Suite("Markdown undo + UI state routing")
struct MarkdownUndoStateTests {

    @Test func markdownSessionRoutesUndoManagerToContent() throws {
        let session = TabSession.markdown(id: UUID())
        let content = try #require(session.content.markdown)
        #expect(session.undoManager === content.undoManager)
    }

    @Test func pdfSessionStillRoutesUndoManagerToPDFContent() throws {
        let session = TabSession(id: UUID())
        let content = try #require(session.content.pdf)
        #expect(session.undoManager === content.undoManager)
    }

    @Test func markdownUndoAvailabilityMirrorsRegistrations() async throws {
        let session = TabSession.markdown(id: UUID())
        let content = try #require(session.content.markdown)
        #expect(session.undoAvailability == UndoAvailability())

        // Explicit grouping: event-driven groups never close in a headless test.
        content.undoManager.groupsByEvent = false
        content.undoManager.beginUndoGrouping()
        content.undoManager.registerUndo(withTarget: content) { _ in }
        content.undoManager.endUndoGrouping()
        // Availability refresh rides the group-close notification, delivered
        // one main-queue turn later — give it a couple.
        for _ in 0..<3 {
            await Task.yield()
            try await Task.sleep(nanoseconds: 30_000_000)
            if session.undoAvailability.canUndo { break }
        }
        #expect(session.undoAvailability.canUndo)
    }

    @Test func uiStateStoresForMarkdownSessions() {
        let session = TabSession.markdown(id: UUID())
        #expect(!session.uiState.showingOutline)
        session.uiState.showingOutline = true
        #expect(session.uiState.showingOutline, "uiState must persist for Markdown tabs (was a PDF-only no-op)")
    }
}
