import Foundation

/// Original byte pieces for edits addressed in the file's normalized UTF-16 source.
/// New fragments use the original encoding and dominant EOL; untouched bytes never re-encode.
nonisolated struct TextFileOrigin: Sendable {
    struct Edit: Sendable {
        let range: NSRange
        let replacement: String
    }

    enum Failure: Error {
        case unsupportedSource
        case invalidRange
        case overlappingEdits
        case nonNormalizedReplacement
        case unrepresentableEncoding
    }

    let data: Data
    let text: String
    private let fidelity: TextFileFidelity
    private let raw: String
    private let anchors: [Anchor]

    private struct Anchor: Sendable {
        let offset: Int
        let byteOffset: Int
        let index: String.Index
    }

    init(data: Data) throws {
        let decoded = TextFileCodec.decode(data)
        guard !TextFileCodec.looksBinary(data), !decoded.fidelity.replacedInvalidUTF8 else {
            throw Failure.unsupportedSource
        }
        let bom = Self.bomLength(in: data)
        let body = Data(data.dropFirst(bom))
        guard let raw = String(data: body, encoding: decoded.fidelity.encoding),
              let encoded = raw.data(using: decoded.fidelity.encoding, allowLossyConversion: false),
              encoded == body else { throw Failure.unsupportedSource }
        self.data = data
        self.text = decoded.text
        self.fidelity = decoded.fidelity
        self.raw = raw

        var anchors = [Anchor(offset: 0, byteOffset: bom, index: raw.startIndex)]
        var index = raw.startIndex
        var offset = 0
        var byteOffset = bom
        while index < raw.endIndex {
            let step = Self.advance(in: raw, from: index, encoding: decoded.fidelity.encoding)
            index = step.index
            offset += step.units
            byteOffset += step.bytes
            if offset - anchors[anchors.count - 1].offset >= 256 || step.isLineBreak {
                anchors.append(Anchor(offset: offset, byteOffset: byteOffset, index: index))
            }
        }
        guard offset == decoded.text.utf16.count, byteOffset == data.count else {
            throw Failure.unsupportedSource
        }
        if anchors[anchors.count - 1].offset != offset {
            anchors.append(Anchor(offset: offset, byteOffset: byteOffset, index: index))
        }
        self.anchors = anchors
    }

    /// All patches refer to this immutable origin; an invalid batch produces no output.
    func applying(_ edits: [Edit]) throws -> Data {
        guard !edits.isEmpty else { return data }
        let sorted = edits.sorted {
            $0.range.location == $1.range.location
                ? $0.range.length < $1.range.length : $0.range.location < $1.range.location
        }
        let length = text.utf16.count
        var previousEnd = 0
        var previousStart: Int?
        var pieces: [(start: Int, end: Int, replacement: Data)] = []
        for edit in sorted {
            let range = edit.range
            guard range.location >= 0, range.length >= 0,
                  range.location <= length, range.length <= length - range.location else {
                throw Failure.invalidRange
            }
            guard range.location >= previousEnd, previousStart != range.location else {
                throw Failure.overlappingEdits
            }
            let start = try byteOffset(at: range.location)
            let end = try byteOffset(at: range.location + range.length)
            previousStart = range.location
            previousEnd = range.location + range.length
            let existing = (text as NSString).substring(with: range)
            if existing.utf16.elementsEqual(edit.replacement.utf16) { continue }
            guard !edit.replacement.unicodeScalars.contains(where: { $0.value == 13 }) else {
                throw Failure.nonNormalizedReplacement
            }
            let fragment = fidelity.lineEnding == .lf ? edit.replacement
                : edit.replacement.replacingOccurrences(of: "\n", with: fidelity.lineEnding.rawValue, options: .literal)
            guard let bytes = fragment.data(using: fidelity.encoding, allowLossyConversion: false) else {
                throw Failure.unrepresentableEncoding
            }
            pieces.append((start, end, bytes))
        }
        guard !pieces.isEmpty else { return data }
        var result = Data()
        result.reserveCapacity(data.count)
        var cursor = 0
        for piece in pieces {
            result.append(data.dropFirst(cursor).prefix(piece.start - cursor))
            result.append(piece.replacement)
            cursor = piece.end
        }
        result.append(data.dropFirst(cursor))
        return result
    }

    enum Piece: Sendable {
        case original(NSRange)
        case generated(String)
    }

    /// Compose reordered immutable source regions without re-encoding their bytes.
    /// The original BOM belongs to the file, never to an individual source region.
    func composing(_ pieces: [Piece]) throws -> Data {
        var result = Data(data.prefix(Self.bomLength(in: data)))
        for piece in pieces {
            switch piece {
            case .original(let range):
                guard range.location >= 0, range.length >= 0,
                      range.location <= text.utf16.count,
                      range.length <= text.utf16.count - range.location else {
                    throw Failure.invalidRange
                }
                let start = try byteOffset(at: range.location)
                let end = try byteOffset(at: range.location + range.length)
                result.append(data.subdata(in: start..<end))
            case .generated(let source):
                guard !source.unicodeScalars.contains(where: { $0.value == 13 }) else {
                    throw Failure.nonNormalizedReplacement
                }
                let fragment = fidelity.lineEnding == .lf ? source
                    : source.replacingOccurrences(of: "\n", with: fidelity.lineEnding.rawValue, options: .literal)
                guard let bytes = fragment.data(using: fidelity.encoding, allowLossyConversion: false) else {
                    throw Failure.unrepresentableEncoding
                }
                result.append(bytes)
            }
        }
        return result
    }

    private func byteOffset(at offset: Int) throws -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].offset <= offset { low = mid + 1 } else { high = mid }
        }
        let anchor = anchors[max(0, low - 1)]
        var cursor = anchor.index
        var current = anchor.offset
        var bytes = anchor.byteOffset
        while current < offset, cursor < raw.endIndex {
            let step = Self.advance(in: raw, from: cursor, encoding: fidelity.encoding)
            cursor = step.index
            current += step.units
            bytes += step.bytes
        }
        guard current == offset else { throw Failure.invalidRange }
        return bytes
    }

    private static func advance(in raw: String, from index: String.Index,
                                encoding: String.Encoding) -> (index: String.Index, units: Int, bytes: Int, isLineBreak: Bool) {
        let scalars = raw.unicodeScalars
        let scalar = scalars[index]
        var end = scalars.index(after: index)
        var bytes = byteCount(scalar, encoding: encoding)
        if scalar.value == 13 {
            if end < scalars.endIndex, scalars[end].value == 10 {
                bytes += byteCount(scalars[end], encoding: encoding)
                end = scalars.index(after: end)
            }
            return (end, 1, bytes, true)
        }
        return (end, scalar.utf16.count, bytes, scalar.value == 10)
    }

    private static func byteCount(_ scalar: Unicode.Scalar, encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf8: return scalar.utf8.count
        case .utf16LittleEndian, .utf16BigEndian: return scalar.utf16.count * 2
        case .utf32LittleEndian, .utf32BigEndian: return 4
        default: return 1
        }
    }

    private static func bomLength(in data: Data) -> Int {
        for bytes: [UInt8] in [[0, 0, 0xFE, 0xFF], [0xFF, 0xFE, 0, 0],
                              [0xEF, 0xBB, 0xBF], [0xFE, 0xFF], [0xFF, 0xFE]] {
            if data.starts(with: bytes) { return bytes.count }
        }
        return 0
    }
}
