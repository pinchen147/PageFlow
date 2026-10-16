//
//  EditClassificationTests.swift
//  MarkdownEngineTests
//
//  Pins the hot-path edit classifier: local Markdown structure changes should
//  leave restyling scoped, while only global delimiters can promote to a full
//  document restyle.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Edit classification")
@MainActor
struct EditClassificationTests {
    private final class TextBox {
        var text: String
        init(_ text: String = "") { self.text = text }
    }

    private final class LatexCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        func record(_ latex: String) {
            lock.lock()
            calls.append(latex)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            calls.removeAll()
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private struct CountingLatexRenderer: LatexRenderer {
        let counter: LatexCallCounter

        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            counter.record(latex)
            let size = CGSize(width: max(1, latex.utf16.count) * 4, height: 8)
            return LatexRenderResult(
                image: NSImage(size: size),
                size: size,
                baselineOffset: 2
            )
        }
    }

    private func makeCoordinator() -> NativeTextViewCoordinator {
        let box = TextBox()
        return NativeTextViewCoordinator(
            text: Binding(
                get: { box.text },
                set: { box.text = $0 }
            ),
            fontName: "SF Pro",
            fontSize: 16,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
    }

    private func makeLatexEditingHarness(
        text: String,
        counter: LatexCallCounter = LatexCallCounter()
    ) -> (coordinator: NativeTextViewCoordinator, textView: NSTextView, counter: LatexCallCounter) {
        let coordinator = makeCoordinator()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(latex: CountingLatexRenderer(counter: counter))
        coordinator.configuration = configuration

        let textView = NSTextView()
        textView.isEditable = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        counter.reset()
        return (coordinator, textView, counter)
    }

    private func requireRenderedMath(
        _ formula: String,
        in textView: NSTextView,
        using coordinator: NativeTextViewCoordinator
    ) throws {
        let storage = try #require(textView.textStorage)
        let text = textView.string as NSString
        let token = try #require(coordinator.parsedDocument(for: textView.string).tokens.first {
            $0.kind == .inlineLatex && text.substring(with: $0.contentRange) == formula
        })
        var image: NSImage?
        storage.enumerateAttribute(.renderedBlockImage, in: token.range) { value, _, stop in
            if let rendered = value as? NSImage {
                image = rendered
                stop.pointee = true
            }
        }
        _ = try #require(image)
    }

    private func performTyping(
        _ replacement: String,
        at location: Int,
        replacing length: Int = 0,
        in textView: NSTextView,
        using coordinator: NativeTextViewCoordinator
    ) {
        let range = NSRange(location: location, length: length)
        #expect(coordinator.textView(textView, shouldChangeTextIn: range, replacementString: replacement))
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.setSelectedRange(NSRange(location: location + replacement.utf16.count, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    @Test func newlineIsLocalStructureOnly() {
        let coordinator = makeCoordinator()
        let text = "alpha beta" as NSString
        let range = NSRange(location: 5, length: 0)

        #expect(coordinator.editMayChangeBlockStructure(
            in: text,
            affectedCharRange: range,
            replacementString: "\n"
        ))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: range,
            replacementString: "\n"
        ))
    }

    @Test func typingALanguageRestylesOnlyItsBlockOnceTheFenceIsAnOpener() {
        let coordinator = makeCoordinator()
        let text = "```p\ncode\n```\n\nprose" as NSString
        let afterP = NSRange(location: 4, length: 0)

        #expect(coordinator.editMayChangeBlockStructure(in: text, affectedCharRange: afterP, replacementString: "y"))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(in: text, affectedCharRange: afterP, replacementString: "y"))
        let deleteP = NSRange(location: 3, length: 1)
        #expect(coordinator.editMayRequireFullDocumentRestyle(in: text, affectedCharRange: deleteP, replacementString: ""))
    }

    @Test(arguments: ["p", "`", "~"])
    func changingABareFenceRequiresFullDocumentRestyle(_ typed: String) {
        let coordinator = makeCoordinator()
        let text = "```\ncode\n```\n\nprose" as NSString
        let afterClosing = NSRange(location: 12, length: 0)

        #expect(coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: afterClosing,
            replacementString: typed
        ))
    }

    @Test func ordinarySpaceStaysPlainText() {
        let coordinator = makeCoordinator()
        let text = "alpha beta" as NSString
        let range = NSRange(location: 5, length: 0)

        #expect(!coordinator.editMayChangeBlockStructure(
            in: text,
            affectedCharRange: range,
            replacementString: " "
        ))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: range,
            replacementString: " "
        ))
    }

    @Test func spaceCompletingHeadingIsLocalStructureOnly() {
        let coordinator = makeCoordinator()
        let text = "#" as NSString
        let range = NSRange(location: 1, length: 0)

        #expect(coordinator.editMayChangeBlockStructure(
            in: text,
            affectedCharRange: range,
            replacementString: " "
        ))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: range,
            replacementString: " "
        ))
    }

    @Test func inlineDollarStaysLocalButBlockDelimitersRequireFullDocumentRestyle() {
        let coordinator = makeCoordinator()
        let text = "alpha" as NSString

        #expect(!coordinator.editMayChangeBlockStructure(
            in: text,
            affectedCharRange: NSRange(location: 5, length: 0),
            replacementString: "$"
        ))
        #expect(coordinator.editMayChangeBlockStructure(
            in: "$alpha" as NSString,
            affectedCharRange: NSRange(location: 1, length: 0),
            replacementString: "$"
        ))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: NSRange(location: 5, length: 0),
            replacementString: "`"
        ))
        #expect(!coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: NSRange(location: 5, length: 0),
            replacementString: "$"
        ))
        #expect(coordinator.editMayRequireFullDocumentRestyle(
            in: "$alpha" as NSString,
            affectedCharRange: NSRange(location: 1, length: 0),
            replacementString: "$"
        ))
        #expect(coordinator.editMayRequireFullDocumentRestyle(
            in: text,
            affectedCharRange: NSRange(location: 5, length: 0),
            replacementString: "$$"
        ))
    }

    @Test func plainProseNewlineUsesFastPath() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        textView.string = "alpha\n beta\n# Heading"
        let oldText = "alpha beta\n# Heading"
        let newText = textView.string as NSString
        coordinator.cachedParsedDocument = coordinator.parsedDocument(for: oldText)
        coordinator.pendingTextChange = NativeTextViewCoordinator.TextChange(
            oldRange: NSRange(location: 5, length: 0),
            replacement: "\n"
        )
        coordinator.pendingEditMayChangeBlockStructure = true
        coordinator.pendingEditRequiresFullDocumentRestyle = false
        coordinator.cachedSpellingDisabled = false

        #expect(coordinator.tryPlainTextEditFastPath(
            textView: textView,
            text: newText,
            selectionRange: NSRange(location: 6, length: 0),
            editedRange: NSRange(location: 5, length: 1)
        ))
    }

    @Test func listLikeNewlineStaysOnStructuralPath() {
        let coordinator = makeCoordinator()
        let textView = NSTextView()
        textView.string = "- item\n"
        let oldText = "- item"
        let newText = textView.string as NSString
        coordinator.cachedParsedDocument = coordinator.parsedDocument(for: oldText)
        coordinator.pendingTextChange = NativeTextViewCoordinator.TextChange(
            oldRange: NSRange(location: 6, length: 0),
            replacement: "\n"
        )
        coordinator.pendingEditMayChangeBlockStructure = true
        coordinator.pendingEditRequiresFullDocumentRestyle = false
        coordinator.cachedSpellingDisabled = false

        #expect(!coordinator.tryPlainTextEditFastPath(
            textView: textView,
            text: newText,
            selectionRange: NSRange(location: 7, length: 0),
            editedRange: NSRange(location: 6, length: 1)
        ))
    }

    @Test func editingOneLatexSpanDoesNotRerenderEveryOtherLatexSpan() {
        let formulas = (0..<12).map { "$x\($0)$" }.joined(separator: "\n")
        let harness = makeLatexEditingHarness(text: formulas)
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))
        harness.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: harness.textView)
        )
        harness.counter.reset()

        performTyping("a", at: 2, in: harness.textView, using: harness.coordinator)

        #expect(harness.counter.snapshot.isEmpty)
    }

    @Test func typingSingleDollarDoesNotRerenderExistingLatexSpansElsewhere() {
        let formulas = (0..<12).map { "$x\($0)$" }.joined(separator: "\n")
        let text = "plain\n" + formulas
        let harness = makeLatexEditingHarness(text: text)

        performTyping("$", at: 5, in: harness.textView, using: harness.coordinator)

        #expect(harness.counter.snapshot.isEmpty)
    }

    @Test func typingMidProseBacktickRunsDoesNotRerenderDistantMath() throws {
        let harness = makeLatexEditingHarness(text: "plain text\n\n$x$\n\n$y$")
        for formula in ["x", "y"] {
            try requireRenderedMath(formula, in: harness.textView, using: harness.coordinator)
        }
        harness.textView.setSelectedRange(NSRange(location: 5, length: 0))
        harness.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: harness.textView)
        )
        harness.counter.reset()

        for count in 1...4 {
            performTyping("`", at: 4 + count, in: harness.textView, using: harness.coordinator)

            #expect(harness.textView.string == "plain" + String(repeating: "`", count: count) + " text\n\n$x$\n\n$y$")
            #expect(harness.counter.snapshot.isEmpty)
        }
    }

    @Test(arguments: ["```", "~~~"])
    func editingClosingFenceRestylesDownstreamProseAndMath(_ marker: String) throws {
        let initial = marker + "\ncode\n" + marker + "\n\nnear prose\n\nfar prose\n\n$x$"
        let harness = makeLatexEditingHarness(text: initial)
        let storage = try #require(harness.textView.textStorage)
        try requireRenderedMath("x", in: harness.textView, using: harness.coordinator)
        let closing = (initial as NSString).range(of: marker, options: .backwards)
        let editLocation = NSMaxRange(closing) - 1
        harness.textView.setSelectedRange(NSRange(location: editLocation, length: 0))
        harness.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: harness.textView)
        )
        harness.counter.reset()

        performTyping("", at: editLocation, replacing: 1, in: harness.textView, using: harness.coordinator)

        let unclosed = marker + "\ncode\n" + String(marker.dropLast()) + "\n\nnear prose\n\nfar prose\n\n$x$"
        #expect(harness.textView.string == unclosed)
        let distantProse = (unclosed as NSString).range(of: "far prose")
        #expect(storage.attribute(.markdownCode, at: distantProse.location, effectiveRange: nil) as? Int == 2)
        #expect(harness.counter.snapshot.isEmpty)

        performTyping(String(marker.suffix(1)), at: editLocation, in: harness.textView, using: harness.coordinator)

        #expect(harness.textView.string == initial)
        let restoredProse = (initial as NSString).range(of: "far prose")
        #expect(storage.attribute(.markdownCode, at: restoredProse.location, effectiveRange: nil) == nil)
        #expect(harness.counter.snapshot == ["x"])
    }
}
