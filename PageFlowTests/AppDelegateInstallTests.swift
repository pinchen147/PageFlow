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
import PDFKit
import SwiftUI
import Testing
@testable import PageFlow

@MainActor
@Suite(.serialized)
struct AppDelegateInstallTests {

    @Test
    func sharedAdaptorInstanceIsAvailable() {
        #expect(AppDelegate.shared != nil)
    }

    @Test
    func windowContentBuilderIsInstalled() {
        #expect(AppDelegate.shared?.windowContentBuilder != nil)
    }

    @Test("a PDF open without a scene creates one registered document window",
          arguments: [true, false])
    func fileLaunchWithoutInitialScene(queuedBeforeLaunch: Bool) throws {
        let delegate = try #require(AppDelegate.shared)
        let registry = WindowRegistry.shared
        let previousWindows = registry.allOpenTabs()
        for group in previousWindows { registry.unregister(group.tabManager) }
        let previousBuilder = delegate.windowContentBuilder
        var createdManagers: [TabManager] = []
        delegate.windowContentBuilder = { manager in
            manager.documentOpenedHandler = nil
            createdManagers.append(manager)
            return AnyView(Color.clear)
        }
        defer {
            for manager in createdManagers {
                if let window = registry.window(for: manager) {
                    // Avoid closing the test host's last visible window.
                    window.orderOut(nil)
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                    window.contentView = nil
                }
                registry.unregister(manager)
            }
            delegate.windowContentBuilder = previousBuilder
            registry.dismissTransientPlaceholderWindowForExternalOpen(within: 0)
            for group in previousWindows { registry.register(group.tabManager, window: group.window) }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("launch.pdf").pageFlowCanonicalDocumentURL
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        try #require(document.write(to: url))

        let launch = Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApp)
        if queuedBeforeLaunch {
            delegate.enqueuePendingURLs([url])
            #expect(createdManagers.isEmpty)
            delegate.applicationDidFinishLaunching(launch)
        } else {
            delegate.applicationDidFinishLaunching(launch)
            #expect(createdManagers.isEmpty, "a plain launch must leave the default scene to SwiftUI")
            delegate.application(NSApp, open: [url])
        }

        let manager = try #require(createdManagers.first)
        let window = try #require(registry.window(for: manager))
        #expect(window.isVisible)
        #expect(manager.activePDFManager?.hasDocument == true)
        #expect(manager.activePDFManager?.documentURL?.pageFlowCanonicalDocumentURL == url)
        #expect(delegate.pendingURLs.isEmpty)
        delegate.application(NSApp, open: [url, url])
        #expect(createdManagers.count == 1)
        #expect(manager.tabCount == 1)
        #expect(registry.allOpenTabs().count == 1)
    }
}
