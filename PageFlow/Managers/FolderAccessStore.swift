//
//  FolderAccessStore.swift
//  PageFlow
//
//  The sandbox grants this app a note file the user opened, not the folder
//  around it. Saving a pasted image beside a note, or reading an image the
//  note references beside itself, needs that folder: the user allows it once
//  through an open panel pointed at the folder, and the app-scoped bookmark
//  minted then is kept for later launches.
//

import AppKit
import Foundation

final class FolderAccessStore: @unchecked Sendable {
    static let shared = FolderAccessStore()

    private static let storageKey = "folderAccessBookmarks.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Folder path → app-scoped security bookmark.
    private var bookmarks: [String: Data]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = defaults.dictionary(forKey: Self.storageKey) as? [String: Data] ?? [:]
    }

    /// Runs `body` with access to `url`'s folder (or the nearest allowed
    /// ancestor) opened, when a grant is stored; runs it as is otherwise —
    /// the file may be one the sandbox already lets through.
    func withAccess<T>(to url: URL, _ body: () -> T) -> T {
        guard let (_, bookmark) = grant(covering: url) else { return body() }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return body() }
        let opened = folder.startAccessingSecurityScopedResource()
        defer { if opened { folder.stopAccessingSecurityScopedResource() } }
        if stale { remember(folder) }
        return body()
    }

    /// Whether a stored grant covers `url`.
    func hasAccess(to url: URL) -> Bool { grant(covering: url) != nil }

    /// Asks the user to allow `folder` through an open panel pointed at it
    /// (they confirm with Allow). Returns whether a grant is now stored.
    /// Never shown in the test host.
    @MainActor
    func requestAccess(to folder: URL, message: String) -> Bool {
        if hasAccess(to: folder) { return true }
        guard !TestEnvironment.isRunningTests else { return false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.message = message
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        remember(chosen)
        return grant(covering: folder) != nil
    }

    private func grant(covering url: URL) -> (path: String, bookmark: Data)? {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return bookmarks
            .filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
    }

    private func remember(_ folder: URL) {
        guard let bookmark = try? folder.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        lock.lock(); defer { lock.unlock() }
        bookmarks[folder.standardizedFileURL.path] = bookmark
        defaults.set(bookmarks, forKey: Self.storageKey)
    }
}
