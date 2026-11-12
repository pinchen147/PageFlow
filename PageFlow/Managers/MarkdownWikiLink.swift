//
//  MarkdownWikiLink.swift
//  PageFlow
//
//  `[[Note]]` links the way Obsidian reads them: a target path, an optional
//  `#heading`, an optional `^block` (ignored), and an alias after `|` that the
//  editor shows instead. The resolver finds the target file off the main
//  thread: the exact path from the note's folder first, then the nearest
//  case-insensitive match in the note's folder tree and its parents, up to a
//  vault (a folder with `.obsidian`) or three levels up.
//

import Foundation
import MarkdownEngine

/// The parts of a wiki-link's target (the text before any `|alias`).
nonisolated struct MarkdownWikiLink: Equatable, Sendable {
    /// The file path as written; empty for a link within the same note.
    let path: String
    /// The heading to land on, if any.
    let heading: String?

    init(_ target: String) {
        var rest = Substring(target)
        if let pipe = rest.firstIndex(of: "|") { rest = rest[..<pipe] }
        var heading: String?
        if let hash = rest.firstIndex(of: "#") {
            // `Note#A#B` lands on the last heading; `Note#^id` is a block.
            let fragment = rest[rest.index(after: hash)...]
            let last = fragment.split(separator: "#").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if let last, !last.isEmpty, !last.hasPrefix("^") { heading = last }
            rest = rest[..<hash]
        }
        if let caret = rest.firstIndex(of: "^") { rest = rest[..<caret] }
        path = rest.trimmingCharacters(in: .whitespaces)
        self.heading = heading
    }

    /// File names tried for the path, best first.
    var candidateNames: [String] {
        guard !path.isEmpty else { return [] }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return [path] }
        let notes = [path + ".md", path + ".markdown"]
        return ext.isEmpty ? notes : [path] + notes
    }
}

/// Finds wiki-link targets on disk. Thread-safe; call `resolve` off the main
/// thread, since it may list folders.
nonisolated final class MarkdownWikiLinkResolver: WikiLinkResolver, @unchecked Sendable {
    static let shared = MarkdownWikiLinkResolver()

    /// Folders above the note's own that are searched without a vault marker.
    static let maxLevelsUp = 3
    /// Files listed per resolve, across all levels.
    static let maxEntries = 20_000
    private static let cacheLifetime: TimeInterval = 30

    private let lock = NSLock()
    private var listings: [String: (date: Date, files: [String])] = [:]

    /// Every wiki-link draws as a link. A note's editor uses
    /// `MarkdownWikiLinkPresence` instead, which dims links to missing files.
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        WikiLinkResolution(id: displayName, exists: true)
    }

    enum Outcome: Equatable {
        case found(URL)
        case notFound
        /// The sandbox would not list a folder the search needed (the note's,
        /// or a parent's), so the target may be there unseen.
        case noAccess
    }

    /// The file `link` points at from a note in `folder`.
    func resolve(_ link: MarkdownWikiLink, from folder: URL) -> Outcome {
        let names = link.candidateNames
        guard !names.isEmpty else { return .notFound }
        let fm = FileManager.default
        let folder = folder.standardizedFileURL
        for name in names {
            let exact = URL(fileURLWithPath: name, relativeTo: folder).standardizedFileURL
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: exact.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return .found(Self.onDiskSpelling(of: exact))
            }
        }
        guard (try? fm.contentsOfDirectory(atPath: folder.path)) != nil else { return .noAccess }
        let wanted = names.map { Self.normalized($0) }
        var budget = Self.maxEntries
        var searched: URL?
        var unreadable = false
        for directory in searchFolders(from: folder) {
            let listed = listing(of: directory, skipping: searched, budget: &budget)
            searched = directory
            unreadable = unreadable || listed.unreadable
            let matches = listed.files.compactMap { file -> (rank: Int, depth: Int, path: String)? in
                let key = Self.normalized(file)
                guard let rank = wanted.firstIndex(where: { key == $0 || key.hasSuffix("/" + $0) }) else { return nil }
                return (rank, file.split(separator: "/").count, file)
            }
            if let best = matches.min(by: { ($0.depth, $0.rank, $0.path) < ($1.depth, $1.rank, $1.path) }) {
                return .found(directory.appendingPathComponent(best.path).standardizedFileURL)
            }
            if budget <= 0 { break }
        }
        return unreadable ? .noAccess : .notFound
    }

    /// The note's folder, then each parent up to the vault root: the nearest
    /// folder holding `.obsidian`, else `maxLevelsUp` levels, never the home
    /// folder or above.
    func searchFolders(from folder: URL) -> [URL] {
        var chain = [folder]
        while let last = chain.last {
            if FileManager.default.fileExists(atPath: last.appendingPathComponent(".obsidian").path) { break }
            let parent = last.deletingLastPathComponent()
            guard chain.count <= Self.maxLevelsUp, parent.path != last.path, !Self.isTooHigh(parent) else { break }
            chain.append(parent)
        }
        return chain
    }

    /// The vault `folder` is in: the nearest folder of the search holding `.obsidian`.
    func vaultRoot(above folder: URL) -> URL? {
        searchFolders(from: folder.standardizedFileURL).last.flatMap { last in
            FileManager.default.fileExists(atPath: last.appendingPathComponent(".obsidian").path) ? last : nil
        }
    }

    private struct Listing {
        var files: [String] = []
        /// The folder, or a folder under it, could not be read.
        var unreadable = false
        /// The entry budget ran out before the folder was fully listed.
        var truncated = false
    }

    /// Records enumeration errors from FileManager's callback.
    private final class ErrorFlag { var raised = false }

    /// Files under `directory` (relative paths), leaving out the subtree
    /// already searched. Complete listings are cached briefly, so repeated
    /// clicks don't relist; a failed or truncated one is not, so the next
    /// click after access is granted (or files change) looks again.
    private func listing(of directory: URL, skipping searched: URL?, budget: inout Int) -> Listing {
        let key = directory.path + "\u{0}" + (searched?.path ?? "")
        lock.lock()
        if let cached = listings[key], Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            lock.unlock()
            budget -= cached.files.count
            return Listing(files: cached.files)
        }
        lock.unlock()
        var listing = Listing()
        let base = directory.standardizedFileURL.path
        let skipped = searched?.standardizedFileURL.path
        let error = ErrorFlag()
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == nil {
            listing.unreadable = true
        } else if let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in error.raised = true; return true }
        ) {
            for case let url as URL in enumerator {
                guard budget > 0 else { listing.truncated = true; break }
                budget -= 1
                let path = url.standardizedFileURL.path
                if path == skipped { enumerator.skipDescendants(); continue }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                guard path.hasPrefix(base + "/") else { continue }
                listing.files.append(String(path.dropFirst(base.count + 1)))
            }
        } else {
            listing.unreadable = true
        }
        listing.unreadable = listing.unreadable || error.raised
        guard !listing.unreadable, !listing.truncated else { return listing }
        lock.lock()
        listings[key] = (Date(), listing.files)
        lock.unlock()
        return listing
    }

    /// A case-insensitive volume finds `note.md` for `Note.md`; the tab should
    /// carry the name as it is on disk.
    private static func onDiskSpelling(of file: URL) -> URL {
        let folder = file.deletingLastPathComponent()
        let name = file.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path), !names.contains(name),
              let real = names.first(where: { normalized($0) == normalized(name) }) else { return file }
        return folder.appendingPathComponent(real)
    }

    private static func normalized(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The home folder, `/Users`, `/` and the like hold too much to walk.
    private static func isTooHigh(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        if path == realHomeFolder { return true }
        return folder.standardizedFileURL.pathComponents.count < 3
    }

    private static let realHomeFolder: String = {
        if let home = getpwuid(getuid())?.pointee.pw_dir { return String(cString: home) }
        return NSHomeDirectory()
    }()
}

/// What to ask for when the sandbox hides folders a wiki-link search needs:
/// the vault root when the note is in one (the folder holding `.obsidian`),
/// else the note folder's parent, so links to sibling folders resolve too.
/// The panel opens at the note folder's parent either way.
nonisolated struct WikiLinkAccessRequest: Equatable {
    /// The folder a grant has to cover.
    let folder: URL
    /// Where the open panel starts.
    let start: URL
    let message: String

    init(noteFolder: URL, vaultRoot: URL?) {
        let noteFolder = noteFolder.standardizedFileURL
        let parent = noteFolder.deletingLastPathComponent()
        start = parent
        if let vaultRoot {
            folder = vaultRoot.standardizedFileURL
            message = "Choose your vault folder, “\(vaultRoot.lastPathComponent)” (the folder that contains .obsidian), "
                + "so PageFlow can open the notes this note links to."
        } else {
            folder = parent
            message = "Allow PageFlow to open the notes this note links to: choose the folder that holds them."
        }
    }
}
