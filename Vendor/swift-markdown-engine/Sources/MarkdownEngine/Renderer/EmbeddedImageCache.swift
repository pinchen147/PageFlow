//
//  EmbeddedImageCache.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//

import AppKit
import CoreGraphics

/// Parsed `![[name|optional-id|tokens]]` reference. The head is the name plus
/// an optional UUID right after it; the parts after the head follow the alt
/// token grammar (`ImageAltTokens`): `![[shot.png|center|crop=…|420]]`.
public struct ImageEmbedReference: Sendable {
    private static let markdownRegex = try! NSRegularExpression(
        pattern: "!\\[\\[([^\\]\\r\\n]*)\\]\\]"
    )

    public let name: String
    public let nodeID: UUID?
    public let requestedWidth: CGFloat?
    public let alignment: ImageAltTokens.Alignment
    /// Normalized crop of the source image (top-left origin), nil for none.
    public let crop: CGRect?

    public init(name: String, nodeID: UUID? = nil, requestedWidth: CGFloat? = nil,
                alignment: ImageAltTokens.Alignment = .left, crop: CGRect? = nil) {
        self.name = name
        self.nodeID = nodeID
        self.requestedWidth = requestedWidth
        self.alignment = alignment
        self.crop = crop
    }

    public init?(content: String) {
        // Tokens are read from the right; what stops the scan (the name, the
        // id, an unknown part) is the head and stays as written.
        let tokens = ImageAltTokens.parse(content)
        let head = tokens.description
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let name = head.first, !name.isEmpty else { return nil }
        let nodeID = head.count > 1 ? UUID(uuidString: head[1]) : nil
        self.init(name: name, nodeID: nodeID, requestedWidth: tokens.width,
                  alignment: tokens.alignment, crop: tokens.crop)
    }

    public static func parse(markdown: String) -> ImageEmbedReference? {
        guard markdown.hasPrefix("![["), markdown.hasSuffix("]]") else { return nil }
        return ImageEmbedReference(content: String(markdown.dropFirst(3).dropLast(2)))
    }

    public static func replacingEmbeds(
        in text: String,
        transform: (ImageEmbedReference) -> String
    ) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let mutable = NSMutableString(string: text)
        let matches = markdownRegex.matches(in: text, range: fullRange).reversed()

        for match in matches {
            let rawContent = nsText.substring(with: match.range(at: 1))
            guard let reference = ImageEmbedReference(content: rawContent) else { continue }
            mutable.replaceCharacters(in: match.range, with: transform(reference))
        }

        return mutable as String
    }

    public var markdown: String {
        var head = name
        if let nodeID {
            head += "|" + nodeID.uuidString
        }
        let tokens = ImageAltTokens(description: head, width: requestedWidth, alignment: alignment, crop: crop)
        return "![[\(ImageAltTokens.format(tokens))]]"
    }

    /// Convert to the engine-side request shape consumed by `EmbeddedImageProvider`.
    public var providerRequest: EmbeddedImageRequest {
        EmbeddedImageRequest(
            name: name,
            id: nodeID?.uuidString,
            requestedWidth: requestedWidth
        )
    }
}

/// Caches images returned by an ``EmbeddedImageProvider``. The cache
/// invalidates when the provider's fingerprint changes, so the engine
/// stays correct even when the embedder swaps out its data source. Values are
/// weak: the provider and styled document own decoded pixels, so this reuse
/// index cannot defeat provider eviction or retain a closed document's images.
final class EmbeddedImageCache {
    static let shared = EmbeddedImageCache()
    private final class Entry {
        weak var image: NSImage?
        init(_ image: NSImage) { self.image = image }
    }

    private init() { cache.countLimit = 256 }

    private let cache = NSCache<NSString, Entry>()
    private var lastFingerprint: AnyHashable?

    func image(for reference: ImageEmbedReference, services: MarkdownEditorServices) -> NSImage? {
        let currentFingerprint = services.images.fingerprint()
        if currentFingerprint != lastFingerprint {
            cache.removeAllObjects()
            lastFingerprint = currentFingerprint
        }

        let cacheKey = reference.nodeID?.uuidString ?? reference.name
        if let cached = cache.object(forKey: cacheKey as NSString)?.image {
            return cached
        }

        guard let image = services.images.image(for: reference.providerRequest) else {
            return nil
        }

        cache.setObject(Entry(image), forKey: cacheKey as NSString)
        return image
    }
}
