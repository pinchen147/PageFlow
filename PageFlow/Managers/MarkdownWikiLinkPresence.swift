//
//  MarkdownWikiLinkPresence.swift
//  PageFlow
//
//  Whether each `[[wiki-link]]` in one note points at a file, so the editor
//  can draw links to missing notes dimmed. Styling asks synchronously on the
//  main thread; the answer comes from a cache, and links not yet known (or
//  known too long ago) are looked up on a background queue. A changed answer
//  bumps the fingerprint and calls `onChange`, which makes the editor restyle.
//

import Foundation
import MarkdownEngine

nonisolated final class MarkdownWikiLinkPresence: WikiLinkResolver, @unchecked Sendable {
    typealias LookUp = @Sendable (MarkdownWikiLink, URL) -> MarkdownWikiLinkResolver.Outcome

    /// How long an answer is trusted before the next restyle checks again.
    static let lifetime: TimeInterval = 30

    private let noteFolder: @Sendable () -> URL?
    private let lookUp: LookUp
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "PageFlow.MarkdownWikiLinkPresence", qos: .utility)

    private struct Key: Hashable {
        let folder: String
        let path: String
    }

    private let lock = NSLock()
    private var missing: [Key: (isMissing: Bool, checked: Date)] = [:]
    private var pending: Set<Key> = []
    private var revision = 0
    private var notifyScheduled = false

    /// - Parameters:
    ///   - noteFolder: The folder of the note the links are in; nil while unsaved.
    ///   - lookUp: Finds a link's target; runs on a background queue.
    ///   - onChange: Called on the main queue after answers changed.
    init(noteFolder: @escaping @Sendable () -> URL?,
         lookUp: @escaping LookUp = MarkdownWikiLinkPresence.lookUpWithoutPrompting,
         onChange: @escaping @Sendable () -> Void) {
        self.noteFolder = noteFolder
        self.lookUp = lookUp
        self.onChange = onChange
    }

    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
        WikiLinkResolution(id: displayName, exists: !isKnownMissing(displayName))
    }

    func fingerprint() -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    /// Whether `target` (the text before any `|alias`) is known to name no
    /// file. Unknown links count as present until their lookup says otherwise.
    func isKnownMissing(_ target: String) -> Bool {
        let link = MarkdownWikiLink(target)
        guard !link.path.isEmpty, let folder = noteFolder()?.standardizedFileURL else { return false }
        let key = Key(folder: folder.path, path: link.path.precomposedStringWithCanonicalMapping.lowercased())
        lock.lock()
        let entry = missing[key]
        let due = (entry.map { Date().timeIntervalSince($0.checked) >= Self.lifetime } ?? true) && !pending.contains(key)
        if due { pending.insert(key) }
        lock.unlock()
        if due { queue.async { self.check(link, key: key, folder: folder) } }
        return entry?.isMissing ?? false
    }

    private func check(_ link: MarkdownWikiLink, key: Key, folder: URL) {
        // A folder the sandbox hides stays a link: a click asks for access.
        let isMissing = lookUp(link, folder) == .notFound
        lock.lock()
        pending.remove(key)
        let changed = (missing[key]?.isMissing ?? false) != isMissing
        missing[key] = (isMissing, Date())
        let notify = changed && !notifyScheduled
        if changed { revision &+= 1 }
        if notify { notifyScheduled = true }
        lock.unlock()
        // After the lookups already queued, so a burst restyles once.
        guard notify else { return }
        queue.async {
            self.lock.lock()
            self.notifyScheduled = false
            self.lock.unlock()
            DispatchQueue.main.async { self.onChange() }
        }
    }

    /// The resolver's search through the folders the user already allowed;
    /// never shows the access panel (a click does that).
    static let lookUpWithoutPrompting: LookUp = { link, folder in
        let access = FolderAccessStore.shared, resolver = MarkdownWikiLinkResolver.shared
        return access.withAccess(to: folder) {
            let request = WikiLinkAccessRequest(noteFolder: folder, vaultRoot: resolver.vaultRoot(above: folder))
            return access.withAccess(to: request.folder) { resolver.resolve(link, from: folder) }
        }
    }
}
