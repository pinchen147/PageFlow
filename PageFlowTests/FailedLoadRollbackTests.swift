//
//  FailedLoadRollbackTests.swift
//  PageFlowTests
//
//  Loading a document into a freshly created tab must roll the tab back on
//  failure — so reopening a since-deleted Recently-Closed file (or any bad
//  open) never strands a blank "New Tab" or steals focus from the active tab.
//

import Foundation
import Testing
@testable import PageFlow

@MainActor
struct FailedLoadRollbackTests {
    @Test
    func failedOpenIntoNewTabRemovesItAndRestoresThePreviousTab() throws {
        let manager = TabManager()
        let original = try #require(manager.activeTabID)
        let countBefore = manager.tabs.count

        // A path that cannot load (no such PDF) drives loadDocument → .failed.
        manager.createNewTab(with: URL(fileURLWithPath: "/tmp/pageflow-missing-\(UUID().uuidString).pdf"))

        #expect(manager.tabs.count == countBefore)   // stray tab removed
        #expect(manager.activeTabID == original)      // previous tab restored
    }
}
