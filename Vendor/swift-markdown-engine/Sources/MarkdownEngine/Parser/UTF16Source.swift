import Foundation

/// Copies literal source units without Unicode normalization or per-character bridging.
func copiedUTF16(of text: NSString) -> [UInt16] {
    let length = text.length
    var characters = [UInt16](repeating: 0, count: length)
    if length > 0 {
        text.getCharacters(&characters, range: NSRange(location: 0, length: length))
    }
    return characters
}

/// Whether `text` holds exactly `units`, compared in fixed chunks so a cache
/// check never allocates a copy of the document.
func utf16(_ units: [UInt16], equals text: NSString) -> Bool {
    guard units.count == text.length else { return false }
    var chunk = [UInt16](repeating: 0, count: 4_096)
    return units.withUnsafeBufferPointer { stored in
        var offset = 0
        while offset < stored.count {
            let length = min(chunk.count, stored.count - offset)
            text.getCharacters(&chunk, range: NSRange(location: offset, length: length))
            let same = chunk.withUnsafeBufferPointer { memcmp($0.baseAddress!, stored.baseAddress! + offset, length * 2) == 0 }
            guard same else { return false }
            offset += length
        }
        return true
    }
}

/// Replace a known source span with bounded native copies, avoiding per-unit tail shifts.
func replacingUTF16(_ source: [UInt16], range: NSRange, with replacement: [UInt16]) -> [UInt16] {
    let length = source.count - range.length + replacement.count
    return [UInt16](unsafeUninitializedCapacity: length + 4_096) { output, count in
        source.withUnsafeBufferPointer { input in
            if range.location > 0 { memcpy(output.baseAddress!, input.baseAddress!, range.location * 2) }
            let tail = source.count - NSMaxRange(range)
            if tail > 0 {
                memcpy(output.baseAddress! + range.location + replacement.count,
                       input.baseAddress! + NSMaxRange(range), tail * 2)
            }
        }
        replacement.withUnsafeBufferPointer { input in
            if !replacement.isEmpty { memcpy(output.baseAddress! + range.location, input.baseAddress!, replacement.count * 2) }
        }
        count = length
    }
}
