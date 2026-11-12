import Foundation

/// One `par` of an EPUB 3 media overlay: a stretch of a recording and the
/// element of the chapter it reads.
public struct EPUBMediaOverlayClip: Equatable, Sendable {
    /// The element read, by id; nil for the whole chapter.
    public let fragment: String?
    /// The recording's path in the archive.
    public let audioPath: String
    public let begin: TimeInterval
    /// Nil plays on to the end of the recording.
    public let end: TimeInterval?
}

/// A chapter's narration: its clips in reading order.
public struct EPUBMediaOverlay: Equatable, Sendable {
    public let clips: [EPUBMediaOverlayClip]
    /// The package's `media:duration` for this overlay.
    public let duration: TimeInterval?
}

/// The narration a book carries, by chapter.
public struct EPUBMediaOverlays: Equatable, Sendable {
    public var chapters: [Int: EPUBMediaOverlay] = [:]
    /// The package's `media:duration` for the whole book.
    public var duration: TimeInterval?

    public var isEmpty: Bool { chapters.isEmpty }
}

public extension EPUBBook {
    /// Writes one of the book's audio files to a new file at `url`. Audio is
    /// too large to hold in memory, and players need to seek in it.
    func extractAudio(_ path: String, to url: URL, limit: Int) throws {
        try ArchiveReader(url: sourceURL).extract(path, to: url, limit: limit)
    }
}

enum MediaOverlayParser {
    /// All a book's SMIL together may not inflate past this.
    private static let totalLimit = 64 * 1024 * 1024
    private static let documentLimit = 8 * 1024 * 1024

    /// Every chapter's narration. One that can't be read just has none:
    /// narration never keeps a book from opening.
    static func overlays(package: ParsedPackage, archive: ArchiveReader) -> EPUBMediaOverlays {
        var overlays = EPUBMediaOverlays(duration: package.mediaDuration)
        var budget = totalLimit
        for (index, item) in package.spine.enumerated() {
            guard let id = item.mediaOverlay, let smil = package.manifest[id],
                  let data = try? archive.read(smil.path, limit: min(budget, documentLimit)) else { continue }
            budget -= data.count
            let clips = (try? clips(in: data, smilPath: smil.path, chapterPath: item.path, archive: archive)) ?? []
            if !clips.isEmpty {
                overlays.chapters[index] = EPUBMediaOverlay(clips: clips, duration: package.mediaDurations[id])
            }
        }
        return overlays
    }

    /// The clips of a SMIL document that read `chapterPath`, in document
    /// order through any nesting. A `par` that can't be played is left out;
    /// the rest of the narration still plays.
    static func clips(in data: Data, smilPath: String, chapterPath: String,
                      archive: ArchiveReader) throws -> [EPUBMediaOverlayClip] {
        let document = try XMLDocumentParser.parse(data)
        guard let root = document.root, root.localName == "smil",
              let body = root.children.first(where: { $0.localName == "body" }) else {
            throw EPUBError.invalidContent(smilPath)
        }
        let base = (smilPath as NSString).deletingLastPathComponent
        // Clips of one recording share a path, resolved once.
        var audioPaths: [String: String?] = [:]
        var clips: [EPUBMediaOverlayClip] = []

        func clip(of par: XMLNode) -> EPUBMediaOverlayClip? {
            guard let text = par.children.first(where: { $0.localName == "text" })?.attribute(named: "src"),
                  let audio = par.children.first(where: { $0.localName == "audio" }),
                  let source = audio.attribute(named: "src") else { return nil }
            let target = text.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard ArchivePath.normalized(String(target[0]), relativeTo: base) == chapterPath else { return nil }
            if audioPaths[source] == nil {
                let path = isRemote(source) ? nil : ArchivePath.normalized(source.removingFragment, relativeTo: base)
                audioPaths[source] = .some(path.flatMap { archive.contains($0) ? $0 : nil })
            }
            guard let audioPath = audioPaths[source] ?? nil else { return nil }
            var begin: TimeInterval = 0
            if let raw = audio.attribute(named: "clipBegin") {
                guard let value = clockValue(raw) else { return nil }
                begin = value
            }
            var end: TimeInterval?
            if let raw = audio.attribute(named: "clipEnd") {
                guard let value = clockValue(raw), value > begin else { return nil }
                end = value
            }
            return EPUBMediaOverlayClip(fragment: target.count == 2 && !target[1].isEmpty ? String(target[1]) : nil,
                                        audioPath: audioPath, begin: begin, end: end)
        }
        func walk(_ node: XMLNode) {
            for child in node.children {
                switch child.localName {
                case "par": if let clip = clip(of: child) { clips.append(clip) }
                case "seq": walk(child)
                default: break
                }
            }
        }
        walk(body)
        return clips
    }

    private static func isRemote(_ source: String) -> Bool {
        source.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
    }

    /// A SMIL clock value in seconds: full (`1:02:03.5`), partial (`02:03`)
    /// or a timecount (`3.2h`, `45min`, `30s`, `5ms`, `12.5`). Nil if malformed.
    static func clockValue(_ raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3, let seconds = decimal(parts[parts.count - 1]), seconds < 60,
                  let minutes = decimal(parts[parts.count - 2]), minutes < 60,
                  !parts[parts.count - 2].contains(".") else { return nil }
            guard parts.count == 3 else { return minutes * 60 + seconds }
            guard let hours = decimal(parts[0]), !parts[0].contains(".") else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        }
        let metrics: [(suffix: String, seconds: TimeInterval)] = [("min", 60), ("ms", 0.001), ("h", 3600), ("s", 1)]
        for metric in metrics where value.hasSuffix(metric.suffix) {
            return decimal(value.dropLast(metric.suffix.count)).map { $0 * metric.seconds }
        }
        return decimal(Substring(value))
    }

    /// Digits with an optional fraction, and nothing else `Double` would take.
    private static func decimal(_ text: Substring) -> Double? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }) else {
            return nil
        }
        return Double(text)
    }
}
