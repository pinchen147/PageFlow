import AppKit

/// View-only navigation state for one retained semantic document owner.
@MainActor
final class SemanticEditorHostSession {
    let owner: NativeSemanticDocumentCoordinator
    weak var controller: MarkdownEditorController?
    let identity = UUID()
    let foldLayout = MarkdownFoldLayout()
    lazy var foldControls = SemanticFoldControls(host: self)
    var collapsedBlocks: Set<UUID> = []
    private var observers: [NSObjectProtocol] = []
    private var pendingFind: (notification: Notification, revision: UInt64)?
    private var pendingNavigation: (() -> Void)?
    private(set) var isRestoringViewport = false
    private var bodyHighlights: [(NSRange, Bool)] = []
    private let highlightedCells = NSHashTable<NSTextView>.weakObjects()
    private var cachedReceipt: (revision: UInt64, value: SemanticMarkdownExportResult)?

    func sourceReceipt() throws -> SemanticMarkdownExportResult {
        if let cachedReceipt, cachedReceipt.revision == owner.revision { return cachedReceipt.value }
        let value = try owner.exportResult()
        cachedReceipt = (owner.revision, value)
        return value
    }

    init(owner: NativeSemanticDocumentCoordinator) {
        self.owner = owner
        (owner.textView.textLayoutManager?.textContentManager as? NSTextContentStorage)?.delegate = foldLayout
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func configure(bus: MarkdownEditorBus, documentID: String) {
        stop()
        let center = NotificationCenter.default
        owner.textView.textLayoutManager?.renderingAttributesValidator = { [weak self] layout, fragment in
            guard let self, let content = layout.textContentManager else { return }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let end = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.endLocation)
            guard start >= 0, end >= start else { return }
            let span = NSRange(location: start, length: end - start)
            for (range, current) in self.bodyHighlights {
                let overlap = NSIntersectionRange(range, span)
                guard overlap.length > 0,
                      let from = content.location(content.documentRange.location, offsetBy: overlap.location),
                      let to = content.location(from, offsetBy: overlap.length),
                      let target = NSTextRange(location: from, end: to) else { continue }
                let theme = self.owner.configuration.theme
                layout.addRenderingAttribute(.backgroundColor,
                    value: current ? theme.findCurrentMatchHighlight : theme.findMatchHighlight, for: target)
            }
        }
        func observe(_ name: Notification.Name?, action: @escaping (Notification) -> Void) {
            guard let name else { return }
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard !bus.scopeByObject || note.object as? String == documentID else { return }
                    action(note)
                }
            })
        }
        observe(bus.findScrollToRange) { [weak self] note in self?.showFind(note) }
        observe(bus.findClearHighlights) { [weak self] _ in self?.clearFind() }
        observe(bus.applyBoldRequest) { [weak self] _ in _ = self?.owner.applyFormat(.bold) }
        observe(bus.applyItalicRequest) { [weak self] _ in _ = self?.owner.applyFormat(.italic) }
        observe(bus.applyUnderlineRequest) { [weak self] _ in _ = self?.owner.applyFormat(.underline) }
        observe(bus.applyHeadingRequest) { [weak self] note in
            if let level = note.userInfo?["level"] as? Int { _ = self?.owner.applyFormat(.heading(level: level)) }
        }
        if let scroll = owner.textView.enclosingScrollView {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.foldControls.refresh()
                    self.controller?.onSectionNavigationChange?(self.navigationSnapshot())
                }
            })
        }
    }

    private func clearFind() {
        bodyHighlights.removeAll()
        for cell in highlightedCells.allObjects {
            if let layout = cell.textLayoutManager { layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange) }
            else { cell.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: cell.string.utf16.count)) }
        }
        highlightedCells.removeAllObjects()
        guard let layout = owner.textView.textLayoutManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
    }

    func inputSettled() {
        if let pending = pendingFind {
            pendingFind = nil
            if pending.revision == owner.revision { showFind(pending.notification) }
        }
        let navigation = pendingNavigation
        pendingNavigation = nil
        navigation?()
    }

    private func showFind(_ note: Notification) {
        let body = owner.textView
        if owner.hasActiveComposition || owner.isWritingToolsActive {
            pendingFind = (note, owner.revision)
            return
        }
        guard let info = note.userInfo,
              let range = info["range"] as? NSRange, range.location >= 0 else { return }
        let index = NativeSemanticSearchIndex(owner: owner)
        let expected = info["expectedSource"] as? String
        let searchCoordinates = expected?.utf16.elementsEqual(index.text.utf16) == true
        guard expected == nil || searchCoordinates || expected?.utf16.elementsEqual(body.string.utf16) == true else { return }
        if let valid = info["whileValid"] as? () -> Bool, !valid() { return }
        func target(_ range: NSRange) -> (NSTextView, NSRange)? {
            if searchCoordinates {
                guard let (segment, local) = index.target(for: range) else { return nil }
                if let block = segment.sourceBlock { return (block.textView, local) }
                if let table = segment.table, let id = segment.cellID, let cell = table.editor(for: id) { return (cell, local) }
                return (body, local)
            }
            guard NSMaxRange(range) <= body.string.utf16.count else { return nil }
            return (body, range)
        }
        clearFind()
        let ranges = info["allRanges"] as? [NSRange] ?? []
        let current = info["currentIndex"] as? Int ?? 0
        for (rank, match) in ranges.enumerated() {
            guard let (view, local) = target(match) else { continue }
            if view !== body { highlightedCells.add(view) }
            else { bodyHighlights.append((local, rank == current)) }
            let theme = owner.configuration.theme
            let color = rank == current ? theme.findCurrentMatchHighlight : theme.findMatchHighlight
            if let layout = view.textLayoutManager, let content = layout.textContentManager,
               let start = content.location(content.documentRange.location, offsetBy: local.location),
               let end = content.location(start, offsetBy: local.length),
               let span = NSTextRange(location: start, end: end) {
                layout.addRenderingAttribute(.backgroundColor, value: color, for: span)
            } else if view !== body {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: local)
            }
        }
        if info["paintsOnly"] as? Bool != true, let (view, local) = target(range) {
            let previous = readingPosition()
            if view === body {
                for region in headingRegions() where NSIntersectionRange(region.body, local).length > 0
                    || NSLocationInRange(local.location, region.body) { collapsedBlocks.remove(region.id) }
                refreshFolds()
            }
            view.setSelectedRange(local)
            if searchCoordinates, let (segment, _) = index.target(for: range),
               let table = segment.table, let id = segment.cellID {
                table.focus(id)
                table.refreshPresentation()
                if let grid = table.grid { body.scrollToVisible(body.convert(grid.bounds, from: grid)) }
            }
            if view !== body, view.isDescendant(of: body) {
                body.scrollToVisible(body.convert(view.bounds, from: view))
            }
            view.scrollRangeToVisible(local)
            if let previous, readingPosition() != previous,
               let callback = info["didNavigate"] as? (ReadingPosition) -> Void { callback(previous) }
        }
    }

    func lineRect(at offset: Int) -> NSRect? {
        let view = owner.textView
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location),
              let element = fragment.textElement?.elementRange else { return nil }
        let local = content.offset(from: element.location, to: location)
        guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(local, $0.characterRange) })
                ?? fragment.textLineFragments.last else { return nil }
        return line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
            dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
    }

    func readingPosition() -> ReadingPosition? {
        let view = owner.textView
        guard !view.isHiddenOrHasHiddenAncestor, let scroll = view.enclosingScrollView,
              let layout = view.textLayoutManager, let content = layout.textContentManager,
              let receipt = try? sourceReceipt() else { return nil }
        var result: ReadingPosition?
        let top = min(view.visibleRect.minY, view.convert(scroll.contentView.bounds, from: scroll.contentView).minY)
        let probe = view.visibleRect.minY + 8
        let start = layout.textViewportLayoutController.viewportRange?.location ?? layout.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            guard fragment.state == .layoutAvailable else { return true }
            let rect = fragment.layoutFragmentFrame.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            guard rect.maxY > probe else { return true }
            guard rect.minY <= view.visibleRect.maxY else { return false }
            guard let line = fragment.textLineFragment(forVerticalOffset: probe - rect.minY, requiresExactMatch: false),
                  let element = fragment.textElement?.elementRange,
                  let location = content.location(element.location, offsetBy: line.characterRange.location) else { return false }
            let visible = content.offset(from: content.documentRange.location, to: location)
            guard let source = receipt.sourceMap.sourceOffset(for: VisibleUTF16Offset(rawValue: visible), affinity: .leading) else { return false }
            result = ReadingPosition(anchorOffset: source.rawValue,
                offsetInViewport: rect.minY + line.typographicBounds.minY - top, magnification: scroll.magnification)
            return false
        }
        return result
    }

    @discardableResult
    func restore(_ position: ReadingPosition) -> Bool {
        guard !isRestoringViewport, !owner.hasActiveComposition, !owner.isWritingToolsActive,
              owner.textView.window != nil, !owner.textView.isHiddenOrHasHiddenAncestor,
              let receipt = try? sourceReceipt(),
              let visible = receipt.sourceMap.visibleOffset(for: SourceUTF16Offset(rawValue: position.anchorOffset), affinity: .leading),
              let scroll = owner.textView.enclosingScrollView else { return false }
        guard let layout = owner.textView.textLayoutManager,
              lineRect(at: visible.rawValue) != nil else { return false }
        isRestoringViewport = true
        defer { isRestoringViewport = false }
        // A distant paragraph initially has an estimated vertical origin. Land
        // again after TextKit materializes each new viewport, as the native
        // reading-position path does, without laying out the whole document.
        let clip = scroll.contentView
        if let content = layout.textContentManager,
           let location = content.location(content.documentRange.location, offsetBy: visible.rawValue) {
            let proposed = layout.textViewportLayoutController.relocateViewport(to: location)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: proposed + owner.textView.textContainerOrigin.y - position.offsetInViewport))
            layout.textViewportLayoutController.layoutViewport()
        }
        for _ in 0..<6 {
            guard let rect = lineRect(at: visible.rawValue) else { return false }
            let clipTop = owner.textView.convert(clip.bounds, from: clip).minY
            let correction = rect.minY - position.offsetInViewport - clipTop
            let rest = (scroll as? ClampedScrollView)?.restingOriginY ?? -CGFloat.greatestFiniteMagnitude
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(rest, clip.bounds.minY + correction)))
            scroll.reflectScrolledClipView(clip)
            layout.textViewportLayoutController.layoutViewport()
            guard let landed = lineRect(at: visible.rawValue) else { return false }
            let landedTop = owner.textView.convert(clip.bounds, from: clip).minY
            if abs(landed.minY - position.offsetInViewport - landedTop) < 0.5 { return true }
            if clip.bounds.minY <= rest + 0.5, landed.minY - position.offsetInViewport <= landedTop { return true }
        }
        return false
    }

    func restore(_ position: ReadingPosition, whileValid: @escaping () -> Bool,
                 didRestore: @escaping (ReadingPosition) -> Void) {
        if owner.hasActiveComposition || owner.isWritingToolsActive {
            pendingNavigation = { [weak self] in self?.restore(position, whileValid: whileValid, didRestore: didRestore) }
            return
        }
        guard whileValid(), let previous = readingPosition(), restore(position) else { return }
        didRestore(previous)
    }

    func navigationSnapshot() -> MarkdownSectionNavigationSnapshot? {
        let view = owner.textView
        guard let storage = view.textStorage, let scroll = view.enclosingScrollView,
              view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        var targets: [MarkdownSectionTarget] = []
        storage.enumerateAttribute(NativeSemanticAttributes.paragraphRole, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let role = value as? NativeSemanticParagraphRole, case .heading(let level) = role else { return }
            let title = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            targets.append(MarkdownSectionTarget(rank: targets.count, level: level, title: String(title.prefix(160)),
                editor: identity, document: 0, source: Int(truncatingIfNeeded: owner.revision), anchor: range.location))
        }
        var visible: Set<Int> = []
        for (index, target) in targets.enumerated() {
            guard let rect = lineRect(at: target.anchor) else { continue }
            let end = index + 1 < targets.count ? lineRect(at: targets[index + 1].anchor)?.minY ?? view.bounds.maxY : view.bounds.maxY
            if rect.minY < view.visibleRect.maxY && end > view.visibleRect.minY { visible.insert(target.rank) }
        }
        let row = owner.configuration.readingWidth ?? view.bounds.width
        return MarkdownSectionNavigationSnapshot(targets: targets, visibleRanks: visible,
            fitsViewportWidth: row * scroll.magnification <= scroll.contentSize.width + 1)
    }

    func preview(_ target: MarkdownSectionTarget) -> MarkdownSectionPreview? {
        guard valid(target), let snapshot = navigationSnapshot(), snapshot.targets.contains(target) else { return nil }
        let text = owner.textView.string as NSString
        let end = target.rank + 1 < snapshot.targets.count ? snapshot.targets[target.rank + 1].anchor : text.length
        return MarkdownSectionPreview(title: target.title, body: text.substring(with:
            NSRange(location: target.anchor, length: min(2048, max(0, end - target.anchor)))))
    }

    func valid(_ target: MarkdownSectionTarget) -> Bool {
        target.editor == identity && target.source == Int(truncatingIfNeeded: owner.revision)
    }

    func scroll(to target: MarkdownSectionTarget, whileValid: @escaping () -> Bool, didNavigate: @escaping (ReadingPosition) -> Void) {
        if owner.hasActiveComposition || owner.isWritingToolsActive {
            pendingNavigation = { [weak self] in self?.scroll(to: target, whileValid: whileValid, didNavigate: didNavigate) }
            return
        }
        guard valid(target), whileValid(), !owner.hasActiveComposition, let previous = readingPosition() else { return }
        owner.textView.scrollRangeToVisible(NSRange(location: target.anchor, length: 0))
        if readingPosition() != previous { didNavigate(previous) }
    }
}
