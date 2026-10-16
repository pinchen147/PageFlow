//
//  WikiLinkService.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Generic wiki-link transformer used by the editor engine.
//
//  Wiki-links live in two forms:
//    Storage form    [[Name|<opaque-id>]]
//    Display form    [[Name]]
//
//  This service converts between the two and maintains a metadata map
//  that lets callers look up the storage range and identifier for any
//  display occurrence. The identifier is opaque to the engine — it can
//  be a UUID, a slug, a database key, anything an embedder hands out
//  via the ``WikiLinkResolver`` protocol.
//

import AppKit
import Foundation
import os

/// Bidirectional transform between the storage and display forms of wiki-links.
public enum WikiLinkService {

    /// Hashable wrapper around `NSRange` so we can use it as a dictionary key.
    public struct RangeKey: Hashable, Sendable {
        public let location: Int
        public let length: Int

        public init(_ range: NSRange) {
            self.location = range.location
            self.length = range.length
        }
    }

    /// Identifier and storage-side range associated with a display occurrence.
    public struct LinkMetadata: Sendable {
        public let id: String?
        public let storageRange: NSRange

        public init(id: String?, storageRange: NSRange) {
            self.id = id
            self.storageRange = storageRange
        }
    }

    /// Regex pattern matching the storage form `[[Name|optional-id]]`.
    public static let storagePattern = #"(?<!!)\[\[([^\|\]\r\n]*)(?:\|([^\]\r\n]+))?\]\]"#
    /// Regex pattern matching the display form `[[Name]]` (no `|`).
    public static let displayPattern = #"(?<!!)\[\[([^\]\r\n]*)\]\]"#

    private static let storageLinkRegex = try! NSRegularExpression(pattern: storagePattern)
    private static let displayLinkRegex = try! NSRegularExpression(pattern: displayPattern)
    private static let logger = Logger(subsystem: "com.markdownengine.wikilinks", category: "WikiLink")

    /// Convert storage form `[[Name|<id>]]` to display `[[Name]]`, returning a display-range metadata map.
    public static func makeDisplayState(from storageText: String) -> (display: String, metadata: [RangeKey: LinkMetadata]) {
        let nsStorage = storageText as NSString
        let fullRange = NSRange(location: 0, length: nsStorage.length)
        var result = ""
        result.reserveCapacity(storageText.count)
        var metadata: [RangeKey: LinkMetadata] = [:]
        var cursor = 0
        var displayLength = 0

        for match in storageLinkRegex.matches(in: storageText, options: [], range: fullRange) {
            let prefixLength = match.range.location - cursor
            if prefixLength > 0 {
                let prefixRange = NSRange(location: cursor, length: prefixLength)
                let prefix = nsStorage.substring(with: prefixRange)
                result.append(prefix)
                displayLength += prefix.utf16.count
                cursor += prefixLength
            }

            let nameRange = match.range(at: 1)
            let name = nsStorage.substring(with: nameRange)
            let displayFragment = "[[\(name)]]"
            let displayRange = NSRange(location: displayLength, length: displayFragment.utf16.count)
            result.append(displayFragment)
            displayLength += displayFragment.utf16.count

            var linkID: String? = nil
            if match.numberOfRanges > 2 {
                let idRange = match.range(at: 2)
                if idRange.location != NSNotFound && idRange.length > 0 {
                    linkID = nsStorage.substring(with: idRange)
                }
            }
            metadata[RangeKey(displayRange)] = LinkMetadata(id: linkID, storageRange: match.range)
            cursor = match.range.location + match.range.length
        }

        if cursor < nsStorage.length {
            let suffixRange = NSRange(location: cursor, length: nsStorage.length - cursor)
            result.append(nsStorage.substring(with: suffixRange))
        }

        return (result, metadata)
    }

    /// Convert display `[[Name]]` back to storage `[[Name|<id>]]`, preferring the `.wikiLinkID` attribute.
    public static func makeStorageState(
        from displayText: String,
        existingMetadata: [RangeKey: LinkMetadata],
        textStorage: NSTextStorage?
    ) -> (storage: String, metadata: [RangeKey: LinkMetadata]) {
        let nsDisplay = displayText as NSString
        // No `[[` anywhere → storage == display; skip the O(document) rebuild.
        if nsDisplay.range(of: "[[").location == NSNotFound {
            return (displayText, [:])
        }
        var storage = ""
        storage.reserveCapacity(nsDisplay.length)   // was displayText.count (O(doc) grapheme count)
        var metadata: [RangeKey: LinkMetadata] = [:]
        var cursor = 0
        var storageLength = 0

        for matchRange in displayLinkRanges(nsDisplay) {
            let prefixLength = matchRange.location - cursor
            if prefixLength > 0 {
                let prefixRange = NSRange(location: cursor, length: prefixLength)
                let prefix = nsDisplay.substring(with: prefixRange)
                storage.append(prefix)
                storageLength += prefix.utf16.count
                cursor += prefixLength
            }

            let contentLength = max(0, matchRange.length - 4)
            let contentRange = NSRange(location: matchRange.location + 2, length: contentLength)
            let name = nsDisplay.substring(with: contentRange)

            var linkID: String? = nil
            if contentRange.length > 0 {
                if let idAttr = textStorage?.attribute(.wikiLinkID, at: contentRange.location, effectiveRange: nil) as? String {
                    linkID = idAttr
                }
            }
            if linkID == nil {
                linkID = existingMetadata[RangeKey(matchRange)]?.id
            }

            let storageFragment: String
            if let linkID, !linkID.isEmpty {
                storageFragment = "[[\(name)|\(linkID)]]"
            } else {
                storageFragment = "[[\(name)]]"
            }
            let fragmentLength = storageFragment.utf16.count
            let storageRange = NSRange(location: storageLength, length: fragmentLength)
            storage.append(storageFragment)
            storageLength += fragmentLength

            metadata[RangeKey(matchRange)] = LinkMetadata(id: linkID, storageRange: storageRange)
            cursor = matchRange.location + matchRange.length
        }

        if cursor < nsDisplay.length {
            let suffixRange = NSRange(location: cursor, length: nsDisplay.length - cursor)
            storage.append(nsDisplay.substring(with: suffixRange))
        }

        return (storage, metadata)
    }

    /// Hand scan for display-form wiki links `(?<!!)\[\[...\]\]`, replacing the slow regex lookbehind.
    static func displayLinkRanges(_ s: NSString) -> [NSRange] {
        let len = s.length
        guard len >= 4 else { return [] }
        var buf = [unichar](repeating: 0, count: len)   // one bulk extract, then array access
        s.getCharacters(&buf, range: NSRange(location: 0, length: len))
        var result: [NSRange] = []
        var i = 0
        while i + 1 < len {
            guard buf[i] == 0x5B, buf[i + 1] == 0x5B else { i += 1; continue }   // [[
            if i > 0, buf[i - 1] == 0x21 { i += 2; continue }                    // preceded by ! → skip
            var j = i + 2
            var matched = false
            while j < len {
                let c = buf[j]
                if c == 0x0A || c == 0x0D { break }                             // newline → no match
                if c == 0x5D {                                                  // ]
                    if j + 1 < len, buf[j + 1] == 0x5D {                        // ]]
                        result.append(NSRange(location: i, length: (j + 2) - i))
                        i = j + 2
                        matched = true
                    }
                    break
                }
                j += 1
            }
            if !matched { i += 1 }
        }
        return result
    }

    /// Resolve a clicked link's id from the caret's `.wikiLinkID` attribute, else its display string.
    public static func resolveIdentifier(link: Any, textView: NSTextView, at charIndex: Int) -> String? {
        if let storage = textView.textStorage, charIndex >= 0, charIndex < storage.length,
           let idAttr = storage.attribute(.wikiLinkID, at: charIndex, effectiveRange: nil) as? String {
            return idAttr
        }
        if let name = link as? String {
            return name
        }
        return nil
    }

    /// Split a storage fragment `[[Name|<id>]]` into its display form and the opaque id.
    public static func displayFragmentAndID(from storageFragment: String) -> (display: String, id: String?) {
        let displayState = makeDisplayState(from: storageFragment)
        return (displayState.display, displayState.metadata.values.first?.id)
    }

    /// Zero-length caret range following replacement of `displayRange` with `storageFragment`.
    public static func caretRangeAfterReplacing(
        displayRange: NSRange,
        with storageFragment: String
    ) -> NSRange {
        let displayFragment = makeDisplayState(from: storageFragment).display as NSString
        return NSRange(location: displayRange.location + displayFragment.length, length: 0)
    }
}

