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

    init(content: MarkdownContent, container: MarkdownEditorSurfaceContainer) {
        self.content = content
        self.container = container
        rail.autoresizingMask = [.width, .height]
        rail.frame = container.bounds
        rail.reservedNativeHit = { [weak container] in container?.nativeControl(at: $0) }
        rail.paintExclusions = { [weak container, weak rail] in
            guard let rail else { return [] }
            return container?.nativeControlRects(in: rail) ?? []
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
            content.editorController.onSectionNavigationChange = { [weak self] snapshot in self?.apply(snapshot) }
            if content.editorController.isSectionNavigationEnabled {
                // Explicit host reconciliation; callbacks consume the committed value.
                apply(content.editorController.sectionNavigationSnapshot)
            } else {
                // Enabling performs the initial reconciliation and publication once.
                content.editorController.isSectionNavigationEnabled = true
            }
        } else {
            content.editorController.onSectionNavigationChange = nil
            content.editorController.isSectionNavigationEnabled = false
            apply(nil)
        }
    }

    private func apply(_ committed: MarkdownSectionNavigationSnapshot?) {
        snapshot = enabled ? committed : nil
        let targets = snapshot?.targets ?? []
        rail.configure(kind: .markdown, count: targets.count, visible: snapshot?.visibleRanks ?? [],
            identity: targets.first as AnyHashable, eligible: enabled && !targets.isEmpty, topInset: topInset)
        if enabled, !targets.isEmpty, let container {
            if rail.superview !== container {
                rail.frame = container.bounds
                container.addSubview(rail)
            }
        } else if rail.superview != nil { rail.removeFromSuperview() }
    }

    func detach() {
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
