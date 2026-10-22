import PDFKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
@Suite(.serialized)
struct PasswordPromptLifetimeTests {
    enum Action: CaseIterable { case cancel, submit, dismiss }
    enum OwnershipChange: CaseIterable { case transfer, advance, replaceRequest }

    private func fixtures() throws -> (URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("password-owner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("first.pdf")
        let second = directory.appendingPathComponent("second.pdf")
        for url in [first, second] {
            try #require(makeTestDocument(pageCount: 1).write(to: url, withOptions: [
                .userPasswordOption: "shared-secret", .ownerPasswordOption: "shared-secret"
            ]))
            try #require(PDFDocument(url: url)?.isLocked == true)
        }
        return (directory, first, second)
    }

    @Test(arguments: Action.allCases, OwnershipChange.allCases)
    func obsoleteDialogCannotActOnAnotherRequest(action: Action, change: OwnershipChange) throws {
        let (directory, firstURL, secondURL) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = TabManager()
        source.openDocument(url: firstURL, isSecurityScoped: false)
        let first = try #require(source.activeSession)
        let request = try #require(source.pendingPasswordRequest)
        let dialog = TabContainerView.passwordDialog(for: request, in: source)
        let binding = TabContainerView.passwordRequestBinding(in: source)
        let destination = TabManager(createInitialTab: false)
        defer {
            for session in Array(source.sessions.values) + Array(destination.sessions.values) { session.cleanup() }
        }
        if change == .replaceRequest {
            let pdf = try #require(first.pdfManager)
            guard case .needsPassword = pdf.loadDocument(from: secondURL) else {
                Issue.record("Replacement fixture must remain locked"); return
            }
            source.promptForPassword(tabID: first.id, url: secondURL, isSecurityScoped: false,
                                     closeTabOnCancel: false, restoreTabIDOnCancel: nil)
        } else {
            source.openDocument(url: secondURL, isSecurityScoped: false)
            if change == .transfer {
                try #require(source.moveTab(first.id, to: destination, at: 0, closeIfEmpty: false))
            } else {
                source.cancelPasswordPrompt()
            }
        }
        let currentRequest = try #require(source.pendingPasswordRequest)
        let currentSession = try #require(source.sessions[currentRequest.tabID])
        let tabIDs = source.tabs.map(\.id)
        try #require(currentRequest.url == secondURL && currentSession.pdfManager?.hasDocument == false)
        switch action {
        case .cancel: dialog.onCancel()
        case .dismiss: binding.wrappedValue = nil
        case .submit: #expect(!dialog.onSubmit("shared-secret"))
        }
        #expect(source.tabs.map(\.id) == tabIDs)
        #expect(source.sessions[currentSession.id] === currentSession)
        #expect(source.pendingPasswordRequest?.tabID == currentRequest.tabID)
        #expect(source.pendingPasswordRequest?.url == secondURL)
        #expect(currentSession.pendingUnlock != nil)
        #expect(currentSession.pdfManager?.hasDocument == false)
        if change == .transfer {
            #expect(destination.sessions[first.id] === first && first.pendingUnlock?.url == firstURL)
        }
    }

    @Test(arguments: Action.allCases)
    func currentDialogStillHandlesItsOwnRequest(_ action: Action) throws {
        let (directory, firstURL, _) = try fixtures()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = TabManager()
        owner.openDocument(url: firstURL, isSecurityScoped: false)
        let session = try #require(owner.activeSession)
        defer { session.cleanup() }
        let dialog = TabContainerView.passwordDialog(for: try #require(owner.pendingPasswordRequest), in: owner)
        let binding = TabContainerView.passwordRequestBinding(in: owner)
        switch action {
        case .cancel:
            dialog.onCancel()
            #expect(!session.pdfManager!.hasDocument)
        case .dismiss:
            binding.wrappedValue = nil
            #expect(!session.pdfManager!.hasDocument)
        case .submit:
            #expect(dialog.onSubmit("shared-secret"))
            #expect(session.pdfManager?.documentURL == firstURL && session.pdfManager?.hasDocument == true)
        }
        #expect(owner.pendingPasswordRequest == nil)
    }
}
