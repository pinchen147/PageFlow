//
//  WindowCloseTests.swift
//  PageFlowTests
//
//  Closing a window's only tab must close the window itself
//  (closeTab → WindowRegistry.closeWindow).
//

import AppKit
import Testing
@testable import PageFlow

/// Records `close()` calls. The window is NEVER ordered front: a visible test
/// window becoming "the last window" triggers
/// `applicationShouldTerminateAfterLastWindowClosed` in the test host and
/// terminates the whole suite mid-run.
@MainActor
private final class CloseSpyWindow: NSWindow {
    var closeCount = 0
    override func close() {
        closeCount += 1
        super.close()
    }
}

@MainActor
struct WindowCloseTests {
    @Test(arguments: [ContentKind.pdf, .markdown])
    func movingTabBackBeforeDeferredCloseKeepsWindowAlive(kind: ContentKind) async throws {
        let source = TabManager()
        if kind == .markdown { source.newMarkdownDocument() }
        let destination = TabManager(createInitialTab: false)
        let window = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(source, window: window)
        defer { WindowRegistry.shared.unregister(source); window.close() }
        let session = try #require(source.activeSession)

        #expect(source.moveTab(session.id, to: destination, at: 0, select: false))
        #expect(destination.moveTab(session.id, to: source, at: 0, select: false))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(source.tabs.contains { $0.id == session.id })
        #expect(window.closeCount == 0)
    }

    @Test(arguments: [ContentKind.pdf, .markdown])
    func creatingDocumentBeforeEmptyCloseKeepsWindowAlive(kind: ContentKind) async throws {
        let manager = TabManager()
        if kind == .markdown { manager.newMarkdownDocument() }
        let window = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(manager, window: window)
        defer { WindowRegistry.shared.unregister(manager); window.close() }
        let closedTabID = try #require(manager.activeTabID)

        manager.closeTab(closedTabID)
        manager.newMarkdownDocument()
        let newSession = try #require(manager.activeSession)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(newSession.id != closedTabID)
        #expect(manager.activeSession === newSession)
        #expect(window.closeCount == 0)
    }


    @Test
    func closingTheOnlyTabClosesItsWindow() async throws {
        let manager = TabManager()
        let window = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        WindowRegistry.shared.register(manager, window: window)
        defer { WindowRegistry.shared.unregister(manager) }

        let onlyTab = try #require(manager.activeTabID)
        manager.closeTab(onlyTab)

        #expect(manager.tabs.isEmpty)
        // closeWindow defers the actual close by one main-queue turn.
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.closeCount == 1)
    }
}
