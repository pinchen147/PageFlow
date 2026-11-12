//
//  AppDefaults.swift
//  PageFlow
//
//  The one way to the app's preferences.
//

import Foundation

nonisolated enum AppDefaults {
    /// The app's own defaults. The test host runs as PageFlow, so `.standard`
    /// there is the reader's real settings: it keeps its own store instead,
    /// empty at each launch. Named for the host so that test runs from other
    /// checkouts don't share it, and a later run reuses the file.
    static let store: UserDefaults = {
        guard TestEnvironment.isRunningTests else { return .standard }
        let suite = "pageflow.tests" + Bundle.main.bundlePath.replacingOccurrences(of: "/", with: ".")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()
}
