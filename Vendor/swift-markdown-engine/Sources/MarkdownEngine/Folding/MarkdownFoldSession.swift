import Foundation

/// One document session's choices. Source changes require exact edit evidence to retain anchors.
final class MarkdownFoldSession {
    private(set) var index = MarkdownFoldIndex(source: "", blocks: [])
    private(set) var collapsedHeadings: Set<Int> = []
    private(set) var hiddenRanges: [NSRange] = []
    private var sourceUnits: [UInt16] = []

    func update(source: NSString, blocks: [Block], edit: (range: NSRange, replacementLength: Int)? = nil) {
        var units = [UInt16](repeating: 0, count: source.length)
        source.getCharacters(&units, range: NSRange(location: 0, length: source.length))
        guard units != sourceUnits else { return }
        var mapped: Set<Int> = []
        if let edit, validates(edit, newUnits: units) {
            let end = NSMaxRange(edit.range)
            let delta = edit.replacementLength - edit.range.length
            for anchor in collapsedHeadings {
                if anchor < edit.range.location {
                    mapped.insert(anchor)
                } else if anchor >= end {
                    mapped.insert(anchor + delta)
                }
                // An edit covering the opener cannot prove which heading survived.
            }
        }
        index = MarkdownFoldIndex(source: source, blocks: blocks)
        let validAnchors = Set(index.regions.map { $0.heading.location })
        collapsedHeadings = mapped.intersection(validAnchors)
        sourceUnits = units
        refreshHiddenRanges()
    }

    /// Publish safe provisional intervals immediately after an authoritative native edit.
    /// The caller must match its pre-edit source generation; length alone is not identity.
    /// Counts and rank remain provisional until a matching canonical reindex arrives.
    @discardableResult
    func applyMappedEdit(range: NSRange, replacement: String, resultingLength: Int) -> Bool {
        guard range.location >= 0, range.length >= 0,
              range.location <= sourceUnits.count,
              range.length <= sourceUnits.count - range.location else { return false }
        let inserted = Array(replacement.utf16)
        guard resultingLength == sourceUnits.count - range.length + inserted.count else { return false }
        if range.length == 0 && inserted.isEmpty { return true }
        let oldLength = sourceUnits.count
        let oldEnd = NSMaxRange(range)
        let replacementEnd = range.location + inserted.count
        let delta = inserted.count - range.length
        func moved(_ span: NSRange) -> NSRange {
            let start: Int
            if span.location < range.location { start = span.location }
            else if span.location >= oldEnd { start = span.location + delta }
            else if span.location == range.location { start = range.location }
            else { start = replacementEnd }
            let end = NSMaxRange(span)
            let mappedEnd: Int
            if end == oldLength && range.location == oldLength { mappedEnd = resultingLength }
            else if end <= range.location { mappedEnd = end }
            else if end >= oldEnd { mappedEnd = end + delta }
            else { mappedEnd = replacementEnd }
            return NSRange(location: start, length: max(0, mappedEnd - start))
        }
        let oldCollapsed = collapsedHeadings
        var mappedCollapsed: Set<Int> = []
        // Complete inserted lines shift the original opener intact. A prefix on
        // the same line can change its grammar, so that case still drops identity.
        let insertsCompleteLines = range.length == 0 && (inserted.last == 0x0A || inserted.last == 0x0D)
        let regions = index.regions.compactMap { region -> MarkdownFoldRegion? in
            let anchor = region.heading.location
            let touchedOpener = range.length == 0
                ? anchor == range.location && !insertsCompleteLines
                : anchor >= range.location && anchor < oldEnd
            guard !touchedOpener else { return nil }
            let heading = moved(region.heading)
            if oldCollapsed.contains(anchor) { mappedCollapsed.insert(heading.location) }
            let bodyEnd = NSMaxRange(moved(region.body))
            let body = NSRange(location: NSMaxRange(heading), length: max(0, bodyEnd - NSMaxRange(heading)))
            return MarkdownFoldRegion(heading: heading, body: body,
                                      level: region.level, hiddenBlockCount: region.hiddenBlockCount)
        }
        index = MarkdownFoldIndex(regions: regions)
        collapsedHeadings = mappedCollapsed
        // Keep the retained receipt in place. Array.replaceSubrange shifts the
        // tail unit by unit in unoptimized builds, making long-note typing slow.
        if delta > 0 { sourceUnits.append(contentsOf: repeatElement(0, count: delta)) }
        sourceUnits.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            if delta != 0, oldEnd < oldLength {
                memmove(base + replacementEnd, base + oldEnd, (oldLength - oldEnd) * MemoryLayout<UInt16>.stride)
            }
            if !inserted.isEmpty {
                inserted.withUnsafeBufferPointer {
                    _ = memcpy(base + range.location, $0.baseAddress!, inserted.count * MemoryLayout<UInt16>.stride)
                }
            }
        }
        if delta < 0 { sourceUnits.removeLast(-delta) }
        refreshHiddenRanges()
        return true
    }

    /// A background canonical result may replace provisional counts only for the exact source.
    @discardableResult
    func reindex(source: NSString, blocks: [Block]) -> Bool {
        guard utf16(sourceUnits, equals: source) else { return false }
        index = MarkdownFoldIndex(source: source, blocks: blocks)
        collapsedHeadings.formIntersection(index.regions.map { $0.heading.location })
        refreshHiddenRanges()
        return true
    }

    func collapsedSection(at heading: Int, in source: NSString) -> NSRange? {
        guard collapsedHeadings.contains(heading), let region = index.region(startingAt: heading) else { return nil }
        var end = NSMaxRange(region.body)
        while end > heading, [0x0A, 0x0D].contains(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: heading, length: end - heading)
    }

    func transfer(in range: NSRange) -> MarkdownFoldTransfer {
        let regions = index.regions.filter { NSLocationInRange($0.heading.location, range) }.map { region in
            MarkdownFoldRegion(heading: region.heading,
                body: NSRange(location: region.body.location,
                              length: max(0, min(NSMaxRange(region.body), NSMaxRange(range)) - region.body.location)),
                level: region.level, hiddenBlockCount: region.hiddenBlockCount)
        }
        return MarkdownFoldTransfer(regions: regions,
            collapsed: collapsedHeadings.filter { NSLocationInRange($0, range) }).shifted(by: -range.location)
    }

    func restore(_ transfer: MarkdownFoldTransfer, at offset: Int) {
        let incoming = transfer.shifted(by: offset)
        let anchors = Set(incoming.regions.map { $0.heading.location })
        index = MarkdownFoldIndex(regions: (index.regions.filter { !anchors.contains($0.heading.location) }
            + incoming.regions).sorted { $0.heading.location < $1.heading.location })
        collapsedHeadings.formUnion(incoming.collapsed)
        refreshHiddenRanges()
    }

    func toggle(at heading: Int) {
        guard index.regions.contains(where: { $0.heading.location == heading }) else { return }
        if !collapsedHeadings.insert(heading).inserted { collapsedHeadings.remove(heading) }
        refreshHiddenRanges()
    }

    func collapseAll() {
        collapsedHeadings = Set(index.regions.map { $0.heading.location })
        refreshHiddenRanges()
    }

    func expandAll() {
        collapsedHeadings.removeAll()
        hiddenRanges.removeAll()
    }

    /// Reveal every closed ancestor intersecting a source selection or containing its caret.
    @discardableResult
    func reveal(_ range: NSRange) -> Bool {
        var changed = false
        for region in index.regions where collapsedHeadings.contains(region.heading.location) {
            let intersects = range.length == 0
                ? range.location >= region.body.location
                    && (range.location < NSMaxRange(region.body)
                        || (range.location == sourceUnits.count && NSMaxRange(region.body) == sourceUnits.count))
                : NSIntersectionRange(region.body, range).length > 0
            if intersects {
                collapsedHeadings.remove(region.heading.location)
                changed = true
            }
        }
        if changed { refreshHiddenRanges() }
        return changed
    }

    func reset() { expandAll() }

    private func validates(_ edit: (range: NSRange, replacementLength: Int), newUnits: [UInt16]) -> Bool {
        let range = edit.range
        guard range.location >= 0, range.length >= 0, edit.replacementLength >= 0,
              range.location <= sourceUnits.count,
              range.length <= sourceUnits.count - range.location,
              newUnits.count == sourceUnits.count - range.length + edit.replacementLength else { return false }
        let oldEnd = NSMaxRange(range)
        let newEnd = range.location + edit.replacementLength
        return sourceUnits[..<range.location].elementsEqual(newUnits[..<range.location])
            && sourceUnits[oldEnd...].elementsEqual(newUnits[newEnd...])
    }

    private func refreshHiddenRanges() {
        var result: [NSRange] = []
        for region in index.regions where collapsedHeadings.contains(region.heading.location) {
            if let previous = result.last, NSMaxRange(previous) >= NSMaxRange(region.body) { continue }
            result.append(region.body)
        }
        hiddenRanges = result
    }
}
