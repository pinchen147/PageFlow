//
//  AppDelegateInstallTests.swift
//  PageFlowTests
//
//  Tear-off, "Move to New Window", and cold-launch URL flushing all need the
//  real AppDelegate instance. On macOS 26 SwiftUI installs its own proxy as
//  `NSApp.delegate` (the cast `NSApp.delegate as? AppDelegate` returns nil),
//  so call sites must use `AppDelegate.shared`. These pin that contract.
//

import AppKit
import Testing
@testable import PageFlow

@MainActor
struct AppDelegateInstallTests {

    @Test
    func sharedAdaptorInstanceIsAvailable() {
        #expect(AppDelegate.shared != nil)
    }

    @Test
    func windowContentBuilderIsInstalled() {
        #expect(AppDelegate.shared?.windowContentBuilder != nil)
    }
}
