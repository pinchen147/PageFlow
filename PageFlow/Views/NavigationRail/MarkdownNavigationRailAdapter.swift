import AppKit
import MarkdownEngine

/// Binds canonical engine publication only while this concrete editor host is eligible.
@MainActor
final class MarkdownNavigationRailAdapter {
    let rail = NavigationRailView()
    private weak var content: MarkdownContent?
    private weak var container: MarkdownEditorSurfaceContainer?
    private var snapshot: MarkdownSectionNavigationSnapshot?
    private var enabled = false
    private var requestedEligible = false
    private var topInset: CGFloat = 0
    private var geometryObservers: [NSObjectProtocol] = []
    private weak var observedScroll: NSScrollView?

    init(content: MarkdownContent, container: MarkdownEditorSurfaceContainer) {
        self.content = content
        self.container = container
        rail.autoresizingMask = [.width, .height]
        rail.frame = container.bounds
        rail.reservedNativeHit = { [weak container] in container?.nativeControl(at: $0) }
        rail.paintExclusions = { [weak container, weak rail] in
            guard let container, let rail else { return [] }
            var exclusions = container.nativeControlRects(in: rail)
            // Exit animation retains marks after interaction has retired. Reserve
            // prose throughout their leftward travel, just as native controls.
            if var prose = container.nativeProseRect(in: rail) {
                if !rail.eligible { prose.size.width += DesignTokens.navigationRailSlideDistance }
                exclusions.append(prose)
            } else {
                exclusions.append(rail.bounds)
            }
            return exclusions
        }
        rail.targetAtRank = { [weak self] rank in
            guard let targets = self?.snapshot?.targets, targets.indices.contains(rank) else { return nil }
            return .section(targets[rank])
        }
        rail.makePreview = { [weak self] target in
            guard let self, case .section(let section) = target,
                  let preview = self.content?.editorController.sectionPreview(for: section) else { return nil }
            let card = MarkdownSectionPreviewView(preview: preview)
            let generation = self.rail.generation
            card.onActivate = { [weak self, weak card] in
                guard let self, card?.superview === self.rail else { return }
                self.activate(section, generation: generation)
            }
            return card
        }
        rail.onActivate = { [weak self] target, generation in
            guard case .section(let section) = target else { return }
            self?.activate(section, generation: generation)
        }
    }

    deinit {
        for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func update(eligible: Bool, topInset: CGFloat, onShowSidebar: @escaping () -> Void) {
        self.topInset = topInset
        rail.onShowSidebar = onShowSidebar
        requestedEligible = eligible
        hostPresenceChanged()
    }

    func hostPresenceChanged() {
        guard let content, let container, content.retainedEditorSurface?.owner === container else { detach(); return }
        let available = requestedEligible && content.retainedEditorSurface?.activePresentation != nil
        enabled = available
        if available {
            observeGeometry(in: container)
            content.editorController.onSectionNavigationChange = { [weak self] snapshot in self?.apply(snapshot) }
            if content.editorController.isSectionNavigationEnabled {
                // Explicit host reconciliation; callbacks consume the committed value.
                apply(content.editorController.sectionNavigationSnapshot)
            } else {
                // Enabling performs the initial reconciliation and publication once.
                content.editorController.isSectionNavigationEnabled = true
            }
        } else {
            removeGeometryObservers()
            content.editorController.onSectionNavigationChange = nil
            content.editorController.isSectionNavigationEnabled = false
            apply(nil)
        }
    }

    private func apply(_ committed: MarkdownSectionNavigationSnapshot?) {
        if enabled { snapshot = committed }
        if let container, rail.superview !== container {
            rail.frame = container.bounds
            container.addSubview(rail)
        }
        let targets = snapshot?.targets ?? []
        let eligible = enabled && !targets.isEmpty && snapshot?.fitsViewportWidth == true
            && container?.nativeProseRect(in: rail).map { $0.minX >= NavigationRailView.laneWidth } == true
        rail.configure(kind: .markdown, count: targets.count, visible: snapshot?.visibleRanks ?? [],
            identity: targets.first as AnyHashable, eligible: eligible, topInset: topInset)
    }

    /// Canonical publications deduplicate equal heading/visible-rank snapshots.
    /// Native scale, pan and resize must also reconcile physical lane clearance.
    private func observeGeometry(in container: MarkdownEditorSurfaceContainer) {
        guard let scroll = content?.retainedEditorSurface?.nativeView,
              observedScroll !== scroll else { return }
        removeGeometryObservers()
        observedScroll = scroll
        let views: [(NSView, Notification.Name)] = [
            (scroll.contentView, NSView.boundsDidChangeNotification),
            (scroll.contentView, NSView.frameDidChangeNotification)
        ] + (container.nativeBodyTextView.map { [($0, NSView.frameDidChangeNotification)] } ?? [])
        // These notifications are already enabled by the retained editor. Do not
        // change shared AppKit notification flags or run TextKit layout per event.
        for (view, name) in views {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: view, queue: .main) { [weak self, weak scroll, weak container] _ in
                MainActor.assumeIsolated {
                    guard let self, let scroll, let container, self.enabled,
                          self.observedScroll === scroll,
                          self.content?.retainedEditorSurface?.owner === container,
                          self.content?.retainedEditorSurface?.activePresentation != nil else { return }
                    self.apply(self.snapshot)
                }
            })
        }
    }

    private func removeGeometryObservers() {
        for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }
        geometryObservers.removeAll()
        observedScroll = nil
    }

    func detach() {
        removeGeometryObservers()
        enabled = false
        if let content, let container, content.retainedEditorSurface?.owner === container {
            content.editorController.onSectionNavigationChange = nil
            content.editorController.isSectionNavigationEnabled = false
        }
        snapshot = nil
        rail.retire()
        rail.removeFromSuperview()
    }

    private func activate(_ target: MarkdownSectionTarget, generation: Int) {
        guard enabled, rail.generation == generation else { return }
        content?.navigateToSection(target, whileValid: { [weak self] in
            guard let self else { return false }
            return self.enabled && self.rail.eligible && self.rail.generation == generation
                && self.rail.window != nil && !self.rail.isHiddenOrHasHiddenAncestor
        })
    }
}
