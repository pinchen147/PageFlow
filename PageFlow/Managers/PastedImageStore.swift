//
//  PastedImageStore.swift
//  PageFlow
//
//  Images arriving on the pasteboard — a file dragged in, a file copied in
//  Finder, or raw image data from a screenshot or a clipboard manager —
//  become markdown image links the note's image provider can resolve.
//
//  A file keeps its place: the link is relative when the file sits inside the
//  note's folder, absolute otherwise, and the sandbox access granted for the
//  drop is remembered as a security-scoped bookmark for later launches.
//
//  Image data has no place yet: it is saved as a PNG in an `attachments`
//  folder beside the note (the Obsidian convention), after the user allows
//  that folder once; an untitled note, or a declined grant, keeps it in the
//  app's own Attachments folder with an absolute link until the note is
//  saved somewhere, when it moves beside the note and the link turns relative.
//

import AppKit
import Foundation
import MarkdownEngine
import UniformTypeIdentifiers

/// Not actor-bound: the image provider asks for remembered access from
/// whichever thread styles (the main thread in the app, any in tests); a lock
/// guards the small bookmark list.
final class PastedImageStore: @unchecked Sendable {
    static let shared = PastedImageStore()

    private static let storageKey = "droppedImageBookmarks.v1"
    private static let capacity = 500
    static let attachmentsFolderName = "attachments"

    private let defaults: UserDefaults
    private let folderAccess: FolderAccessStore
    private let fallbackFolder: URL
    private let lock = NSLock()
    /// Absolute path → security-scoped bookmark, newest last.
    private var bookmarks: [(path: String, bookmark: Data)]

    init(defaults: UserDefaults = .standard, folderAccess: FolderAccessStore = .shared,
         fallbackFolder: URL = PastedImageStore.fallbackAttachmentsFolder) {
        self.defaults = defaults
        self.folderAccess = folderAccess
        self.fallbackFolder = fallbackFolder
        let stored = defaults.array(forKey: Self.storageKey) as? [[String: Any]] ?? []
        bookmarks = stored.compactMap { entry in
            guard let path = entry["path"] as? String, let bookmark = entry["bookmark"] as? Data else { return nil }
            return (path, bookmark)
        }
    }

    // MARK: - Links

    /// The markdown for what the pasteboard holds: one `![name](path)` line per
    /// image file, or one for image data saved to disk; `nil` when it holds
    /// neither. Remembers access to each file it links.
    @MainActor
    func markdownLinks(for pasteboard: NSPasteboard, documentURL: URL?) -> String? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(Self.isImage)
        if !urls.isEmpty {
            for url in urls { remember(url) }
            return urls.map { Self.link(for: $0, documentURL: documentURL) }.joined(separator: "\n\n")
        }
        guard let data = PasteboardImageReader.imageData(from: pasteboard),
              let saved = save(data, documentURL: documentURL) else { return nil }
        return Self.link(for: saved, documentURL: documentURL)
    }

    /// The markdown for one image file: relative to the note's folder when the
    /// file is inside it, absolute otherwise; angle-bracketed when the path has
    /// a space or a parenthesis (the one form every reader agrees on).
    static func link(for url: URL, documentURL: URL?) -> String {
        "![\(url.deletingPathExtension().lastPathComponent)](\(destination(for: url, documentURL: documentURL)))"
    }

    /// The link destination for `url`: relative inside the note's folder,
    /// angle-bracketed when it holds a space or parenthesis.
    static func destination(for url: URL, documentURL: URL?) -> String {
        let path = url.standardizedFileURL.path
        let folder = documentURL?.standardizedFileURL.deletingLastPathComponent().path
        let destination: String
        if let folder, path.hasPrefix(folder + "/") {
            destination = String(path.dropFirst(folder.count + 1))
        } else {
            destination = path
        }
        let needsBrackets = destination.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
        return needsBrackets ? "<\(destination)>" : destination
    }

    static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - Saving image data

    /// Where pasted image data goes for a note without a folder, or when the
    /// note's folder was not allowed.
    static var fallbackAttachmentsFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PageFlow/Attachments", isDirectory: true)
    }

    /// Obsidian's timestamped base name; saving adds a numeric suffix on collision.
    nonisolated static func pastedImageName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "Pasted image \(formatter.string(from: date)).png"
    }

    /// Saves `data` beside the note (asking for the folder once) or in the
    /// fallback folder, and returns the file written.
    @MainActor
    func save(_ data: Data, documentURL: URL?, name: String = pastedImageName()) -> URL? {
        if let folder = documentURL?.standardizedFileURL.deletingLastPathComponent() {
            let attachments = folder.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
            if let url = write(data, named: name, into: attachments) { return url }
            let allowed = folderAccess.requestAccess(
                to: folder,
                message: "Allow PageFlow to save pasted images in an “\(Self.attachmentsFolderName)” folder next to this note."
            )
            if allowed, let url = write(data, named: name, into: attachments) { return url }
        }
        return write(data, named: name, into: fallbackFolder)
    }

    /// Images pasted before the note had a folder sit in the fallback folder
    /// behind absolute links, which name the user's home and break on any
    /// other Mac. Once the note is saved at `noteURL`, each moves into the
    /// `attachments` folder beside it; returns the link edits for `text`
    /// (alt text kept), empty when nothing moved.
    @MainActor
    func adoptFallbackImages(in text: String, savedAt noteURL: URL) -> [(range: NSRange, link: String)] {
        let source = text as NSString
        let prefix = fallbackFolder.standardizedFileURL.path + "/"
        let folder = noteURL.deletingLastPathComponent()
        let attachments = folder.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
        var edits: [(range: NSRange, link: String)] = []
        var askedForAccess = false
        for match in Self.imageLinkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var destination = source.substring(with: match.range(at: 2))
            if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
            let file = URL(fileURLWithPath: destination).standardizedFileURL
            guard file.path.hasPrefix(prefix), let data = try? Data(contentsOf: file) else { continue }
            var moved = write(data, named: file.lastPathComponent, into: attachments)
            if moved == nil, !askedForAccess {
                askedForAccess = true
                if folderAccess.requestAccess(
                    to: folder,
                    message: "Allow PageFlow to move this note's pasted images into an “\(Self.attachmentsFolderName)” folder next to it."
                ) {
                    moved = write(data, named: file.lastPathComponent, into: attachments)
                }
            }
            guard let moved else { continue }
            try? FileManager.default.removeItem(at: file)
            let alt = source.substring(with: match.range(at: 1))
            edits.append((match.range, "![\(alt)](\(Self.destination(for: moved, documentURL: noteURL)))"))
        }
        return edits
    }

    /// `![alt](destination)`: group 1 the alt text, group 2 the destination.
    private static let imageLinkPattern = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\((<[^>]*>|[^)\s]+)\)"#)

    private func write(_ data: Data, named name: String, into folder: URL) -> URL? {
        folderAccess.withAccess(to: folder) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var url = folder.appendingPathComponent(name)
                let stem = url.deletingPathExtension().lastPathComponent
                let fileExtension = url.pathExtension
                var copyIndex = 0
                while true {
                    do {
                        try data.write(to: url, options: .withoutOverwriting)
                        return url
                    } catch let error as CocoaError where error.code == .fileWriteFileExists {
                        copyIndex += 1
                        let candidate = "\(stem) (\(copyIndex))"
                        url = folder.appendingPathComponent(fileExtension.isEmpty ? candidate : "\(candidate).\(fileExtension)")
                    }
                }
            } catch {
                return nil
            }
        }
    }

    // MARK: - Access across launches

    /// Runs `body` with the sandbox access this app was granted for `url`
    /// when it was dropped, if any was recorded; `nil` when none is stored.
    func withRememberedAccess<T>(to url: URL, _ body: (URL) -> T?) -> T? {
        let path = url.standardizedFileURL.path
        lock.lock()
        let entry = bookmarks.last(where: { $0.path == path })
        lock.unlock()
        guard let entry else { return nil }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope,
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let opened = resolved.startAccessingSecurityScopedResource()
        defer { if opened { resolved.stopAccessingSecurityScopedResource() } }
        if stale { remember(resolved) }
        return body(resolved)
    }

    private func remember(_ url: URL) {
        guard let bookmark = url.pageFlowSecurityScopedBookmark else { return }
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        bookmarks.removeAll { $0.path == path }
        bookmarks.append((path, bookmark))
        if bookmarks.count > Self.capacity { bookmarks.removeFirst(bookmarks.count - Self.capacity) }
        defaults.set(bookmarks.map { ["path": $0.path, "bookmark": $0.bookmark] }, forKey: Self.storageKey)
    }
}
