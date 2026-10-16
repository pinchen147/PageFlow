import AppKit
import PDFKit
import Testing
@testable import PageFlow

@MainActor
struct WindowCloseApprovalTests {
    @MainActor
    private final class OriginalDelegate: NSObject, NSWindowDelegate {
        var allowsClose = true
        var approvals = 0
        var moves = 0
        var closes = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            approvals += 1
            return allowsClose
        }
        func windowDidMove(_ notification: Notification) { moves += 1 }
        func windowWillClose(_ notification: Notification) { closes += 1 }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func drafts() throws -> (TabManager, TabSession, TabSession) {
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        let first = try #require(owner.activeSession)
        first.content.markdown?.documentManager.text = "first e\u{301} 😀\n"
        owner.newMarkdownDocument()
        let second = try #require(owner.activeSession)
        second.content.markdown?.documentManager.text = "second draft\n"
        return (owner, first, second)
    }

    @Test
    func originalDelegateVetoAndOptionalCallbacksSurviveInstallation() throws {
        let owner = TabManager(createInitialTab: false)
        let window = window()
        defer { window.close() }
        let original = OriginalDelegate()
        original.allowsClose = false
        window.delegate = original
        var prompts = 0
        let gate = WindowCloseCoordinator(window: window, manager: owner,
            prompt: DocumentClosePrompt(decide: { _ in prompts += 1; return .discard }, saveURL: { _ in nil }))
        #expect(!gate.windowShouldClose(window))
        #expect(original.approvals == 1)
        #expect(prompts == 0)
        let selector = #selector(NSWindowDelegate.windowDidMove(_:))
        try #require(gate.responds(to: selector))
        _ = gate.perform(selector, with: Notification(name: NSWindow.didMoveNotification, object: window))
        #expect(original.moves == 1)
        gate.detach()
        #expect(window.delegate === original)
    }

    @Test
    func laterCancelKeepsEverySessionAndItsEdits() throws {
        let (owner, first, second) = try drafts()
        let ids = owner.tabs.map(\.id)
        var decisions = 0
        let allowed = owner.confirmWindowClose(using: DocumentClosePrompt(decide: { _ in
            decisions += 1
            return decisions == 1 ? .discard : .cancel
        }, saveURL: { _ in nil }))
        #expect(!allowed)
        #expect(decisions == 2)
        #expect(owner.tabs.map(\.id) == ids)
        #expect(owner.sessions[first.id] === first)
        #expect(owner.sessions[second.id] === second)
        #expect(first.content.markdown?.documentManager.text == "first e\u{301} 😀\n")
        #expect(second.content.markdown?.documentManager.text == "second draft\n")
        #expect(first.isDirty && second.isDirty)
    }

    @Test
    func untitledSavePersistsAndUpdatesIdentityEvenIfLaterTabCancels() throws {
        let (owner, first, second) = try drafts()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("close-save-\(UUID()).md")
        defer { try? FileManager.default.removeItem(at: url) }
        var decisions = 0
        let allowed = owner.confirmWindowClose(using: DocumentClosePrompt(decide: { _ in
            decisions += 1
            return decisions == 1 ? .save : .cancel
        }, saveURL: { _ in url }))
        #expect(!allowed)
        #expect(try Data(contentsOf: url) == Data("first e\u{301} 😀\n".utf8))
        #expect(owner.tabs.first { $0.id == first.id }?.documentURL == url)
        #expect(owner.tabID(for: url) == first.id)
        #expect(!first.isDirty && second.isDirty)
        #expect(owner.sessions[first.id] === first && owner.sessions[second.id] === second)
    }

    @Test(arguments: [false, true])
    func saveAsCancellationOrFailureKeepsTheUntitledTab(failWrite: Bool) throws {
        let (owner, first, _) = try drafts()
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("close-blocker-\(UUID())")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let allowed = owner.confirmDocumentClose(first, using: DocumentClosePrompt(
            decide: { _ in .save }, saveURL: { _ in failWrite ? blocker.appendingPathComponent("draft.md") : nil }))
        #expect(!allowed)
        #expect(owner.sessions[first.id] === first)
        #expect(first.isDirty)
        #expect(first.content.markdown?.documentManager.documentURL == nil)
        #expect(first.content.markdown?.documentManager.text == "first e\u{301} 😀\n")
    }

    @Test
    func newEditsRevokeAnEarlierDiscardApproval() throws {
        let (owner, first, _) = try drafts()
        var decisions = 0
        let allowed = owner.confirmWindowClose(using: DocumentClosePrompt(decide: { _ in
            decisions += 1
            if decisions == 2 { first.content.markdown?.documentManager.text = "new edit during another prompt" }
            return .discard
        }, saveURL: { _ in nil }))
        #expect(!allowed)
        #expect(owner.tabs.count == 2)
        #expect(first.content.markdown?.documentManager.text == "new edit during another prompt")
    }

    @Test
    func replacingPDFWhileApprovalIsPendingCannotApproveItsReplacement() throws {
        let owner = TabManager()
        let session = try #require(owner.activeSession)
        let manager = try #require(session.pdfManager)
        let initial = PDFDocument()
        initial.insert(PDFPage(), at: 0)
        manager.document = initial
        manager.isDirty = true
        let replacement = PDFDocument()
        replacement.insert(PDFPage(), at: 0)
        let allowed = owner.confirmDocumentClose(session, using: DocumentClosePrompt(decide: { _ in
            manager.document = replacement
            manager.isDirty = true
            return .discard
        }, saveURL: { _ in nil }))
        #expect(!allowed)
        #expect(manager.document === replacement)
        #expect(owner.activeSession === session)
    }

    @Test
    func actualCloseCleansSessionsAndUnregistersBeforeForwardingWillClose() throws {
        let (owner, first, second) = try drafts()
        let window = window()
        let original = OriginalDelegate()
        window.delegate = original
        WindowRegistry.shared.register(owner, window: window)
        defer { WindowRegistry.shared.unregister(owner) }
        // close() is the already-approved/programmatic route, unlike performClose.
        window.close()
        #expect(original.closes == 1)
        #expect(WindowRegistry.shared.window(for: owner) == nil)
        #expect(owner.tabs.isEmpty && owner.sessions.isEmpty)
        #expect(first.content.markdown?.documentManager.isClosed == true)
        #expect(second.content.markdown?.documentManager.isClosed == true)
    }
}
