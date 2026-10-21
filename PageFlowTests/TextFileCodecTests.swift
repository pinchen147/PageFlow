//
//  TextFileCodecTests.swift
//  PageFlowTests
//
//  The ADR-0008 locked test matrix: byte-faithful encoding + line-ending
//  round-trip for the Markdown editor. Covers BOM variants, mixed/orphan EOL,
//  no-trailing-newline, the 8-bit byte-faithful set, and the UTF-16/32
//  read→UTF-8-with-note path.
//

import Foundation
import Testing
@testable import PageFlow

struct TextFileCodecTests {

    /// Decode then re-encode must reproduce the original bytes exactly.
    private func expectByteFaithfulRoundTrip(_ data: Data, _ comment: Comment) {
        let decoded = TextFileCodec.decode(data)
        let encoded = TextFileCodec.encode(decoded.text, fidelity: decoded.fidelity)
        #expect(encoded.data == data, comment)
        #expect(!encoded.downgradedToUTF8, comment)
    }

    // MARK: - UTF-8

    @Test
    func utf8_LF_roundTripsAndNormalizes() {
        let data = Data("# Title\nhello world\n".utf8)
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == "# Title\nhello world\n")
        #expect(decoded.fidelity.encoding == .utf8)
        #expect(decoded.fidelity.lineEnding == .lf)
        #expect(!decoded.fidelity.hadUTF8BOM)
        expectByteFaithfulRoundTrip(data, "utf8/LF")
    }

    @Test
    func utf8_CRLF_normalizesToLFButSavesCRLF() {
        let data = Data("a\r\nb\r\nc\r\n".utf8)
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == "a\nb\nc\n")   // homogeneous in memory
        #expect(decoded.fidelity.lineEnding == .crlf)
        expectByteFaithfulRoundTrip(data, "utf8/CRLF")
    }

    @Test
    func utf8_BOM_isStrippedInMemoryAndReEmittedOnSave() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("x\ny\n".utf8)
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == "x\ny\n")        // BOM not in the buffer
        #expect(decoded.fidelity.hadUTF8BOM)
        #expect(decoded.fidelity.encoding == .utf8)
        expectByteFaithfulRoundTrip(data, "utf8/BOM")
    }

    @Test
    func bareCR_oldMacEndings_roundTrip() {
        let data = Data("a\rb\rc".utf8)
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == "a\nb\nc")
        #expect(decoded.fidelity.lineEnding == .cr)
        expectByteFaithfulRoundTrip(data, "bare CR")
    }

    @Test
    func noTrailingNewline_isNotGivenOne() {
        let data = Data("no trailing newline".utf8)
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == "no trailing newline")
        #expect(decoded.fidelity.lineEnding == .lf)   // default when none present
        expectByteFaithfulRoundTrip(data, "no trailing newline")
    }

    @Test
    func emptyFile_roundTrips() {
        expectByteFaithfulRoundTrip(Data(), "empty")
        let decoded = TextFileCodec.decode(Data())
        #expect(decoded.text.isEmpty)
    }

    @Test
    func newlineNormalizationPreservesUnicodeAndMixedEndingTieRules() {
        let cases: [(String, String, LineEnding)] = [
            ("e\u{301}\r\n二\u{2028}😀\rZ\n", "e\u{301}\n二\u{2028}😀\nZ\n", .crlf),
            ("a\r\r\nb\n\n", "a\n\nb\n\n", .lf),
            ("\u{2028}\u{2029}\u{0085}é", "\u{2028}\u{2029}\u{0085}é", .lf),
            ("😀\ré\r", "😀\né\n", .cr)
        ]
        for (input, expected, ending) in cases {
            let decoded = TextFileCodec.decode(Data(input.utf8))
            #expect(Array(decoded.text.utf8) == Array(expected.utf8))
            #expect(decoded.fidelity.lineEnding == ending)
        }
    }

    // MARK: - Damaged UTF-8

    @Test
    func damagedUTF8StaysUTF8AndSurvivesAnEmojiEdit() {
        var data = Data("café — naïve\n".utf8)
        data.append(0xFF)
        data.append(contentsOf: Data(" end\n".utf8))
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.fidelity.encoding == .utf8)
        #expect(decoded.fidelity.replacedInvalidUTF8)
        #expect(decoded.text == "café — naïve\n\u{FFFD} end\n")

        let saved = TextFileCodec.encode(decoded.text + "😀", fidelity: decoded.fidelity)
        #expect(!saved.downgradedToUTF8)
        #expect(String(data: saved.data, encoding: .utf8) == "café — naïve\n\u{FFFD} end\n😀")
    }

    @Test
    func damagedBodyAfterAUTF8BOMIsFlagged() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Data("é".utf8))
        data.append(0xC3)   // truncated two-byte sequence
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.fidelity.hadUTF8BOM)
        #expect(decoded.fidelity.replacedInvalidUTF8)
        #expect(decoded.text == "é\u{FFFD}")
    }

    @Test
    func cleanFilesAreNeverFlaggedAsDamaged() {
        #expect(!TextFileCodec.decode(Data("plain é\n".utf8)).fidelity.replacedInvalidUTF8)
        #expect(!TextFileCodec.decode(Data([0x68, 0x92, 0xE9, 0x0A])).fidelity.replacedInvalidUTF8)
    }

    @Test
    func binaryDetectionFollowsGitsZeroByteRule() {
        #expect(TextFileCodec.looksBinary(Data([0x41, 0x00, 0x42])))
        #expect(!TextFileCodec.looksBinary(Data("text only\n".utf8)))
        #expect(!TextFileCodec.looksBinary(Data([0xFF, 0xFE, 0x41, 0x00])), "UTF-16 is text")
        var late = Data(repeating: 0x41, count: 8000)
        late.append(0x00)
        #expect(!TextFileCodec.looksBinary(late), "only the first 8000 bytes count")
    }

    // MARK: - 8-bit encodings (byte-faithful)

    @Test
    func cp1252_roundTripsByteFaithfully() {
        // 'h', RIGHT SINGLE QUOTE (0x92), 'é' (0xE9), LF — invalid UTF-8, valid CP1252.
        let data = Data([0x68, 0x92, 0xE9, 0x0A])
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.fidelity.encoding == .windowsCP1252)
        expectByteFaithfulRoundTrip(data, "CP1252")
    }

    @Test
    func macRomanOrCP1252_eightBit_roundTripsByteFaithfully() {
        // 0x81 is undefined in CP1252; the ladder falls through to MacRoman (which
        // maps all 256). Either way the bytes must round-trip exactly — that is the
        // contract; the exact encoding chosen is an implementation detail.
        let data = Data([0x41, 0x81, 0x0A])
        let decoded = TextFileCodec.decode(data)
        #expect(String(data: data, encoding: .utf8) == nil)  // confirm it is non-UTF-8
        expectByteFaithfulRoundTrip(data, "8-bit fallthrough")
    }

    @Test
    func eightBitSave_downgradesToUTF8_whenTextOutgrowsTheEncoding() {
        // A CP1252 file edited to contain an emoji (not representable in CP1252)
        // must downgrade to UTF-8 rather than corrupt the character.
        let data = Data([0x68, 0xE9, 0x0A])   // 'h', 'é', LF
        let decoded = TextFileCodec.decode(data)
        let grown = decoded.text + "😀\n"
        let encoded = TextFileCodec.encode(grown, fidelity: decoded.fidelity)
        #expect(encoded.downgradedToUTF8)
        #expect(encoded.data == Data(grown.replacingOccurrences(of: "\n", with: decoded.fidelity.lineEnding.rawValue).utf8))
    }

    // MARK: - UTF-16 / UTF-32 (read, saved as UTF-8 with note)

    private func expectReadAsTextSavedAsUTF8(
        bom: [UInt8], bodyEncoding: String.Encoding, _ comment: Comment
    ) {
        let text = "hi α\nthere\n"
        let body = text.data(using: bodyEncoding)!
        let data = Data(bom) + body

        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == text, comment)
        #expect(decoded.fidelity.savedAsDowngradedUTF8, comment)

        let encoded = TextFileCodec.encode(decoded.text, fidelity: decoded.fidelity)
        #expect(encoded.data == Data(text.utf8), comment)  // plain UTF-8, no BOM
        #expect(!encoded.downgradedToUTF8, comment)         // the note is from load, not a re-downgrade
    }

    @Test func utf16LE_readSavedAsUTF8() {
        expectReadAsTextSavedAsUTF8(bom: [0xFF, 0xFE], bodyEncoding: .utf16LittleEndian, "UTF-16 LE")
    }

    @Test func utf16BE_readSavedAsUTF8() {
        expectReadAsTextSavedAsUTF8(bom: [0xFE, 0xFF], bodyEncoding: .utf16BigEndian, "UTF-16 BE")
    }

    @Test func utf32LE_readSavedAsUTF8() {
        expectReadAsTextSavedAsUTF8(bom: [0xFF, 0xFE, 0x00, 0x00], bodyEncoding: .utf32LittleEndian, "UTF-32 LE")
    }

    @Test func utf32BE_readSavedAsUTF8() {
        expectReadAsTextSavedAsUTF8(bom: [0x00, 0x00, 0xFE, 0xFF], bodyEncoding: .utf32BigEndian, "UTF-32 BE")
    }

    /// The ordering hazard the ADR calls out: the UTF-32 LE BOM (`FF FE 00 00`)
    /// begins with the UTF-16 LE BOM (`FF FE`), so it must be tested first.
    @Test
    func utf32LE_isNotMisdetectedAsUTF16LE() {
        let text = "z\n"
        let data = Data([0xFF, 0xFE, 0x00, 0x00]) + text.data(using: .utf32LittleEndian)!
        let decoded = TextFileCodec.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.fidelity.encoding == .utf32LittleEndian)
    }

    // MARK: - Dominant line ending

    @Test
    func dominantLineEnding_picksTheMajorityInAMixedFile() {
        #expect(TextFileCodec.dominantLineEnding("a\r\nb\r\nc\nd\r\n") == .crlf)  // 3 CRLF vs 1 LF
        #expect(TextFileCodec.dominantLineEnding("a\nb\nc\r\n") == .lf)           // 2 LF vs 1 CRLF
        #expect(TextFileCodec.dominantLineEnding("a\rb\rc") == .cr)
        #expect(TextFileCodec.dominantLineEnding("no endings") == .lf)
    }
}
