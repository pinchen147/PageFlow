//
//  ClosedTabStore.swift
//  PageFlow
//
//  An app-wide, in-memory ring buffer of recently closed document tabs, so the
//  Tab Switcher can offer a "Recently Closed" section (Chrome parity). Only tabs
//  backed by a document URL are recorded — a blank "New Tab" has nothing to
//  reopen. Not persisted: the history is cleared when the app quits.
//
//  Production uses the `shared` singleton; tests construct their own instance to
//  avoid leaking state across the suite.
//

import Foundation
import Observation

@Observable
@MainActor
final class ClosedTabStore {
    static let shared = ClosedTabStore()

    struct Record: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let isSecurityScoped: Bool
    }

    /// Most-recently-closed first, capped at `maxRecords`.
    private(set) var records: [Record] = []

    private let maxRecords = 25

    init() {}

    /// Archives a closing tab. No-op for a tab without a document (nothing to
    /// reopen). Re-closing the same document moves it to the front instead of
    /// duplicating it.
    func record(_ tab: TabModel) {
        guard let url = tab.documentURL else { return }
        let canonical = url.pageFlowCanonicalDocumentURL

        records.removeAll { $0.url.pageFlowCanonicalDocumentURL == canonical }
        records.insert(
            Record(url: url, title: tab.displayTitle, isSecurityScoped: tab.isSecurityScoped),
            at: 0
        )
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
    }

    /// Drops a record once it has been reopened.
    func remove(_ record: Record) {
        records.removeAll { $0.id == record.id }
    }
}
