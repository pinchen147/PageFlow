//
//  ClosedTabStoreTests.swift
//  PageFlowTests
//
//  The Recently-Closed ring buffer behind the Tab Switcher: most-recent-first,
//  de-duplicated, capped, and skipping tabs that have nothing to reopen.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct ClosedTabStoreTests {
    private func tab(_ path: String) -> TabModel {
        TabModel(documentURL: URL(fileURLWithPath: path))
    }

    @Test
    func recordsMostRecentFirstAndSkipsUntitledTabs() {
        let store = ClosedTabStore()
        store.record(tab("/tmp/a.pdf"))
        store.record(tab("/tmp/b.pdf"))
        store.record(TabModel())  // no document → nothing to reopen → skipped

        #expect(store.records.count == 2)
        #expect(store.records.first?.url.lastPathComponent == "b.pdf")
        #expect(store.records.last?.url.lastPathComponent == "a.pdf")
    }

    @Test
    func reClosingTheSameDocumentMovesItToFrontWithoutDuplicating() {
        let store = ClosedTabStore()
        store.record(tab("/tmp/a.pdf"))
        store.record(tab("/tmp/b.pdf"))
        store.record(tab("/tmp/a.pdf"))

        #expect(store.records.count == 2)
        #expect(store.records.first?.url.lastPathComponent == "a.pdf")
        #expect(store.records.last?.url.lastPathComponent == "b.pdf")
    }

    @Test
    func capsAtTwentyFiveKeepingTheNewest() {
        let store = ClosedTabStore()
        for index in 0..<30 {
            store.record(tab("/tmp/\(index).pdf"))
        }

        #expect(store.records.count == 25)
        #expect(store.records.first?.url.lastPathComponent == "29.pdf")
        #expect(!store.records.contains { $0.url.lastPathComponent == "0.pdf" })
    }

    @Test
    func removeDropsTheRecord() throws {
        let store = ClosedTabStore()
        store.record(tab("/tmp/a.pdf"))
        let record = try #require(store.records.first)

        store.remove(record)

        #expect(store.records.isEmpty)
    }
}
