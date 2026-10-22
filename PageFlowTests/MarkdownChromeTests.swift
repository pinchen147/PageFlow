//
//  MarkdownChromeTests.swift
//  PageFlowTests
//
//  S7b shared-chrome pure logic: the markdown heading outline, the word-count
//  chip, the content-kind → icon / toolbar-set mapping, and the format-command
//  bus posting. All headless — no mounted editor, no window.
//

import AppKit
import Testing
import MarkdownEngine
@testable import PageFlow

@MainActor
struct MarkdownChromeTests {

    // MARK: - (a) Heading outline

    @Test
    func outlineExtractsHeadingsWithLevelsAndLineIndex() {
        let text = """
        # Title
        Some text
        ## Section A
        ```
        # not a heading (inside a fence)
        ```
        ### Sub B ###
        """
        let items = MarkdownOutline.parse(text)

        #expect(items.map(\.title) == ["Title", "Section A", "Sub B"])
        #expect(items.map(\.level) == [1, 2, 3])
        #expect(items.map(\.lineIndex) == [0, 2, 6])   // the fenced `#` at line 4 is skipped
    }

    @Test
    func outlineIgnoresNonHeadingsAndEmptyText() {
        #expect(MarkdownOutline.parse("").isEmpty)
        #expect(MarkdownOutline.parse("just a paragraph\nwith no headings").isEmpty)
        // 7 `#` is not a heading (max ATX depth is 6); `#nospace` is not a heading.
        #expect(MarkdownOutline.parse("####### too deep\n#nospace").isEmpty)
    }

    @Test
    func outlineKeepsTrailingHashFusedToWord() {
        // `# C#` — the trailing `#` is fused to the word, NOT a closing sequence
        // (CommonMark requires whitespace before a closing `#` run), so it stays.
        #expect(MarkdownOutline.parse("# C#").map(\.title) == ["C#"])
        // A whitespace-preceded closing run IS stripped (`## Done ##` → `Done`).
        #expect(MarkdownOutline.parse("## Done ##").map(\.title) == ["Done"])
        // A content that is entirely a closing run yields an empty title.
        #expect(MarkdownOutline.parse("# ###").map(\.title) == [""])
    }

    // MARK: - (b) Word count

    @Test
    func wordCountHandlesEmptyWhitespaceWordsAndUnicode() {
        #expect(WordCount.count("").words == 0)
        #expect(WordCount.count("").characters == 0)

        #expect(WordCount.count("   \n\t  ").words == 0)   // whitespace-only → no words

        let three = WordCount.count("hello world foo")
        #expect(three.words == 3)
        #expect(three.characters == 15)

        // Grapheme clusters: "a 😀 b" → 3 words, 5 characters (emoji counts as one).
        let emoji = WordCount.count("a 😀 b")
        #expect(emoji.words == 3)
        #expect(emoji.characters == 5)

        let cases: [(String, Int, Int)] = [
            ("a\r\nb", 2, 3),
            ("e\u{301}", 1, 1),
            ("\u{600}a", 1, 1),
            ("👩‍👩‍👧‍👦 🇺🇳", 2, 3),
            (" \u{301}a", 1, 2),
            ("\u{2003}\u{301}b", 1, 2),
            ("1\u{FE0F}\u{20E3}", 1, 1),
            ("a\u{200D}b", 1, 2)
        ]
        for (text, words, characters) in cases {
            let storage = NSTextStorage(string: text)
            for source in [text, NSMutableString(string: text) as String, storage.string] {
                #expect(WordCount.count(source) == WordCount(words: words, characters: characters))
            }
        }
    }

    // MARK: - (c) Content-kind → icon / toolbar set

    @Test
    func contentKindMapsToDistinctIconsAndToolbarSets() {
        #expect(ContentKind.pdf.tabIconSystemName == "doc.richtext")
        #expect(ContentKind.markdown.tabIconSystemName == "text.alignleft")
        #expect(ContentKind.pdf != ContentKind.markdown)

        // The toolbar carries D11's set; the Format menu carries every command.
        // the reference editor's host toolbar: the marks live on the selection bar.
        #expect(MarkdownFormatCommand.toolbar == [.table, .checklist])
        #expect(MarkdownFormatCommand.insertMenu == [.bulletedList, .checklist, .codeBlock, .divider, .heading, .heading2,
                                                     .heading3, .numberedList, .quote])
        #expect(Set(MarkdownFormatCommand.toolbar).isSubset(of: MarkdownFormatCommand.allCases))
    }

    @Test
    func formatHelpNamesTheShortcutThatTriggersIt() {
        #expect(MarkdownFormatCommand.link.help == "Link (⌘K)")
        #expect(MarkdownFormatCommand.bulletedList.help == "Bulleted List (⇧⌘8)")
        // ⌘E stays PageFlow's Add Comment (owner, 2026-10-14): Code names no shortcut.
        #expect(MarkdownFormatCommand.code.help == "Code")
    }

}
