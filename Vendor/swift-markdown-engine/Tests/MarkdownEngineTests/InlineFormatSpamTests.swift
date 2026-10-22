//
//  InlineFormatSpamTests.swift
//  MarkdownEngineTests
//
//  Field report 2026-07-03: selecting the same text and spamming ⌘U/⌘B/⌘I
//  must TOGGLE the styles on and off. Instead the field produced marker soup
//  ("<u>***</u>***<u>***</u><u>***_</u>**<u>**___**</u>**<u>***18***</u>…").
//  These tests drive the REAL editor path — mounted NativeTextViewWrapper,
//  coordinator context-menu actions (the same methods the app's bus handlers
//  call) — and assert every press sequence stays sane and self-inverting.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@Suite("Inline format toggle spam")
@MainActor
struct InlineFormatSpamTests {
    typealias H = TableOverlayEndToEndTests

    private func settle(_ rounds: Int = 4) async {
        for _ in 0..<rounds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func findEditor(in view: NSView) -> NativeTextView? {
        if let tv = view as? NativeTextView { return tv }
        for sub in view.subviews {
            if let found = findEditor(in: sub) { return found }
        }
        return nil
    }

    private func mount(_ text: String) async -> (NSWindow, NativeTextView)? {
        let host = H.Host(text: text)
        let hosting = NSHostingView(rootView: H.EditorHarnessView(host: host, configuration: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        await settle()
        guard let tv = findEditor(in: hosting) else { return nil }
        return (window, tv)
    }

    private func press(_ style: MarkdownInlineStyle, _ tv: NativeTextView) async {
        let coordinator = tv.delegate as? NativeTextViewCoordinator
        switch style {
        case .bold: coordinator?.didMarkdownBold(nil)
        case .italic: coordinator?.didMarkdownItalic(nil)
        case .underline: coordinator?.didMarkdownUnderline(nil)
        case .strikethrough, .highlight: coordinator?.applyInlineStyle(style)
        }
        await settle()
    }

    /// Marker soup detector: marker-only fragments inside <u>…</u>, doubled
    /// tags, or runaway growth.
    private func soupIndicators(_ text: String) -> [String] {
        var found: [String] = []
        for bad in ["<u><u>", "</u></u>", "<u>*</u>", "<u>**</u>", "<u>***</u>", "****", "<u></u>"] {
            if text.contains(bad) { found.append(bad) }
        }
        return found
    }

    @Test("spamming one style on the same selection just toggles it")
    func singleStyleSpamToggles() async throws {
        for style in [MarkdownInlineStyle.underline, .bold, .italic] {
            let (window, tv) = try #require(await mount("before 18 after"))
            defer { window.orderOut(nil) }
            let ns = tv.string as NSString
            tv.setSelectedRange(ns.range(of: "18"))

            let original = tv.string
            var texts: [String] = []
            for _ in 0..<4 {
                await press(style, tv)
                texts.append(tv.string)
            }
            print("SPAM \(style): \(texts)")
            // Odd presses = styled, even presses = back to the original.
            #expect(texts[1] == original, "double \(style) must round-trip, got '\(texts[1])'")
            #expect(texts[3] == original, "quadruple \(style) must round-trip, got '\(texts[3])'")
            #expect(texts[0] == texts[2], "odd presses must agree, got '\(texts[0])' vs '\(texts[2])'")
            for t in texts {
                #expect(soupIndicators(t).isEmpty, "soup \(soupIndicators(t)) in '\(t)'")
            }
        }
    }

    @Test("spamming U B I U B I on the same selection stays sane and inverts")
    func stackedSpamStaysSane() async throws {
        let (window, tv) = try #require(await mount("before 18 after"))
        defer { window.orderOut(nil) }
        let ns = tv.string as NSString
        tv.setSelectedRange(ns.range(of: "18"))
        let original = tv.string

        let sequence: [MarkdownInlineStyle] = [
            .underline, .bold, .italic,   // stack all three on
            .underline, .bold, .italic,   // spam again — each must toggle OFF
        ]
        var log: [String] = []
        for style in sequence {
            await press(style, tv)
            log.append("\(style): \(tv.string)")
            #expect(soupIndicators(tv.string).isEmpty,
                    "soup \(soupIndicators(tv.string)) after \(style): '\(tv.string)'")
            #expect(tv.string.utf16.count < original.utf16.count + 30,
                    "runaway growth after \(style): '\(tv.string)'")
        }
        print("SPAM UBI×2 log:\n" + log.joined(separator: "\n"))
        #expect(tv.string == original, "U B I U B I must fully invert, got '\(tv.string)'")
    }
}
