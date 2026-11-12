import AppKit

extension NativeSemanticDocumentCoordinator {
    var activeTableSession: NativeSemanticTableSession? {
        guard let storage = textView.textStorage else { return nil }
        let responder = textView.window?.firstResponder
        var focused: NativeSemanticTableSession?
        storage.enumerateAttribute(NativeSemanticAttributes.tableSession, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let session = value as? NativeSemanticTableSession else { return }
            if let responder, responder === session.grid || (session.activeCellID.flatMap { session.editor(for: $0) }.map { responder === $0 } ?? false) {
                focused = session
                stop.pointee = true
            }
        }
        if let focused { return focused }
        let index = textView.selectedRange().location
        guard responder === textView, index < storage.length else { return nil }
        return storage.attribute(NativeSemanticAttributes.tableSession, at: index, effectiveRange: nil) as? NativeSemanticTableSession
    }

    func canPerformTable(_ command: MarkdownTableCommand) -> Bool {
        guard textView.isEditable, !isWritingToolsActive, let session = activeTableSession else { return false }
        return session.canPerform(command)
    }

    @discardableResult
    func performTable(_ command: MarkdownTableCommand) -> Bool {
        guard canPerformTable(command), let session = activeTableSession else { return false }
        if command == .editTableSource { return editTableSource(session: session) }
        if command == .deleteTable {
            var document = snapshot()
            guard let index = document.blocks.firstIndex(where: { documentStorage.tableSession(for: $0.id) === session }) else { return false }
            document.blocks.remove(at: index)
            install(document, selection: textView.selectedRange(), actionName: command.title)
            return true
        }
        return session.perform(command)
    }
}
