//
//  ImageAltTokensTests.swift
//  MarkdownEngineTests
//
//  The alt-text token grammar (doc 26 §2): reading from the right in any
//  order, writing width last, and round trips that keep every byte PageFlow
//  did not change.
//

import AppKit
import Testing
@testable import MarkdownEngine

@Suite("Image alt tokens")
struct ImageAltTokensTests {
    private static let chartCrop = CGRect(x: 0.12, y: 0.05, width: 0.8, height: 0.9)

    /// Every row of doc 26 §2.2's table, plus §2.2 point 5.
    @Test(arguments: [
        ("Chart", "Chart", nil, ImageAltTokens.Alignment.left, nil),
        ("Chart|300", "Chart", 300, .left, nil),
        ("Chart|420|center|crop=0.12,0.05,0.80,0.90", "Chart", 420, .center, chartCrop),
        ("Chart|center|crop=0.12,0.05,0.8,0.9|420", "Chart", 420, .center, chartCrop),
        ("|420|right", "", 420, .right, nil),
        ("300", "300", nil, .left, nil),
        ("Q3 | 2024", "Q3 ", 2024, .left, nil),
        (#"Q3 \| 2024"#, #"Q3 \| 2024"#, nil, .left, nil),
        ("a|300|420", "a", 420, .left, nil),
        ("a|crop=0.5,0.5,0.6,0.6", "a|crop=0.5,0.5,0.6,0.6", nil, .left, nil),
        ("a|640x480", "a", 640, .left, nil),
        ("a|foo|420", "a|foo", 420, .left, nil),
    ] as [(String, String, CGFloat?, ImageAltTokens.Alignment, CGRect?)])
    func readsTheSpecTable(_ alt: String, _ description: String, _ width: CGFloat?,
                           _ alignment: ImageAltTokens.Alignment, _ crop: CGRect?) {
        let tokens = ImageAltTokens.parse(alt)
        #expect(tokens.description == description)
        #expect(tokens.width == width)
        #expect(tokens.alignment == alignment)
        #expect(tokens.crop == crop)
    }

    @Test("an escaped pipe is shown as a pipe; spaces around a token are ignored")
    func displayAndTrimming() {
        #expect(ImageAltTokens.parse(#"Q3 \| 2024"#).displayDescription == "Q3 | 2024")
        let spaced = ImageAltTokens.parse("Chart | CENTER |\t300 ")
        #expect(spaced.description == "Chart ")
        #expect(spaced.alignment == .center && spaced.width == 300)
    }

    @Test("a segment that fails any check is description, never half a token", arguments: [
        "a|0", "a|100001", "a|1234567", "a|30.5", "a|-30", "a|middle", "a|crop=0.1,0.1,0.5",
        "a|crop=0.1,0.1,0.005,0.5", "a|crop=1.2,0,0.5,0.5", "a|crop=0.1,0.1,0.5,0.5,0.1", "a|crop=0.1, 0.1,0.5,0.5",
        "a|crop=1e-1,0,0.5,0.5", "a|x480", "a|640x",
    ])
    func invalidSegmentsStayDescription(_ alt: String) {
        let tokens = ImageAltTokens.parse(alt)
        #expect(tokens.description == alt)
        #expect(tokens == ImageAltTokens(description: alt))
    }

    @Test("a full-rect crop is a valid token meaning no crop")
    func fullRectMeansNoCrop() {
        let tokens = ImageAltTokens.parse("a|crop=0.1,0.1,0.5,0.5|crop=0,0,1,1")
        #expect(tokens.description == "a")
        #expect(tokens.crop == nil, "the rightmost crop wins, and it keeps the whole image")
        #expect(ImageAltTokens.parse("a|crop=.5,0,.5,1").crop == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    // MARK: Writing

    @Test("the writer orders align, crop, width last, and leaves defaults out")
    func writerOrder() {
        let tokens = ImageAltTokens(description: "Chart", width: 420, alignment: .center, crop: Self.chartCrop)
        #expect(ImageAltTokens.format(tokens) == "Chart|center|crop=0.12,0.05,0.8,0.9|420")
        #expect(ImageAltTokens.format(ImageAltTokens(description: "Chart")) == "Chart")
        #expect(ImageAltTokens.format(ImageAltTokens(description: "", width: 300, alignment: .right)) == "|right|300")
        #expect(ImageAltTokens.format(ImageAltTokens.parse("Chart|420|center|crop=0.12,0.05,0.80,0.90"))
            == "Chart|center|crop=0.12,0.05,0.8,0.9|420")
    }

    @Test("crop numbers: 4 decimals, shortest form, full rect dropped; width rounds half up")
    func numberFormat() {
        func written(_ crop: CGRect?, width: CGFloat? = nil) -> String {
            ImageAltTokens.format(ImageAltTokens(description: "a", width: width, crop: crop))
        }
        #expect(written(CGRect(x: 0, y: 0.2, width: 0.75, height: 0.8)) == "a|crop=0,0.2,0.75,0.8")
        #expect(written(CGRect(x: 0.123456, y: 0.00004, width: 0.5, height: 0.99999)) == "a|crop=0.1235,0,0.5,1")
        #expect(written(CGRect(x: 0, y: 0, width: 1, height: 1)) == "a")
        #expect(written(CGRect(x: 0.00001, y: 0, width: 0.99996, height: 1)) == "a", "rounds to the full rect")
        #expect(written(nil, width: 336.5) == "a|337")
        #expect(written(nil, width: 336.49) == "a|336")
    }

    @Test("a typed `Q3 | 2024` is written escaped and reads back whole, with no width")
    func escaping() {
        let description = ImageAltTokens.sanitizedDescription("Q3 | 2024")
        #expect(description == #"Q3 \| 2024"#)
        let alone = ImageAltTokens.parse(ImageAltTokens.format(ImageAltTokens(description: description)))
        #expect(alone.width == nil && alone.displayDescription == "Q3 | 2024")
        let sized = ImageAltTokens.parse(ImageAltTokens.format(ImageAltTokens(description: description, width: 300)))
        #expect(sized.width == 300 && sized.displayDescription == "Q3 | 2024")
        #expect(ImageAltTokens.sanitizedDescription(#"a [b] \c"#) == #"a \[b\] \\c"#)
    }

    @Test("sanitising removes controls and bidi marks, collapses whitespace and caps at 2048")
    func sanitising() {
        #expect(ImageAltTokens.sanitizedDescription("  a\tb\nc \u{202E}d\u{200F}  e  ") == "abc d e")
        #expect(ImageAltTokens.sanitizedDescription("👩\u{200D}💻 dev") == "👩\u{200D}💻 dev", "a joiner is not a control")
        let long = String(repeating: "a", count: 2_047) + "😀"
        #expect(ImageAltTokens.sanitizedDescription(long) == String(repeating: "a", count: 2_047),
                "a surrogate pair past the cap is dropped whole")
    }

    @Test("a written description with `\\|`, `\\[` and `\\]` escapes stays one image")
    func escapedDescriptionsParseAsImages() throws {
        let description = ImageAltTokens.sanitizedDescription("Q3 | [draft] 2024")
        let alt = ImageAltTokens.format(ImageAltTokens(description: description, width: 300, alignment: .center))
        let source = "![\(alt)](chart.png)"
        let image = try #require(MarkdownTokenizer.parseTokensViaAST(in: source).first { $0.kind == .imageLink })
        #expect(image.range == NSRange(location: 0, length: (source as NSString).length))
        let reread = ImageAltTokens.parse((source as NSString).substring(with: image.contentRange))
        #expect(reread.displayDescription == "Q3 | [draft] 2024")
        #expect(reread.width == 300 && reread.alignment == .center)
    }

    @Test("a description ending in a lone backslash keeps its meaning when a token follows")
    func trailingBackslash() {
        let written = ImageAltTokens.format(ImageAltTokens(description: #"a\"#, width: 300))
        #expect(written == #"a\\|300"#)
        let reread = ImageAltTokens.parse(written)
        #expect(reread.width == 300 && reread.displayDescription == #"a\"#)
    }

    // MARK: Round trips

    /// doc 26 §2.4: after the first PageFlow write the output is stable, and
    /// the description (unknown segments included) is the source's own bytes.
    @Test("format ∘ parse is stable after one write over 2,000 fuzzed alts")
    func roundTripProperty() {
        let pieces = [
            "a", "Chart", "Q3 ", " ", "\t", "\\", "\\|", "|", "|", "|", "300", "0", "100001", "640x480", "center",
            "LEFT", "Right", "crop=0.1,0.2,0.5,0.5", "crop=0.5,0.5,0.6,0.6", "crop=0,0,1,1", "crop=.25,0,.5,1",
            "foo", "é", "😀", "[", "]", "x", "12",
        ]
        var generator = SplitMix64(seed: 0x1D0C26)
        for _ in 0..<2_000 {
            let count = Int(generator.next() % 9)
            let alt = (0..<count).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            let parsed = ImageAltTokens.parse(alt)
            #expect(alt.hasPrefix(parsed.description), "the description is the source's own prefix: \(alt)")
            let once = ImageAltTokens.format(parsed)
            #expect(once.hasPrefix(parsed.description), "an unedited description is written byte for byte: \(alt)")
            let reread = ImageAltTokens.parse(once)
            #expect(reread.width == parsed.width && reread.alignment == parsed.alignment && reread.crop == parsed.crop,
                    "the write reads back as the same values: \(alt)")
            #expect(ImageAltTokens.format(reread) == once, "stable after the first write: \(alt)")
        }
    }

    // MARK: `![[…]]` embeds

    @Test("an embed's tokens follow its name and optional id")
    func embedTokens() throws {
        let id = "8F2C1A52-7E1B-4C0D-9A3E-5B6F7A8B9C0D"
        let embed = try #require(ImageEmbedReference(content: "shot.png|\(id)|center|crop=0,0,0.5,0.5|300"))
        #expect(embed.name == "shot.png")
        #expect(embed.nodeID?.uuidString == id)
        #expect(embed.requestedWidth == 300)
        #expect(embed.alignment == .center)
        #expect(embed.crop == CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(embed.markdown == "![[shot.png|\(id)|center|crop=0,0,0.5,0.5|300]]")

        let plain = try #require(ImageEmbedReference(content: " shot.png |420"))
        #expect(plain.name == "shot.png" && plain.requestedWidth == 420 && plain.alignment == .left)
        #expect(ImageEmbedReference(content: "|300") == nil, "no name, no embed")
    }
}

/// A small deterministic generator, so a failing fuzz case reproduces.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
