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
