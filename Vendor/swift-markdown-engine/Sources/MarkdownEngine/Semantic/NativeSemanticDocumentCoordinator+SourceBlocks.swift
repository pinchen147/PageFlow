import AppKit

extension NativeSemanticDocumentCoordinator {
    var activeSourceBlockSession: NativeSemanticSourceBlockSession? {
        guard let storage = textView.textStorage, let responder = textView.window?.firstResponder else { return nil }
        var focused: NativeSemanticSourceBlockSession?
        storage.enumerateAttribute(NativeSemanticSourceBlockSession.attribute, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let session = value as? NativeSemanticSourceBlockSession, responder === session.textView else { return }
            focused = session
            stop.pointee = true
        }
        return focused
    }
}
