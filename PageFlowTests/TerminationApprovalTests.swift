import AppKit
import MarkdownEngine
import Testing
@testable import PageFlow

@MainActor
struct TerminationApprovalTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test(arguments: [false, true])
    func aRecoveredDraftArrivingDuringQuitRevokesApproval(save: Bool) throws {
        let delegate = try #require(AppDelegate.shared)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        let original = try #require(owner.activeSession)
        original.content.markdown?.documentManager.text = "Pending draft"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
        }
        var savePanels = 0
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in
            owner.restoreRecoveredMarkdown(.init(id: UUID(), title: "Arrived during quit", source: "Recovered draft", updatedAt: Date()))
            return save ? .save : .discard
        }, saveURL: { _ in savePanels += 1; return nil }))
        #expect(savePanels == 0)
        #expect(result == .terminateCancel)
        #expect(!delegate.terminationApproved)
        #expect(owner.tabs.count == 2)
        #expect(owner.sessions[original.id] === original)
        #expect(owner.activeMarkdownContent?.documentManager.text == "Recovered draft")
        #expect(owner.activeMarkdownContent?.documentManager.isDirty == true)
    }

    @Test
    func aCommentEditDuringQuitRevokesDiscard() throws {
        let delegate = try #require(AppDelegate.shared)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        let content = try #require(owner.activeMarkdownContent)
        content.documentManager.text = "Draft"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
        }
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in
            content.documentManager.setCommentBlock(MarkdownCommentBlock.block(for: [
                MarkdownCommentThread(anchor: MarkdownCommentAnchor(prefix: "", exact: "Draft", suffix: ""), root: MarkdownComment(body: "New comment"))
            ]))
            return .discard
        }, saveURL: { _ in nil }))
        #expect(result == .terminateCancel)
        #expect(content.documentManager.commentBlock.contains("New comment"))
    }

    @Test
    func aDraftArrivingDuringSaveAsCancelsBeforeWritingTheChosenFile() throws {
        let delegate = try #require(AppDelegate.shared)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        owner.activeMarkdownContent?.documentManager.text = "Initial draft"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quit-save-\(UUID()).md")
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: url)
        }
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in
            owner.restoreRecoveredMarkdown(.init(id: UUID(), title: "New arrival", source: "Unreviewed draft", updatedAt: Date()))
            return url
        }))
        #expect(result == .terminateCancel)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(owner.tabs.count == 2)
    }

    @Test
    func aNewEditToAnAlreadySavedDraftCancelsTheLaterSavePanel() throws {
        let delegate = try #require(AppDelegate.shared)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        let first = try #require(owner.activeMarkdownContent)
        first.documentManager.text = "First approved draft"
        owner.newMarkdownDocument()
        owner.activeMarkdownContent?.documentManager.text = "Second approved draft"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quit-series-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("first.md")
        let secondURL = directory.appendingPathComponent("second.md")
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        var panels = 0
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in
            panels += 1
            if panels == 2 {
                first.documentManager.text = "New edit after the first save"
                return secondURL
            }
            return firstURL
        }))
        #expect(result == .terminateCancel)
        #expect(panels == 2)
        #expect(try Data(contentsOf: firstURL) == Data("First approved draft".utf8))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
        #expect(first.documentManager.text == "New edit after the first save")
        #expect(first.documentManager.isDirty)
    }

    @Test
    func anEditInsideTheEncodingDialogCancelsBeforeWriting() async throws {
        let delegate = try #require(AppDelegate.shared)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quit-encoding-\(UUID()).md")
        var original = Data("café\n".utf8)
        original.append(0xFF)
        try original.write(to: url)
        let owner = TabManager()
        await owner.openDocument(url: url, isSecurityScoped: false, bringsToFront: false)?.value
        let content = try #require(owner.activeMarkdownContent)
        content.documentManager.text = "Approved edit"
        try #require(content.documentManager.hasInvalidUTF8)
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: url)
        }
        owner.invalidUTF8SavePrompt = { _ in content.documentManager.text = "Unreviewed edit"; return true }
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in nil }))
        #expect(result == .terminateCancel)
        #expect(try Data(contentsOf: url) == original)
        #expect(content.documentManager.text == "Unreviewed edit")
        #expect(content.documentManager.isDirty)
    }

    @Test
    func aSuccessfulSaveAsWithPastedImagesStillAllowsQuit() throws {
        let delegate = try #require(AppDelegate.shared)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-image-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fallback = PastedImageStore.fallbackAttachmentsFolder
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let image = fallback.appendingPathComponent("quit-\(UUID()).png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        try bytes.write(to: image)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        let content = try #require(owner.activeMarkdownContent)
        content.documentManager.text = "![Chart](<\(image.path)>)\n"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        let url = root.appendingPathComponent("note.md")
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: image)
        }
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in .save }, saveURL: { _ in url }))
        #expect(result == .terminateNow)
        #expect(!content.documentManager.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "![Chart](attachments/\(image.lastPathComponent))\n")
        #expect(try Data(contentsOf: root.appendingPathComponent("attachments").appendingPathComponent(image.lastPathComponent)) == bytes)
    }

    @Test(arguments: [false, true])
    func anUnchangedQuitDecisionStillSucceeds(save: Bool) throws {
        let delegate = try #require(AppDelegate.shared)
        let owner = TabManager(createInitialTab: false)
        owner.newMarkdownDocument()
        owner.activeMarkdownContent?.documentManager.text = "Approved draft"
        let window = window()
        WindowRegistry.shared.register(owner, window: window)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quit-control-\(UUID()).md")
        defer {
            WindowRegistry.shared.unregister(owner)
            for session in owner.sessions.values { session.cleanup() }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: url)
        }
        let result = delegate.confirmTermination(using: DocumentClosePrompt(decide: { _ in save ? .save : .discard }, saveURL: { _ in url }))
        #expect(result == .terminateNow)
        #expect(delegate.terminationApproved)
        if save { #expect(try Data(contentsOf: url) == Data("Approved draft".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    }
}
