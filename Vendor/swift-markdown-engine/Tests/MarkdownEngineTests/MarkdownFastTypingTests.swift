//
//  MarkdownFastTypingTests.swift
//  MarkdownEngineTests
//
//  Regression coverage for the native editor's burst-typing hot path.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown fast typing path")
struct MarkdownFastTypingTests {

    private final class State {
        var text: String
        var isWikiLinkActive = false

        init(text: String) {
            self.text = text
        }
    }

    private func makeCoordinatorAndTextView(text: String) -> (NativeTextViewCoordinator, NativeTextView, State) {
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
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        textView.string = text
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        return (coordinator, textView, state)
    }

    @Test("selection changes during a pending edit do not parse the document")
    func pendingEditSelectionChangeAvoidsFullDocumentParse() {
        let text = largeFixture(target: "target")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let insertion = (text as NSString).range(of: "target").location + 3

        coordinator.cachedParsedChars = nil
        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: insertion, length: 0),
            replacementString: "x"
        )
        #expect(shouldChange)

        textView.setSelectedRange(NSRange(location: insertion + 1, length: 0))
        coordinator.textViewDidChangeSelection(Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        ))

        #expect(coordinator.cachedParsedChars == nil)
        #expect(coordinator.pendingEditedRange != nil)
        #expect(coordinator.previousCaretLocation == insertion + 1)
    }

    @Test("plain typing inside bold uses the fast path")
    func plainTypingInsideBoldUsesFastPath() {
        let text = largeFixture(target: "**target**")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: target.location + 3, length: 0),
            tokens: coordinator.cachedParsedDocument?.tokens ?? [],
            in: text as NSString
        )
        coordinator.previousActiveTokenIndices = coordinator.activeTokenIndices
        coordinator.cachedParsedChars = nil

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: target.location + 3, length: 0),
            replacementString: "x"
        )
        #expect(shouldChange)
        textView.replaceCharacters(in: NSRange(location: target.location + 3, length: 0), with: "x")
        textView.setSelectedRange(NSRange(location: target.location + 4, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textView.string.contains("**tarxget**"))
        #expect(coordinator.cachedParsedChars == nil)
        let parsed = coordinator.parsedDocument(for: textView.string)
        #expect(parsed.tokens.contains {
            $0.kind == .bold && $0.contentRange.length == "tarxget".utf16.count
        })
        let insertedAttributes = textView.textStorage?.attributes(at: target.location + 3, effectiveRange: nil)
        let insertedFont = insertedAttributes?[.font] as? NSFont
        #expect(insertedFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test("plain typing inside italic uses the fast path")
    func plainTypingInsideItalicUsesFastPath() {
        let text = largeFixture(target: "*target*")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: target.location + 3, length: 0),
            tokens: coordinator.cachedParsedDocument?.tokens ?? [],
            in: text as NSString
        )
        coordinator.previousActiveTokenIndices = coordinator.activeTokenIndices
        coordinator.cachedParsedChars = nil

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: target.location + 3, length: 0),
            replacementString: "x"
        )
        #expect(shouldChange)
        textView.replaceCharacters(in: NSRange(location: target.location + 3, length: 0), with: "x")
        textView.setSelectedRange(NSRange(location: target.location + 4, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textView.string.contains("*tarxget*"))
        #expect(coordinator.cachedParsedChars == nil)
        let parsed = coordinator.parsedDocument(for: textView.string)
        #expect(parsed.tokens.contains {
            $0.kind == .italic && $0.contentRange.length == "tarxget".utf16.count
        })
        let insertedAttributes = textView.textStorage?.attributes(at: target.location + 3, effectiveRange: nil)
        let insertedFont = insertedAttributes?[.font] as? NSFont
        #expect(insertedFont?.fontDescriptor.symbolicTraits.contains(.italic) == true)
    }

    @Test("plain typing inside underline uses the fast path")
    func plainTypingInsideUnderlineUsesFastPath() {
        let text = largeFixture(target: "<u>target</u>")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")

        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: target.location + 2, length: 0),
            tokens: coordinator.cachedParsedDocument?.tokens ?? [],
            in: text as NSString
        )
        coordinator.previousActiveTokenIndices = coordinator.activeTokenIndices
        coordinator.cachedParsedChars = nil

        let shouldChange = coordinator.textView(
            textView,
            shouldChangeTextIn: NSRange(location: target.location + 2, length: 0),
            replacementString: "x"
        )
        #expect(shouldChange)
        textView.replaceCharacters(in: NSRange(location: target.location + 2, length: 0), with: "x")
        textView.setSelectedRange(NSRange(location: target.location + 3, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        #expect(textView.string.contains("<u>taxrget</u>"))
        #expect(coordinator.cachedParsedChars == nil)
        let parsed = coordinator.parsedDocument(for: textView.string)
        #expect(parsed.tokens.contains {
            $0.kind == .underline && $0.contentRange.length == "taxrget".utf16.count
        })
        let insertedAttributes = textView.textStorage?.attributes(at: target.location + 2, effectiveRange: nil)
        #expect(insertedAttributes?[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test("burst typing inside active bold stays on the fast path")
    func burstTypingInsideActiveBoldStaysFast() {
        let text = largeFixture(target: "**target**")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        let target = (text as NSString).range(of: "target")
        var insertion = target.location + 3

        coordinator.activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: insertion, length: 0),
            tokens: coordinator.cachedParsedDocument?.tokens ?? [],
            in: text as NSString
        )
        coordinator.previousActiveTokenIndices = coordinator.activeTokenIndices
        coordinator.cachedParsedChars = nil

        for _ in 0..<10 {
            let range = NSRange(location: insertion, length: 0)
            #expect(coordinator.textView(textView, shouldChangeTextIn: range, replacementString: "x"))
            textView.replaceCharacters(in: range, with: "x")
            insertion += 1
            textView.setSelectedRange(NSRange(location: insertion, length: 0))
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            #expect(coordinator.cachedParsedChars == nil)
        }

        #expect(textView.string.contains("**tar" + String(repeating: "x", count: 10) + "get**"))
        let insertedAttributes = textView.textStorage?.attributes(at: insertion - 1, effectiveRange: nil)
        let insertedFont = insertedAttributes?[.font] as? NSFont
        #expect(insertedFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let parsed = coordinator.parsedDocument(for: textView.string)
        #expect(parsed.tokens.contains {
            $0.kind == .bold && $0.contentRange.length == "tarxxxxxxxxxxget".utf16.count
        })
    }

    @Test("plain burst before later tokens reparses on demand")
    func plainBurstBeforeLaterTokensReparsesOnDemand() {
        let text = largeFixture(target: "target\n**after**")
        let (coordinator, textView, _) = makeCoordinatorAndTextView(text: text)
        var insertion = (text as NSString).range(of: "target").location + 3

        coordinator.previousActiveTokenIndices = []
        coordinator.cachedParsedChars = nil

        for _ in 0..<5 {
            let range = NSRange(location: insertion, length: 0)
            #expect(coordinator.textView(textView, shouldChangeTextIn: range, replacementString: "x"))
            textView.replaceCharacters(in: range, with: "x")
            insertion += 1
            textView.setSelectedRange(NSRange(location: insertion, length: 0))
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            #expect(coordinator.cachedParsedChars == nil)
        }

        let parsed = coordinator.parsedDocument(for: textView.string)
        let after = (textView.string as NSString).range(of: "after")
        #expect(parsed.tokens.contains {
            $0.kind == .bold && $0.contentRange.location == after.location
        })
    }

    private func largeFixture(target: String) -> String {
        let prefix = (0..<2_000).map { "plain line \($0) with text" }.joined(separator: "\n")
        let suffix = (2_000..<4_000).map { "plain line \($0) with text" }.joined(separator: "\n")
        return prefix + "\n" + target + "\n" + suffix
    }
}
