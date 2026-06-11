//
//  TestEnvironment.swift
//  PageFlow
//
//  Detects the app-hosted test environment.
//

import Foundation

enum TestEnvironment {
    /// True when running inside a test host (XCTest/Swift Testing is loaded).
    /// Used to suppress UI that blocks the main actor under tests: the
    /// auto-open file panel (its modal behavior starves @MainActor tests and
    /// cascades the suite) and the quit-time save prompt (which turns finished
    /// test hosts into zombie processes).
    static let isRunningTests = NSClassFromString("XCTestCase") != nil
}
