//
//  TextFileCodec.swift
//  PageFlow
//
//  Byte-faithful text load/save fidelity for the Markdown editor (ADR-0008).
//
//  A `.md` file can be UTF-8, CP1252, MacRoman, ISO-8859-1, or BOM-tagged
//  UTF-16/32, with LF / CRLF / CR line endings. Reading such a file and saving
//  it as UTF-8/LF silently rewrites bytes the user never touched — a data-loss
//  class bug. This codec detects the original encoding + dominant line ending on
//  load, normalizes the in-memory buffer to `\n` (so TextKit keeps a homogeneous
//  buffer and line-math/search stay correct), and re-applies both on save so an
//  externally-authored file survives load → edit → save byte-clean.
//
//  Pure value transforms (Data ↔ String) with no file or actor state — the whole
//  fidelity contract is unit-testable here, independent of disk IO.
//

import Foundation

/// The dominant on-disk line ending, captured on load and re-applied on save.
/// CRLF is tested as a pair before bare CR/LF (ADR-0008).
enum LineEnding: String, Equatable, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
}

/// The byte-level fidelity captured when a text file is read, so a save can
/// reproduce the file the user opened rather than silently normalizing it.
struct TextFileFidelity: Equatable, Sendable {
    /// The encoding the bytes were read with (and, for the 8-bit set, written
    /// back with). For UTF-16/32 sources this records the *original* encoding;
    /// the bytes are nonetheless saved as UTF-8 (`savedAsDowngradedUTF8`).
    var encoding: String.Encoding
    /// A UTF-8 file that carried a byte-order mark we must re-emit on save.
    var hadUTF8BOM: Bool
    /// The dominant on-disk line ending, re-applied on save.
    var lineEnding: LineEnding
    /// Set when the source was UTF-16/32: read faithfully, but saved as UTF-8
    /// (ADR-0008 v1 restriction) — surfaced to the user as a one-time note, never
    /// a silent rewrite.
    var savedAsDowngradedUTF8: Bool
    /// A UTF-8 file with damaged bytes, read with each shown as U+FFFD. Saving
    /// writes the replacement character, so the host asks before the first save.
    var replacedInvalidUTF8 = false

    /// The default for a brand-new (untitled) document: UTF-8, LF, no BOM.
    static let utf8LF = TextFileFidelity(
        encoding: .utf8, hadUTF8BOM: false, lineEnding: .lf, savedAsDowngradedUTF8: false)
}

enum TextFileCodec {

    /// The decoded, normalized text plus the fidelity needed to re-save it.
    struct Decoded: Equatable {
        /// Normalized to `\n` — the homogeneous in-memory form.
        var text: String
        var fidelity: TextFileFidelity
    }

    /// The result of encoding for save.
    struct Encoded: Equatable {
        var data: Data
        /// True when the text could not be represented in its original 8-bit
        /// encoding and was saved as UTF-8 instead (e.g. an emoji typed into a
        /// CP1252 file) — surfaced as a one-time note rather than corrupting.
        var downgradedToUTF8: Bool
    }

    // MARK: - Decode (load)

    /// A zero byte early in a file without a UTF-16/32 byte-order mark means it
    /// isn't text (git's rule: the first 8000 bytes). Decoding it anyway would
    /// succeed (ISO-8859-1 maps every byte) and the first save would corrupt it.
    static func looksBinary(_ data: Data) -> Bool {
        guard BOM.detect(in: data) == nil else { return false }
        return data.prefix(8000).contains(0)
    }

    /// Detects encoding (BOM → strict-UTF-8 → damaged UTF-8 → CP1252 → MacRoman →
    /// ISO-8859-1) and the dominant line ending, then normalizes the buffer to `\n`.
    static func decode(_ data: Data) -> Decoded {
        if let bom = BOM.detect(in: data) {
            let body = Data(data.dropFirst(bom.byteCount))
            switch bom {
            case .utf8:
                if let raw = String(data: body, encoding: .utf8) {
                    return finish(raw, encoding: .utf8, hadUTF8BOM: true, downgraded: false)
                }
                return finish(String(decoding: body, as: UTF8.self), encoding: .utf8,
                              hadUTF8BOM: true, downgraded: false, replacedInvalidUTF8: true)
            case .utf16LE, .utf16BE, .utf32LE, .utf32BE:
                // UTF-16/32 are READ (BOM-detected) but SAVED as UTF-8 in v1.
                if let raw = String(data: body, encoding: bom.encoding) {
                    return finish(raw, encoding: bom.encoding, hadUTF8BOM: false, downgraded: true)
                }
                return finish(String(decoding: body, as: UTF8.self), encoding: bom.encoding,
                              hadUTF8BOM: false, downgraded: true, replacedInvalidUTF8: true)
            }
        }

        // No BOM: strict UTF-8 first (any valid UTF-8 wins), then the 8-bit ladder.
        // ISO-8859-1 decodes every byte, so the ladder never falls through.
        if let raw = String(data: data, encoding: .utf8) {
            return finish(raw, encoding: .utf8, hadUTF8BOM: false, downgraded: false)
        }
        // A UTF-8 file with a few damaged bytes (a bad sync, a concatenation)
        // stays UTF-8: read as an 8-bit encoding, every accented character would
        // show garbled and be saved garbled.
        if isMostlyUTF8(data) {
            return finish(String(decoding: data, as: UTF8.self), encoding: .utf8,
                          hadUTF8BOM: false, downgraded: false, replacedInvalidUTF8: true)
        }
        for encoding in [String.Encoding.windowsCP1252, .macOSRoman, .isoLatin1] {
            if let raw = String(data: data, encoding: encoding) {
                return finish(raw, encoding: encoding, hadUTF8BOM: false, downgraded: false)
            }
        }
        // Defensive fallback (unreachable: isoLatin1 maps all 256 bytes).
        return finish(String(decoding: data, as: UTF8.self),
                      encoding: .utf8, hadUTF8BOM: false, downgraded: false)
    }

    /// Invalid UTF-8 with at least as many valid multi-byte sequences as damaged
    /// ones. Real 8-bit text (CP1252, MacRoman) almost never forms valid
    /// multi-byte sequences, so it keeps the 8-bit ladder.
    private static func isMostlyUTF8(_ data: Data) -> Bool {
        var multiByte = 0
        var invalid = 0
        var bytes = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&bytes) {
            case .scalarValue(let scalar): if scalar.value >= 0x80 { multiByte += 1 }
            case .error: invalid += 1
            case .emptyInput: return multiByte > 0 && multiByte >= invalid
            }
        }
    }

    private static func finish(
        _ raw: String, encoding: String.Encoding, hadUTF8BOM: Bool, downgraded: Bool,
        replacedInvalidUTF8: Bool = false
    ) -> Decoded {
        let lineEnding = dominantLineEnding(raw)
        // Substring replacement matches on scalar sequence, so CRLF collapses
        // before bare CR — order matters.
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return Decoded(
            text: normalized,
            fidelity: TextFileFidelity(
                encoding: encoding,
                hadUTF8BOM: hadUTF8BOM,
                lineEnding: lineEnding,
                savedAsDowngradedUTF8: downgraded,
                replacedInvalidUTF8: replacedInvalidUTF8))
    }

    /// The most frequent line ending, counting CRLF as a pair before bare CR/LF.
    /// Scans unicode scalars (not Characters) because Swift fuses `\r\n` into one
    /// Character, which would hide the distinction. Defaults to LF.
    static func dominantLineEnding(_ text: String) -> LineEnding {
        var crlf = 0, cr = 0, lf = 0
        // Stream the scalars with a one-scalar carry so a multi-MB document needs
        // no backing array. A pending `\r` resolves to CRLF if the next scalar is
        // `\n`, else it was a bare CR.
        var sawCR = false
        for scalar in text.unicodeScalars {
            if sawCR {
                sawCR = false
                if scalar == "\n" { crlf += 1; continue }  // \r\n consumed as a pair
                cr += 1                                     // the prior \r was bare
            }
            if scalar == "\r" { sawCR = true } else if scalar == "\n" { lf += 1 }
        }
        if sawCR { cr += 1 }  // trailing bare \r
        if crlf >= lf && crlf >= cr && crlf > 0 { return .crlf }
        if cr > lf && cr > 0 { return .cr }
        return .lf
    }

    // MARK: - Encode (save)

    /// Re-expands `\n` → the stored line ending and encodes to the stored
    /// encoding (never `dataRepresentation()` — that is the PDF byte path).
    /// `nonisolated`: pure Sendable-value work — the save path runs it INSIDE
    /// the detached write task so a large document's encode never occupies
    /// the main actor.
    nonisolated static func encode(_ text: String, fidelity: TextFileFidelity) -> Encoded {
        let expanded = fidelity.lineEnding == .lf
            ? text
            : text.replacingOccurrences(of: "\n", with: fidelity.lineEnding.rawValue)

        // UTF-16/32 sources save as plain UTF-8 (no BOM) in v1.
        if fidelity.savedAsDowngradedUTF8 {
            return Encoded(data: Data(expanded.utf8), downgradedToUTF8: false)
        }

        if fidelity.encoding == .utf8 {
            var data = Data()
            if fidelity.hadUTF8BOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(Data(expanded.utf8))
            return Encoded(data: data, downgradedToUTF8: false)
        }

        // 8-bit set (CP1252 / MacRoman / ISO-8859-1), non-lossy. If the text grew a
        // character the original encoding can't represent, downgrade to UTF-8
        // rather than drop it to '?'.
        if let data = expanded.data(using: fidelity.encoding, allowLossyConversion: false) {
            return Encoded(data: data, downgradedToUTF8: false)
        }
        return Encoded(data: Data(expanded.utf8), downgradedToUTF8: true)
    }

    // MARK: - BOM

    private enum BOM {
        case utf8, utf16LE, utf16BE, utf32LE, utf32BE

        var byteCount: Int {
            switch self {
            case .utf8: return 3
            case .utf16LE, .utf16BE: return 2
            case .utf32LE, .utf32BE: return 4
            }
        }

        var encoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LE: return .utf16LittleEndian
            case .utf16BE: return .utf16BigEndian
            case .utf32LE: return .utf32LittleEndian
            case .utf32BE: return .utf32BigEndian
            }
        }

        /// Tests the 4-byte UTF-32 BOMs before the 2-byte UTF-16 BOMs, since the
        /// UTF-32 LE BOM (`FF FE 00 00`) begins with the UTF-16 LE BOM (`FF FE`).
        static func detect(in data: Data) -> BOM? {
            func has(_ bytes: [UInt8]) -> Bool {
                data.count >= bytes.count && Array(data.prefix(bytes.count)) == bytes
            }
            if has([0x00, 0x00, 0xFE, 0xFF]) { return .utf32BE }
            if has([0xFF, 0xFE, 0x00, 0x00]) { return .utf32LE }
            if has([0xFE, 0xFF]) { return .utf16BE }
            if has([0xFF, 0xFE]) { return .utf16LE }
            if has([0xEF, 0xBB, 0xBF]) { return .utf8 }
            return nil
        }
    }
}
