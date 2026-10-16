//
//  DocumentStateStore.swift
//  PageFlow
//
//  App-wide persistence of per-document reading state (last page, scroll, zoom,
//  Markdown reading position), keyed by canonical file path — the same identity
//  `BookmarkManager` uses, so a moved/renamed file is treated as a new document
//  and stale state is discarded.
//
//  Mirrors the `SettingsManager` idiom: a single JSON value in UserDefaults,
//  loaded once at init and rewritten on each change. Capped and LRU-pruned so
//  reading history can't grow without bound.
//
//  Schema v2: each record is kept as the JSON object it was stored as. A save
//  replaces the keys this build knows (`DocumentViewState.knownKeys`) and keeps
//  every other key verbatim, so a newer build's fields survive a round trip
//  through an older one. The v1 blob (same record shape, typed re-encode that
//  dropped unknown keys) is read once when no v2 blob exists.
//

import Foundation
import os.log

@MainActor
final class DocumentStateStore {
    static let shared = DocumentStateStore()

    /// Maximum number of remembered documents; least-recently-updated are pruned.
    private static let capacity = 500
    static let storageKey = "documentViewStates.v2"
    static let legacyStorageKey = "documentViewStates.v1"

    /// One remembered document: the state this build understands, decoded from
    /// the record's JSON object, plus that object itself for the merge on save.
    private struct Record {
        var state: DocumentViewState
        var updatedAt: Date
        var stateObject: [String: Any]
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.pageflow", category: "DocumentStateStore")
    private var records: [String: Record] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) ?? defaults.data(forKey: Self.legacyStorageKey) {
            records = decodeRecords(data)
        }
    }

    // MARK: - Access

    /// Saved reading state for `url`, or `nil` if none is recorded.
    func state(for url: URL) -> DocumentViewState? {
        guard let key = Self.key(for: url) else { return nil }
        return records[key]?.state
    }

    /// Records `state` for `url`, pruning the oldest entries past capacity.
    func save(_ state: DocumentViewState, for url: URL) {
        guard let key = Self.key(for: url), let object = Self.jsonObject(of: state) else { return }
        // The keys this build writes are replaced wholesale (a field now nil is
        // gone); keys it does not know stay exactly as stored.
        var merged = records[key]?.stateObject.filter { !DocumentViewState.knownKeys.contains($0.key) } ?? [:]
        merged.merge(object) { _, new in new }
        records[key] = Record(state: state, updatedAt: Date(), stateObject: merged)
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
        guard records.count > Self.capacity else { return }
        let survivors = records
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.capacity)
        records = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    private func persist() {
        let raw = records.mapValues { record -> [String: Any] in
            ["state": record.stateObject, "updatedAt": record.updatedAt.timeIntervalSinceReferenceDate]
        }
        do {
            defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: Self.storageKey)
        } catch {
            logger.error("Failed to encode document view states: \(error.localizedDescription)")
        }
    }

    private func decodeRecords(_ data: Data) -> [String: Record] {
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            logger.error("Failed to decode document view states")
            return [:]
        }
        var decoded: [String: Record] = [:]
        for (key, record) in raw {
            guard let stateObject = record["state"] as? [String: Any],
                  let state = Self.state(from: stateObject) else { continue }
            let updatedAt = (record["updatedAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
            decoded[key] = Record(state: state, updatedAt: updatedAt, stateObject: stateObject)
        }
        return decoded
    }

    private static func state(from object: [String: Any]) -> DocumentViewState? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(DocumentViewState.self, from: data)
    }

    private static func jsonObject(of state: DocumentViewState) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
