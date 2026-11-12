import AppKit

/// Uses the same disclosure and summary controls over semantic heading identities.
@MainActor
final class SemanticFoldControls {
    weak var host: SemanticEditorHostSession?
    private var buttons: [UUID: (FoldButton, FoldButton)] = [:]
    private var refreshing = false

    init(host: SemanticEditorHostSession) { self.host = host }

    func uninstall() {
        for (_, pair) in buttons { pair.0.removeFromSuperview(); pair.1.removeFromSuperview() }
        buttons.removeAll()
    }

    func refresh() {
        guard !refreshing, let host, let storage = host.owner.textView.textStorage,
              let layout = host.owner.textView.textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return }
        refreshing = true
        defer { refreshing = false }
        let view = host.owner.textView
        let regions = Dictionary(uniqueKeysWithValues: host.headingRegions().map { ($0.heading.location, $0) })
        var visible: Set<UUID> = []
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            guard let region = regions[offset], region.body.length > 0,
                  host.foldLayout.hiddenRange(containing: offset) == nil else { return true }
            let pair: (FoldButton, FoldButton)
            if let retained = buttons[region.id] { pair = retained }
            else {
                let action = { [weak host] in
                    guard let host, let current = host.headingRegions().first(where: { $0.id == region.id }) else { return }
                    host.owner.textView.setSelectedRange(NSRange(location: current.heading.location, length: 0))
                    _ = host.fold(.toggleFold)
                }
                pair = (FoldButton(summary: false, action: action), FoldButton(summary: true, action: action))
                buttons[region.id] = pair
                view.addSubview(pair.0)
                view.addSubview(pair.1)
            }
            visible.insert(region.id)
            let closed = host.collapsedBlocks.contains(region.id)
            let title = (storage.string as NSString).substring(with: region.heading).trimmingCharacters(in: .whitespacesAndNewlines)
            var count = 0
            storage.enumerateAttribute(NativeSemanticAttributes.blockID, in: region.body) { _, _, _ in count += 1 }
            let enabled = !view.hasMarkedText() && !host.owner.isWritingToolsActive
            pair.0.configure(closed: closed, count: count, title: title, enabled: enabled)
            pair.1.configure(closed: closed, count: count, title: title, enabled: enabled)
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            let line = fragment.textLineFragments.first?.typographicBounds ?? .zero
            pair.0.frame = NSRect(x: max(0, view.textContainerOrigin.x - 30), y: frame.minY + line.midY - 12, width: 24, height: 24)
            pair.1.frame = NSRect(x: view.textContainerOrigin.x, y: frame.maxY - MarkdownFoldLayout.rowHeight,
                width: view.textContainer?.size.width ?? view.bounds.width, height: MarkdownFoldLayout.rowHeight)
            pair.1.isHidden = !closed || !host.owner.configuration.showsHiddenContentRow
            pair.0.trackHeading(in: view, rect: frame.union(pair.0.frame))
            return true
        }
        for id in Array(buttons.keys) where !visible.contains(id) {
            if let pair = buttons.removeValue(forKey: id) { pair.0.removeFromSuperview(); pair.1.removeFromSuperview() }
        }
    }
}
