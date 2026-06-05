//
//  DocumentStateStore.swift
//  PageFlow
//
//  App-wide persistence of per-document reading state (last page, scroll, zoom),
//  keyed by canonical file path — the same identity `BookmarkManager` uses, so a
//  moved/renamed file is treated as a new document and stale state is discarded.
//
//  Mirrors the `SettingsManager` idiom: a single JSON-encoded value in
//  UserDefaults, loaded once at init and rewritten on each change. Capped and
//  LRU-pruned so reading history can't grow without bound.
//

import Foundation
import os.log

@MainActor
final class DocumentStateStore {
    static let shared = DocumentStateStore()

    /// Maximum number of remembered documents; least-recently-updated are pruned.
    private static let capacity = 500
    private static let storageKey = "documentViewStates.v1"

    private struct Entry: Codable {
        var state: DocumentViewState
        var updatedAt: Date
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.pageflow", category: "DocumentStateStore")
    private var entries: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = [:]

        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                entries = try JSONDecoder().decode([String: Entry].self, from: data)
            } catch {
                logger.error("Failed to decode document view states: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Access

    /// Saved reading state for `url`, or `nil` if none is recorded.
    func state(for url: URL) -> DocumentViewState? {
        guard let key = Self.key(for: url) else { return nil }
        return entries[key]?.state
    }

    /// Records `state` for `url`, pruning the oldest entries past capacity.
    func save(_ state: DocumentViewState, for url: URL) {
        guard let key = Self.key(for: url) else { return }
        entries[key] = Entry(state: state, updatedAt: Date())
        pruneIfNeeded()
        persist()
    }

    // MARK: - Identity

    private static func key(for url: URL) -> String? {
        let path = url.pageFlowCanonicalDocumentURL.path
        return path.isEmpty ? nil : path
    }

    // MARK: - Persistence

    private func pruneIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let survivors = entries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.capacity)
        entries = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(entries)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            logger.error("Failed to encode document view states: \(error.localizedDescription)")
        }
    }
}
