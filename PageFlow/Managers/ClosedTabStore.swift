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

        /// The file is no longer there. Only a real "no such file" counts: a
        /// sandbox refusal goes on to the open, which reports it as it does any
        /// other file it can't read.
        var fileIsGone: Bool {
            let isAccessing = isSecurityScoped && url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            do {
                return try !url.checkResourceIsReachable()
            } catch let error as NSError {
                return error.domain == NSCocoaErrorDomain
                    && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            }
        }
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
        record(url: url, title: tab.displayTitle, isSecurityScoped: tab.isSecurityScoped)
    }

    /// The same for a tab closed before its document arrived: a note still
    /// reading, or a PDF at its password prompt, has only the URL it was opening.
    func record(url: URL, title: String, isSecurityScoped: Bool) {
        let canonical = url.pageFlowCanonicalDocumentURL

        records.removeAll { $0.url.pageFlowCanonicalDocumentURL == canonical }
        records.insert(
            Record(url: url, title: title, isSecurityScoped: isSecurityScoped),
            at: 0
        )
        if records.count > maxRecords {
            records.removeLast(records.count - maxRecords)
        }
    }

    /// Drops a record that has nothing left to come back to.
    func remove(_ record: Record) {
        records.removeAll { $0.id == record.id }
    }

    /// `url` has settled: it opened, by whatever route, or it can't open. Until
    /// then an open can still be abandoned, so its record stays on the stack.
    func documentSettled(_ url: URL) {
        let canonical = url.pageFlowCanonicalDocumentURL
        records.removeAll { $0.url.pageFlowCanonicalDocumentURL == canonical }
    }
}
