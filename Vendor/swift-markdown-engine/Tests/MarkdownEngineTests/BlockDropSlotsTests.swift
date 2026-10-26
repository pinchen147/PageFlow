import Foundation
import Testing
@testable import MarkdownEngine

/// Where drops and block moves land (doc 26 §10.3): block boundaries, never
/// inside a block or a line, and around image lines inside a paragraph.
@Suite("Block drop slots")
struct BlockDropSlotsTests {
    private func slots(_ text: String, window: NSRange? = nil) -> [Int] {
        BlockDropSlots.slots(in: text as NSString, blocks: BlockParser.parse(text, memoizing: false), window: window)
    }

    /// The fenced code and `$$` math ranges, as the coordinator's parse has them.
    private func opaqueRanges(_ text: String) -> [NSRange] {
        MarkdownTokenizer.parseTokensViaAST(in: text)
            .filter { $0.kind == .codeBlock || $0.kind == .blockLatex }
            .map(\.range)
            .sorted { $0.location < $1.location }
    }

    private func offset(of marker: String, in text: String) -> Int {
        (text as NSString).range(of: marker).location
    }

    @Test("every top-level block start and the end of the note")
    func blockStarts() {
        let text = "# Title\n\nPara one\nstill one\n\n- a\n- b\n\n> quote\n\n---\n\nEnd"
        #expect(slots(text) == [0, offset(of: "Para", in: text), offset(of: "- a", in: text),
                                offset(of: "> quote", in: text), offset(of: "---", in: text),
                                offset(of: "End", in: text), (text as NSString).length])
    }

    @Test("no slot inside fenced code or $$ math with blank lines, a table or a list")
    func opaqueBlocks() {
        let text = "A\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n$$\nx\n\ny\n$$\n\n| t | u |\n| - | - |\n| 1 | 2 |\n\n- one\n- two\n\nB"
        let found = slots(text)
        let code = (text as NSString).range(of: "```swift\nlet a = 1\n\nlet b = 2\n```")
        let math = (text as NSString).range(of: "$$\nx\n\ny\n$$")
        let table = (text as NSString).range(of: "| t | u |\n| - | - |\n| 1 | 2 |")
        let list = (text as NSString).range(of: "- one\n- two")
        for block in [code, math, table, list] {
            #expect(!found.contains { $0 > block.location && $0 < NSMaxRange(block) }, "a slot inside \(block)")
            #expect(found.contains(block.location))
        }
        #expect(found.contains(offset(of: "B", in: text)))
    }

    @Test("an image line under a paragraph has a slot on each side; plain lines have none")
    func imageLineInsideParagraph() {
        for image in ["![shot](shot.png)", #"![shot](a\)b.png)"#, #"![a `]` b](shot.png)"#] {
            let text = "Para text\n\(image)\nMore text\nand more"
            #expect(slots(text) == [0, offset(of: image, in: text), offset(of: "More", in: text), (text as NSString).length])
        }
        let embed = "Line\n  ![[diagram.png]]  \nAfter"
        #expect(slots(embed) == [0, offset(of: "  ![[", in: embed), offset(of: "After", in: embed), (embed as NSString).length])
    }

    @Test("an image inside a line of text is not a slot")
    func inlineImage() {
        for line in ["Before ![icon](i.png) after", #"![shot](a\)b.png) plain suffix"#, #"![a `]` b](shot.png) plain suffix"#] {
            let text = "\(line)\nnext line"
            #expect(slots(text) == [0, (text as NSString).length])
        }
    }

    @Test("an image line's end and the next block's start are one slot")
    func blankSeparatedDuplicates() {
        let text = "Para\n![a](a.png)\n\nNext"
        #expect(slots(text) == [0, offset(of: "![a]", in: text), offset(of: "Next", in: text), (text as NSString).length])
    }

    @Test("a window returns its slots plus the nearest one on each side")
    func window() {
        let text = (0..<50).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        let all = slots(text)
        let start = offset(of: "Paragraph 20", in: text)
        let end = offset(of: "Paragraph 23", in: text)
        let windowed = slots(text, window: NSRange(location: start + 3, length: end - start))
        #expect(windowed.first == start)
        #expect(windowed.last == offset(of: "Paragraph 24", in: text))
        #expect(windowed.allSatisfy(all.contains))
        #expect(windowed.count == 5)
    }

    @Test("an empty note has one slot")
    func emptyNote() {
        #expect(slots("") == [0])
    }

    @Test("a capped scan never invents a boundary inside a contiguous block", arguments: ["line", "- item", "> quote"])
    func cappedScanKeepsOnlyProvenBoundaries(prefix: String) {
        let lines = (0..<24).map { "\(prefix) \($0)" }
        let text = lines.joined(separator: "\n") + "\n\nEnd"
        let ns = text as NSString
        let window = ns.range(of: lines[12])
        let blocks = BlockDropSlots.blocks(around: window, in: ns, opaqueRanges: [], maxLines: 3)
        let found = BlockDropSlots.slots(in: ns, blocks: blocks, window: window)
        let allowed = [0, ns.range(of: "End").location, ns.length]
        #expect(found.allSatisfy(allowed.contains), "a scan limit cannot turn an interior line into a top-level boundary")
    }

    @Test("the inserted block gets exactly one blank line on each side")
    func insertionShape() {
        func insert(_ text: String, at slot: Int) -> (String, Int) {
            let ns = text as NSString
            let insertion = BlockDropSlots.insertion(of: "![x](x.png)", at: slot, in: ns)
            return (ns.replacingCharacters(in: NSRange(location: slot, length: 0), with: insertion.text), slot + insertion.caret)
        }
        // Between blocks.
        var (result, caret) = insert("A\n\nB", at: 3)
        #expect(result == "A\n\n![x](x.png)\n\nB")
        #expect((result as NSString).substring(from: caret) == "\nB")
        // At the start of the note.
        (result, caret) = insert("A", at: 0)
        #expect(result == "![x](x.png)\n\nA")
        #expect(caret == ("![x](x.png)\n" as NSString).length)
        // At the end, with and without a trailing newline.
        (result, caret) = insert("A", at: 1)
        #expect(result == "A\n\n![x](x.png)\n")
        #expect(caret == (result as NSString).length)
        (result, _) = insert("A\n", at: 2)
        #expect(result == "A\n\n![x](x.png)\n")
        // Right under a paragraph line (a single newline before).
        (result, _) = insert("Para\n![a](a.png)", at: 5)
        #expect(result == "Para\n\n![x](x.png)\n\n![a](a.png)")
        // Before blank lines that are already there.
        (result, _) = insert("A\n\n\nB", at: 2)
        #expect(result == "A\n\n![x](x.png)\n\nB")
        // An empty note.
        (result, _) = insert("", at: 0)
        #expect(result == "![x](x.png)\n")
    }

    @Test("the stretch parsed around a window gives the whole-note slots near it")
    func localStretchMatchesWholeNote() {
        var parts: [String] = []
        for index in 0..<40 {
            switch index % 8 {
            case 0: parts.append("# Heading \(index)")
            case 1: parts.append("Para \(index)\nsecond line\n![shot \(index)](pics/\(index).png)\nthird line")
            case 2: parts.append("```swift\nlet a = \(index)\n\n\nlet b = 2\n```")
            case 3: parts.append("$$\nx^\(index)\n\ny\n$$")
            case 4: parts.append("| t | u |\n| - | - |\n| \(index) | 2 |")
            case 5: parts.append("- one\n- two\n- \(index)")
            case 6: parts.append("> quote \(index)\n> more")
            default: parts.append("Para \(index) ![inline](x.png) text\n![[embed \(index).png]]")
            }
        }
        let text = parts.joined(separator: "\n\n") + "\n"
        let ns = text as NSString
        let opaque = opaqueRanges(text)
        let whole = slots(text)
        // Every window start and size the viewport could have.
        for location in stride(from: 0, to: ns.length, by: 7) {
            for length in [0, 40, 200] {
                let window = NSRange(location: location, length: min(length, ns.length - location))
                let local = BlockDropSlots.slots(in: ns, blocks: BlockDropSlots.blocks(around: window, in: ns, opaqueRanges: opaque),
                                                 window: window)
                let expected = BlockDropSlots.slots(in: ns, blocks: BlockParser.parse(text, memoizing: false), window: window)
                #expect(local == expected, "window \(window)")
                #expect(local.allSatisfy(whole.contains), "window \(window)")
            }
        }
    }

    @Test("an image line is one whole image, embeds included")
    func imageLines() {
        func check(_ line: String) -> Bool {
            BlockDropSlots.isImageLine(NSRange(location: 0, length: (line as NSString).length), in: line as NSString)
        }
        #expect(check("![a](b.png)"))
        #expect(check("  ![a [b] \\] c](<my pic (1).png> \"t (x)\")  \n"))
        #expect(check("![[embed.png]]"))
        #expect(check("![alt|300|center](x.png)"))
        #expect(!check("![a](b.png) and text"))
        #expect(!check("![a](b.png) ![c](d.png)"))
        #expect(!check("![[a]] ![[b]]"))
        #expect(!check("text ![a](b.png)"))
        #expect(!check("[a](b.png)"))
    }
}
