//
//  PastedImageStore.swift
//  PageFlow
//
//  Images arriving in a note — files dropped on it, files copied in Finder
//  and pasted, a file picked in Insert → Image, or raw image data from a
//  browser, a screenshot or a clipboard manager — become markdown image
//  links the note's image provider can resolve (doc 26 §9.2).
//
//  A file already inside the note's folder keeps its place behind a relative
//  link. Any other file is copied into an `attachments` folder beside the
//  note (the Obsidian convention), and image data is saved there as a PNG,
//  after the user allows that folder once; an untitled note, or a declined
//  grant, keeps them in the app's own Attachments folder with an absolute
//  link until the note is saved somewhere, when they move beside the note
//  and the link turns relative. The sandbox access granted for a drop is
//  remembered as a security-scoped bookmark.
//

import AppKit
import Foundation
import ImageIO
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
    /// Absolute path → security-scoped bookmark, newest last. Guarded by `lock`.
    nonisolated(unsafe) private var bookmarks: [(path: String, bookmark: Data)]

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
    /// image file, copied into the note's `attachments` folder unless it is
    /// already inside the note's folder (doc 26 Q5), or one for image data
    /// saved there; `nil` when it holds neither. `report` gets the messages
    /// for files that could not be added.
    @MainActor
    func markdownLinks(for pasteboard: NSPasteboard, documentURL: URL?, report: ((String) -> Void)? = nil) -> String? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(Self.isImage)
        if !urls.isEmpty {
            let imported = importImageFiles(urls, documentURL: documentURL)
            if let message = imported.message { report?(message) }
            return imported.links.isEmpty ? nil : imported.links.joined(separator: "\n\n")
        }
        guard let data = PasteboardImageReader.imageData(from: pasteboard),
              let saved = save(data, documentURL: documentURL) else { return nil }
        return Self.link(for: saved, documentURL: documentURL)
    }

    /// The markdown for one image file: relative to the note's folder when the
    /// file is inside it, absolute otherwise; angle-bracketed when the path has
    /// a space or a parenthesis (the one form every reader agrees on).
    nonisolated static func link(for url: URL, documentURL: URL?) -> String {
        let description = ImageAltTokens.sanitizedDescription(url.deletingPathExtension().lastPathComponent)
        return "![\(description)](\(destination(for: url, documentURL: documentURL)))"
    }

    /// The link destination for `url`: relative inside the note's folder,
    /// angle-bracketed when it holds a space or parenthesis.
    nonisolated static func destination(for url: URL, documentURL: URL?) -> String {
        let path = url.standardizedFileURL.path
        let folder = documentURL?.standardizedFileURL.deletingLastPathComponent().path
        let destination: String
        if let folder, path.hasPrefix(folder + "/") {
            destination = String(path.dropFirst(folder.count + 1))
        } else {
            destination = path
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: " ()")
        allowed.remove(charactersIn: "%#?<>\\:")
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: allowed) ?? destination
        let needsBrackets = encoded.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
        return needsBrackets ? "<\(encoded)>" : encoded
    }

    static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: - Importing image files (doc 26 §9.2, §9.4)

    /// One drop or paste adds at most this many images, each at most this large.
    nonisolated static let maxImagesPerImport = 20
    nonisolated static let maxImageBytes = 20 * 1024 * 1024

    /// What an import added, in order, and what went wrong.
    nonisolated struct ImageImport: Sendable {
        var links: [String] = []
        var messages: [String] = []

        /// The one toast for the import: the first message, with a count of the rest.
        var message: String? {
            guard let first = messages.first else { return nil }
            return messages.count == 1 ? first : "\(first) (\(messages.count - 1) more not added)"
        }
    }

    /// Copied files retain their identity until main-actor delivery chooses the
    /// note's current folder. Save As may change it while a copy is running.
    nonisolated private struct ImportedImages: Sendable {
        var images: [(file: URL, description: String)] = []
        var messages: [String] = []

        func formatted(relativeTo documentURL: URL?) -> ImageImport {
            ImageImport(links: images.map {
                "![\($0.description)](\(PastedImageStore.destination(for: $0.file, documentURL: documentURL)))"
            }, messages: messages)
        }
    }

    /// Why one image was not added, as the window toast says it.
    nonisolated enum ImportFailure: Error {
        case unsupported, tooLarge, empty, failed

        func message(for name: String) -> String {
            switch self {
            case .unsupported: "“\(name)” isn’t a supported image. Use a PNG, JPEG, GIF, WebP, HEIC or TIFF file."
            case .tooLarge: "“\(name)” is too large to add (20 MB max)."
            case .empty: "“\(name)” is empty."
            case .failed: "Couldn’t add “\(name)”. Try again."
            }
        }
    }

    /// An import decided on the main thread (which files, where copies go),
    /// carried out off it.
    nonisolated private struct ImportPlan: Sendable {
        var files: [URL] = []
        var data: Data?
        var documentURL: URL?
        /// Where copies go; nil when nothing needs copying.
        var destination: URL?
        var messages: [String] = []
        let dataName = PastedImageStore.pastedImageName()
    }

    /// Imports dropped images: copies run off the main thread and `completion`
    /// gets the links on it. The folder prompt, when needed, comes first.
    @MainActor
    func importImages(_ files: [URL], data: Data?, documentURL: @escaping @MainActor () -> URL?,
                      completion: @escaping @MainActor (ImageImport) -> Void) {
        let plan = plan(files, data: data, documentURL: documentURL())
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = perform(plan)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                completion(result.formatted(relativeTo: documentURL()))
            } }
        }
    }

    /// Imports image files synchronously: a paste or Insert → Image.
    @MainActor
    func importImageFiles(_ files: [URL], documentURL: URL?) -> ImageImport {
        perform(plan(files, data: nil, documentURL: documentURL)).formatted(relativeTo: documentURL)
    }

    /// Caps the count, remembers access to each file, and settles the folder
    /// copies go to (asking for it once) unless every file can stay put.
    @MainActor
    private func plan(_ files: [URL], data: Data?, documentURL: URL?) -> ImportPlan {
        var plan = ImportPlan(documentURL: documentURL)
        plan.files = Array(files.prefix(Self.maxImagesPerImport))
        plan.data = plan.files.count < Self.maxImagesPerImport ? data : nil
        if files.count + (data == nil ? 0 : 1) > Self.maxImagesPerImport {
            plan.messages.append("Only the first \(Self.maxImagesPerImport) images were added.")
        }
        for url in plan.files { remember(url) }
        let folder = Self.noteFolder(of: documentURL)
        let needsCopy = plan.data != nil || plan.files.contains { Self.isSupportedImage($0) && !Self.isInside($0, folder) }
        if needsCopy { plan.destination = attachmentsFolder(for: documentURL) }
        return plan
    }

    /// Links each file in order: in place inside the note's folder, else a
    /// copy in the plan's folder; image data saved there too.
    nonisolated private func perform(_ plan: ImportPlan) -> ImportedImages {
        var result = ImportedImages(messages: plan.messages)
        let folder = Self.noteFolder(of: plan.documentURL)
        for url in plan.files {
            let outcome: Result<URL, ImportFailure> = accessing(url) { source in
                if let failure = Self.validate(source) { return .failure(failure) }
                if Self.isInside(url, folder) { return .success(url) }
                guard let destination = plan.destination,
                      let copy = self.copy(source, named: url.lastPathComponent, into: destination) else { return .failure(.failed) }
                return .success(copy)
            }
            switch outcome {
            case .success(let file):
                let stem = ImageAltTokens.sanitizedDescription(url.deletingPathExtension().lastPathComponent)
                result.images.append((file, stem))
            case .failure(let failure):
                result.messages.append(failure.message(for: url.lastPathComponent))
            }
        }
        if let data = plan.data {
            if let destination = plan.destination, let saved = write(data, named: plan.dataName, into: destination) {
                result.images.append((saved, ImageAltTokens.sanitizedDescription(saved.deletingPathExtension().lastPathComponent)))
            } else {
                result.messages.append(ImportFailure.failed.message(for: plan.dataName))
            }
        }
        return result
    }

    /// Why `url` can't be added, or nil: an image type ImageIO decodes (SVG
    /// and PDF are not images here), not empty, at most 20 MB.
    nonisolated static func validate(_ url: URL) -> ImportFailure? {
        guard isSupportedImage(url) else { return .unsupported }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return .failed }
        if size == 0 { return .empty }
        if size > maxImageBytes { return .tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            return .unsupported
        }
        return nil
    }

    nonisolated static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    nonisolated private static func noteFolder(of documentURL: URL?) -> URL? {
        documentURL?.standardizedFileURL.deletingLastPathComponent()
    }

    nonisolated private static func isInside(_ url: URL, _ folder: URL?) -> Bool {
        guard let folder else { return false }
        return url.standardizedFileURL.path.hasPrefix(folder.path + "/")
    }

    /// The note's `attachments` folder when it can be written (asking once),
    /// else the fallback folder.
    @MainActor
    private func attachmentsFolder(for documentURL: URL?) -> URL {
        guard let folder = Self.noteFolder(of: documentURL) else { return fallbackFolder }
        let attachments = folder.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
        if canWrite(into: attachments) { return attachments }
        let allowed = folderAccess.requestAccess(
            to: folder,
            message: "Allow PageFlow to save images in an “\(Self.attachmentsFolderName)” folder next to this note."
        )
        return allowed && canWrite(into: attachments) ? attachments : fallbackFolder
    }

    /// Whether a file can be written into `folder` (creating it), tried for
    /// real: the sandbox answers only to a write.
    nonisolated private func canWrite(into folder: URL) -> Bool {
        folderAccess.withAccess(to: folder) {
            let probe = folder.appendingPathComponent(".pageflow-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data().write(to: probe)
                try? FileManager.default.removeItem(at: probe)
                return true
            } catch {
                return false
            }
        }
    }

    /// Runs `body` on `url` with the access its drop left, if any; else as is.
    nonisolated private func accessing<T>(_ url: URL, _ body: (URL) -> T) -> T {
        var result: T?
        _ = withRememberedAccess(to: url) { resolved -> Bool? in
            result = body(resolved)
            return true
        }
        return result ?? body(url)
    }

    /// Copies `source` into `folder` as `name`, adding " (n)" on a clash.
    nonisolated private func copy(_ source: URL, named name: String, into folder: URL) -> URL? {
        folderAccess.withAccess(to: folder) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return Self.firstFreeName(name, in: folder) { url in
                try FileManager.default.copyItem(at: source, to: url)
            }
        }
    }

    /// Writes through `attempt` at `folder/name`, then "name (1)", "name (2)"…
    /// while the name is taken; nil on any other failure.
    nonisolated private static func firstFreeName(_ name: String, in folder: URL, attempt: (URL) throws -> Void) -> URL? {
        var url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension
        var copyIndex = 0
        while true {
            do {
                try attempt(url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                copyIndex += 1
                let candidate = "\(stem) (\(copyIndex))"
                url = folder.appendingPathComponent(fileExtension.isEmpty ? candidate : "\(candidate).\(fileExtension)")
            } catch {
                return nil
            }
        }
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
    func adoptFallbackImages(in text: String, savedAt noteURL: URL, whileApproved: () -> Bool = { true }) -> [(range: NSRange, link: String)] {
        guard whileApproved() else { return [] }
        let source = text as NSString
        let prefix = fallbackFolder.standardizedFileURL.path + "/"
        let folder = noteURL.deletingLastPathComponent()
        let attachments = folder.appendingPathComponent(Self.attachmentsFolderName, isDirectory: true)
        var edits: [(range: NSRange, link: String)] = []
        var askedForAccess = false
        var adopted: [URL: URL] = [:]
        for match in Self.imageLinkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var destination = source.substring(with: match.range(at: 2))
            if destination.hasPrefix("<"), destination.hasSuffix(">") { destination = String(destination.dropFirst().dropLast()) }
            let file = URL(fileURLWithPath: destination.removingPercentEncoding ?? destination).standardizedFileURL
            guard file.path.hasPrefix(prefix) else { continue }
            let moved: URL
            if let existing = adopted[file] {
                moved = existing
            } else {
                guard let data = try? Data(contentsOf: file) else { continue }
                var saved = write(data, named: file.lastPathComponent, into: attachments)
                if saved == nil, !askedForAccess {
                    askedForAccess = true
                    if folderAccess.requestAccess(
                        to: folder,
                        message: "Allow PageFlow to move this note's pasted images into an “\(Self.attachmentsFolderName)” folder next to it."
                    ) {
                        guard whileApproved() else { return [] }
                        saved = write(data, named: file.lastPathComponent, into: attachments)
                    }
                }
                guard let saved else { continue }
                adopted[file] = saved
                moved = saved
            }
            let alt = source.substring(with: match.range(at: 1))
            edits.append((match.range, "![\(alt)](\(Self.destination(for: moved, documentURL: noteURL)))"))
        }
        guard whileApproved() else { return [] }
        for file in adopted.keys { try? FileManager.default.removeItem(at: file) }
        return edits
    }

    /// `![alt](destination)`: group 1 the alt text, group 2 the destination.
    private static let imageLinkPattern = try! NSRegularExpression(pattern: #"!\[((?:\\.|[^\]\\])*)\]\((<[^>]*>|[^)\s]+)\)"#)

    nonisolated private func write(_ data: Data, named name: String, into folder: URL) -> URL? {
        folderAccess.withAccess(to: folder) {
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
                return nil
            }
            return Self.firstFreeName(name, in: folder) { url in
                try data.write(to: url, options: .withoutOverwriting)
            }
        }
    }

    // MARK: - Access across launches

    /// Runs `body` with the sandbox access this app was granted for `url`
    /// when it was dropped, if any was recorded; `nil` when none is stored.
    nonisolated func withRememberedAccess<T>(to url: URL, _ body: (URL) -> T?) -> T? {
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

    nonisolated private func remember(_ url: URL) {
        guard let bookmark = url.pageFlowSecurityScopedBookmark else { return }
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        bookmarks.removeAll { $0.path == path }
        bookmarks.append((path, bookmark))
        if bookmarks.count > Self.capacity { bookmarks.removeFirst(bookmarks.count - Self.capacity) }
        defaults.set(bookmarks.map { ["path": $0.path, "bookmark": $0.bookmark] }, forKey: Self.storageKey)
    }
}
