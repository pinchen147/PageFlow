import AppKit

extension SemanticEditorHostSession {
    struct HeadingRegion {
        let id: UUID
        let heading: NSRange
        let body: NSRange
    }

    func headingRegions() -> [HeadingRegion] {
        guard let storage = owner.textView.textStorage else { return [] }
        var headings: [(UUID, NSRange, Int)] = []
        storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: NSRange(location: 0, length: storage.length)) { id, range, _ in
            guard let id = id as? UUID,
                  let role = storage.attribute(NativeSemanticAttributes.paragraphRole, at: range.location, effectiveRange: nil) as? NativeSemanticParagraphRole,
                  case .heading(let level) = role else { return }
            headings.append((id, range, level))
        }
        return headings.enumerated().map { index, entry in
            let end = headings.dropFirst(index + 1).first { $0.2 <= entry.2 }?.1.location ?? storage.length
            return HeadingRegion(id: entry.0, heading: entry.1,
                body: NSRange(location: NSMaxRange(entry.1), length: max(0, end - NSMaxRange(entry.1))))
        }
    }

    var currentRegion: HeadingRegion? {
        let caret = owner.textView.selectedRange().location
        return headingRegions().last { $0.heading.location <= caret && caret <= NSMaxRange($0.body) }
    }

    func canFold(_ command: MarkdownEditorKeyCommand) -> Bool {
        guard !owner.textView.hasMarkedText(), !owner.isWritingToolsActive else { return false }
        switch command {
        case .toggleFold: return currentRegion?.body.length ?? 0 > 0
        case .collapseAll: return headingRegions().contains { $0.body.length > 0 && !collapsedBlocks.contains($0.id) }
        case .expandAll: return !collapsedBlocks.isEmpty
        default: return false
        }
    }

    func fold(_ command: MarkdownEditorKeyCommand) -> Bool {
        guard canFold(command) else { return false }
        switch command {
        case .toggleFold:
            guard let current = currentRegion else { return false }
            if !collapsedBlocks.insert(current.id).inserted { collapsedBlocks.remove(current.id) }
            owner.textView.setSelectedRange(NSRange(location: current.heading.location, length: 0))
        case .collapseAll: collapsedBlocks = Set(headingRegions().filter { $0.body.length > 0 }.map(\.id))
        case .expandAll: collapsedBlocks.removeAll()
        default: return false
        }
        refreshFolds()
        return true
    }

    func refreshFolds() {
        let regions = headingRegions()
        collapsedBlocks.formIntersection(Set(regions.map(\.id)))
        var hidden: [NSRange] = []
        for region in regions where collapsedBlocks.contains(region.id) && region.body.length > 0 {
            if let last = hidden.last, region.body.location <= NSMaxRange(last) {
                hidden[hidden.count - 1] = NSUnionRange(last, region.body)
            } else { hidden.append(region.body) }
        }
        let summaries = owner.configuration.showsHiddenContentRow
            ? Set(regions.filter { collapsedBlocks.contains($0.id) }.map { $0.heading.location }) : []
        guard hidden != foldLayout.hiddenRanges || summaries != foldLayout.summaryHeadings else {
            foldControls.refresh()
            return
        }
        foldLayout.summaryHeadings = summaries
        foldLayout.hiddenRanges = hidden
        if let layout = owner.textView.textLayoutManager {
            layout.invalidateLayout(for: layout.documentRange)
            owner.textView.needsLayout = true
        }
        foldControls.refresh()
        controller?.onFoldingStateChange?()
        controller?.onSectionNavigationChange?(navigationSnapshot())
    }
}
