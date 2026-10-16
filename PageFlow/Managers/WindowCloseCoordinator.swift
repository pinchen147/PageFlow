import AppKit
import PDFKit

/// Native modal UI is kept at the approval boundary. No tab is removed while
/// these decisions are pending, including when a later document cancels close.
@MainActor
struct DocumentClosePrompt {
    enum Decision { case save, cancel, discard }
    var decide: (String) -> Decision
    var saveURL: (String) -> URL?

    static var live: Self {
        Self(decide: { title in
            let alert = NSAlert()
            alert.icon = NSApp.applicationIconImage
            alert.messageText = "Do you want to save changes to \"\(title)\"?"
            alert.informativeText = "Your changes will be lost if you don't save."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .save
            case .alertThirdButtonReturn: return .discard
            default: return .cancel
            }
        }, saveURL: { MarkdownSavePanel.runModal(defaultName: $0) })
    }
}

/// A modal alert runs a nested event loop. Keep approval bound to both the exact
/// session and its source state; replacement, transfer or new edits revoke it.
@MainActor
private struct CloseSnapshot {
    let session: TabSession
    private let unchanged: (Bool) -> Bool

    init(_ session: TabSession) {
        self.session = session
        switch session.content {
        case .pdf(let content):
            let manager = content.pdfManager
            let document = manager.document
            let url = manager.documentURL
            let revision = manager.closeRevision
            unchanged = { allowingSavedURL in
                manager.document === document && (allowingSavedURL || manager.documentURL == url) &&
                    manager.closeRevision == revision
            }
        case .markdown(let content):
            content.reconcileLiveText()
            let manager = content.documentManager
            let text = manager.text
            let url = manager.documentURL
            unchanged = { allowingSavedURL in
                content.reconcileLiveText()
                return !manager.isClosed && (allowingSavedURL || manager.documentURL == url) &&
                    manager.text.utf8.elementsEqual(text.utf8)
            }
        }
    }

    func matches(_ owner: TabManager, allowingSavedURL: Bool = false) -> Bool {
        owner.sessions[session.id] === session && owner.tabs.contains { $0.id == session.id } && unchanged(allowingSavedURL)
    }
}

extension TabManager {
    func confirmWindowClose(using prompt: DocumentClosePrompt? = nil) -> Bool {
        let prompt = prompt ?? .live
        flushMarkdownEditors()
        let initialIDs = tabs.map(\.id)
        let candidates = initialIDs.compactMap { sessions[$0] }.map(CloseSnapshot.init)
        guard candidates.count == initialIDs.count else { return false }
        var approved: [CloseSnapshot] = []
        for candidate in candidates {
            guard candidate.matches(self),
                  confirmDocumentClose(candidate.session, using: prompt) else { return false }
            approved.append(CloseSnapshot(candidate.session))
        }
        return tabs.map(\.id) == initialIDs && approved.allSatisfy { $0.matches(self) }
    }

    /// Shared by tab close, replacement and native whole-window close.
    func confirmDocumentClose(_ session: TabSession, using prompt: DocumentClosePrompt? = nil) -> Bool {
        let prompt = prompt ?? .live
        let snapshot = CloseSnapshot(session)
        guard snapshot.matches(self) else { return false }
        let document = session.content.document
        guard document.isDirty else { return true }
        let decision = prompt.decide(document.documentTitle)
        guard snapshot.matches(self) else { return false }
        switch decision {
        case .cancel: return false
        case .discard: return true
        case .save:
            let saved: Bool
            if document.needsSaveAs {
                guard let url = prompt.saveURL(document.documentTitle), snapshot.matches(self) else { return false }
                saved = saveDocumentAsSync(session, to: url, isSecurityScoped: true, expectedDocument: document)
            } else {
                saved = DirtyDoc(session: session, owner: self).saveSync()
            }
            guard saved, snapshot.matches(self, allowingSavedURL: true) else { return false }
            return !document.isDirty
        }
    }

    /// Runs only once the native window really closes, never during approval.
    func finishWindowClose() {
        flushMarkdownEditors()
        flushActiveTabViewState()
        closeFilePicker()
        for tab in tabs { ClosedTabStore.shared.record(tab) }
        for id in Array(sessions.keys) { closeSession(for: id) }
        tabs.removeAll()
        activeTabID = nil
        unlockQueue.removeAll()
    }
}

/// Preserves the delegate installed by SwiftUI (or NSWindowController). AppKit
/// queries optional selectors when assigning delegates, so forwarding includes
/// responds(to:) as well as the messages themselves.
@MainActor
final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private weak var manager: TabManager?
    private weak var original: (any NSWindowDelegate)?
    private var isApproving = false
    private var isClosing = false
    private let prompt: DocumentClosePrompt

    init(window: NSWindow, manager: TabManager, prompt: DocumentClosePrompt? = nil) {
        self.window = window
        self.manager = manager
        self.original = window.delegate
        self.prompt = prompt ?? .live
        super.init()
        window.delegate = self
    }

    func detach() {
        guard !isClosing, let window, window.delegate === self else { return }
        window.delegate = original
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return MainActor.assumeIsolated { original?.responds(to: aSelector) == true }
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        MainActor.assumeIsolated { original }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isApproving else { return false }
        isApproving = true
        defer { isApproving = false }
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        guard sender === window, let manager else { return true }
        return manager.confirmWindowClose(using: prompt)
    }

    func windowWillClose(_ notification: Notification) {
        let delegate = original
        isClosing = true
        if let window, let manager {
            WindowRegistry.shared.finishClose(of: manager, window: window)
        }
        delegate?.windowWillClose?(notification)
    }
}
