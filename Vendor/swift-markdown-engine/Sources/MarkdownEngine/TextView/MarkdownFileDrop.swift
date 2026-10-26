import Foundation

/// What a file drag over the note carries (doc 26 §9.1), reported to the host
/// while it hovers so the host can keep its own drop overlay out of the way.
public enum MarkdownFileDragKind: Equatable, Sendable {
    /// At least one image (a file, image data or a file promise): the editor
    /// shows its drop line, and the host's overlay should stay hidden.
    case images
    /// Only documents the host opens: no drop line; the host shows its overlay.
    case documents
}

/// Images dropped on the note, handed to the host to store (doc 26 §9.2).
public struct MarkdownImageDrop {
    /// Image files in drop order. Promised files (Photos, Mail) arrive here
    /// once received into a temporary folder; the host copies them away.
    public var fileURLs: [URL]
    /// The image a drag carried as data with no file (a browser, Preview),
    /// as PNG.
    public var imageData: Data?

    /// Creates an import request from ordered file URLs and optional PNG data.
    public init(fileURLs: [URL] = [], imageData: Data? = nil) {
        self.fileURLs = fileURLs
        self.imageData = imageData
    }
}
