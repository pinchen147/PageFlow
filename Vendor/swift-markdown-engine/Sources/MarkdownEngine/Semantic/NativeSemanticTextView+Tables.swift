import AppKit

extension NativeSemanticTextView {
    func semanticTableSessions() -> [NativeSemanticTableSession] {
        guard let storage = textStorage else { return [] }
        var sessions: [NativeSemanticTableSession] = []
        storage.enumerateAttribute(NativeSemanticAttributes.tableSession, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let session = value as? NativeSemanticTableSession, !sessions.contains(where: { $0 === session }) { sessions.append(session) }
        }
        return sessions
    }

    func refreshSemanticTables() {
        guard let storage = textStorage, let layout = textLayoutManager,
              let content = layout.textContentManager else { return }
        if semanticCoordinator?.tableWidthBindingRevision != semanticCoordinator?.revision { semanticCoordinator?.refreshTableWidths() }
        if semanticTableProxy == nil, let scroll = enclosingScrollView {
            semanticTableProxy = TableProxyScroller(textView: self, scrollView: scroll)
        }
        var mounted = Set<ObjectIdentifier>()
        storage.enumerateAttribute(NativeSemanticAttributes.tableSession, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let session = value as? NativeSemanticTableSession else { return }
            session.isEditable = isEditable
            session.onFocus = { [weak semanticCoordinator] view in semanticCoordinator?.preferredInputView = view }
            session.onSelectionChange = { [weak semanticCoordinator] in semanticCoordinator?.onSelectionChange?() }
            session.onKeyEquivalent = { [weak semanticCoordinator, weak session] event, view in
                guard view.isEditable, !view.hasMarkedText(), let owner = semanticCoordinator,
                      let command = owner.keyBindings.command(for: event), let format = command.format else { return false }
                return session?.applyFormat(format) == true
            }
            mounted.insert(ObjectIdentifier(session))
            guard let location = content.location(content.documentRange.location, offsetBy: range.location) else { return }
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let rect = fragment.layoutFragmentFrame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            session.mount(in: self, origin: rect.origin, font: semanticCoordinator?.documentStorage.baseFont ?? font ?? .systemFont(ofSize: NSFont.systemFontSize))
        }
        semanticTableProxy?.update()
        for overlay in subviews.compactMap({ $0 as? WideTableOverlay }) {
            if let session = (overlay.documentView as? MarkdownTableGridView)?.semanticSession,
               !mounted.contains(ObjectIdentifier(session)) { session.detachPresentation() }
        }
        for grid in subviews.compactMap({ $0 as? MarkdownTableGridView }) {
            if let session = grid.semanticSession, !mounted.contains(ObjectIdentifier(session)) {
                session.chrome?.removeFromSuperview()
                grid.removeFromSuperview()
            }
        }
    }
}
