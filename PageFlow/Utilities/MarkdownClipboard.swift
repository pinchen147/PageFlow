import AppKit

/// Orders asynchronous Copy requests across every PDF tab and window.
@MainActor
final class MarkdownClipboard {
    static let shared = MarkdownClipboard(pasteboard: .general)
    struct Request {
        fileprivate let id: UUID
        fileprivate let changeCount: Int
    }
    private let pasteboard: NSPasteboard
    private var latestRequestID: UUID?

    init(pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func beginRequest() -> Request {
        let request = Request(id: UUID(), changeCount: pasteboard.changeCount)
        latestRequestID = request.id
        return request
    }

    func copy(_ text: String, for request: Request) {
        guard latestRequestID == request.id, pasteboard.changeCount == request.changeCount else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
