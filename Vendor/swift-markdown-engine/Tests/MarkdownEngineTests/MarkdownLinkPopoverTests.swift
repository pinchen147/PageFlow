import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// the reference editor's link dialog (doc 24 §6.7).
@MainActor
@Suite("Link dialog", .serialized)
struct MarkdownLinkPopoverTests {
    @Test("URL normalisation follows the reference editor's rules", arguments: [
        ("example.com", "https://example.com"),
        ("  https://example.com/a  ", "https://example.com/a"),
        ("go/x", "http://go/x"),
        ("someone@example.com", "mailto:someone@example.com"),
        ("#section", "#section"),
        ("/path with space", "/path%20with%20space"),
        ("tel:+1 555 0100", "tel:+15550100"),
        ("see https://example.com now", "https://example.com"),
        ("C:\\docs\\x", ""),
        ("//cdn.example.com", ""),
        ("localhost", ""),
        ("javascript:alert(1)", ""),
        ("two words", ""),
    ])
    func normalisation(input: String, expected: String) {
        switch MarkdownLinkURL.normalize(input) {
        case .success(let url): #expect(url == expected)
        case .failure: #expect(expected.isEmpty, "\(input) was refused")
        }
    }

    @Test("a link over 2048 bytes is refused as too long")
    func tooLong() {
        #expect(MarkdownLinkURL.normalize("https://e.com/" + String(repeating: "a", count: 2_100)) == .failure(.tooLong))
    }

    @Test("Markdown escapes brackets in the text and percent-encodes unbalanced parentheses")
    func markdownEscaping() {
        #expect(MarkdownLinkURL.markdown(text: "a [b]", url: "https://e.com/x_(y)") == "[a \\[b\\]](https://e.com/x_(y))")
        #expect(MarkdownLinkURL.markdown(text: "t", url: "https://e.com/x)") == "[t](https://e.com/x%29)")
    }

    final class Host { var text: String; init(_ t: String) { text = t } }

    private func mount(_ source: String) throws -> (NativeTextViewCoordinator, NativeTextView, NSWindow) {
        _ = NSApplication.shared
        let host = Host(source)
        var configuration = MarkdownEditorConfiguration.default
        configuration.showsSelectionBar = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        let wrapper = NativeTextViewWrapper(text: Binding(get: { host.text }, set: { host.text = $0 }),
                                            configuration: configuration, fontSize: 16, documentId: UUID().uuidString,
                                            undoManager: undo)
        let coordinator = wrapper.makeCoordinator()
        let scroll = wrapper.makeNativeView(coordinator: coordinator)
        let view = try #require(scroll.nativeTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = scroll
        window.orderBack(nil)
        wrapper.updateNativeView(scroll, coordinator: coordinator)
        window.makeFirstResponder(view)
        return (coordinator, view, window)
    }

    @Test("Link on a plain selection opens edit mode; Save writes [text](url) as one Undo step")
    func saveOnSelection() async throws {
        let (coordinator, view, window) = try mount("Read the docs today\n")
        defer { window.close() }
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 9, length: 4))
        coordinator.apply(.link)
        let popover = try #require(bar.linkPopover)
        #expect(popover.mode == .edit)
        #expect(popover.target.text == "docs")
        popover.saveForTesting(text: "docs", url: "example.com/docs")
        #expect(view.string == "Read the [docs](https://example.com/docs) today\n")
        #expect(bar.linkPopover == nil)
        view.undoManager?.undo()
        #expect(view.string == "Read the docs today\n")
    }

    @Test("Link inside an existing link edits the whole link; Remove leaves its text")
    func editAndRemove() async throws {
        let (coordinator, view, window) = try mount("See [old](https://old.example) here\n")
        defer { window.close() }
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 6, length: 1))
        coordinator.apply(.link)
        let popover = try #require(bar.linkPopover)
        #expect(popover.target.isExistingLink)
        #expect(popover.target.url == "https://old.example")
        popover.saveForTesting(text: "new", url: "https://new.example")
        #expect(view.string == "See [new](https://new.example) here\n")
        #expect(bar.showLinkActions(at: 6))
        let actions = try #require(bar.linkPopover)
        #expect(actions.mode == .actions)
        actions.removeForTesting()
        #expect(view.string == "See new here\n")
    }

    @Test("an invalid link keeps the dialog open with the reference editor's message")
    func invalidLink() async throws {
        let (coordinator, view, window) = try mount("Read the docs today\n")
        defer { window.close() }
        let bar = try #require(coordinator.selectionBar)
        view.setSelectedRange(NSRange(location: 9, length: 4))
        coordinator.apply(.link)
        let popover = try #require(bar.linkPopover)
        popover.saveForTesting(text: "docs", url: "not a link")
        #expect(bar.linkPopover === popover)
        #expect(popover.errorForTesting == "That doesn't look like a link")
        #expect(view.string == "Read the docs today\n")
        popover.close()
    }
}
