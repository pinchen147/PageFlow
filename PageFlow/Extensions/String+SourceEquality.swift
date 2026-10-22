//
//  String+SourceEquality.swift
//  PageFlow
//

import Foundation

extension String {
    /// Byte-for-byte equality of the UTF-8 encodings. Markdown is source text:
    /// canonically equivalent Unicode (which `==` treats as equal) still
    /// changes the bytes a save writes. A size check and `memcmp` over
    /// contiguous storage keep the hot callers (dirty state per tab per
    /// render) cheap on long notes.
    nonisolated func hasSameSource(as other: String) -> Bool {
        guard utf8.count == other.utf8.count else { return false }
        let fast = utf8.withContiguousStorageIfAvailable { lhs in
            other.utf8.withContiguousStorageIfAvailable { rhs in
                lhs.isEmpty || memcmp(lhs.baseAddress!, rhs.baseAddress!, lhs.count) == 0
            }
        }
        return (fast ?? nil) ?? utf8.elementsEqual(other.utf8)
    }
}
