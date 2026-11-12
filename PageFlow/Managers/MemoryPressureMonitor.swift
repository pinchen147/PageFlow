//
//  MemoryPressureMonitor.swift
//  PageFlow
//
//  When macOS reports memory pressure, hidden tabs and shared caches give back
//  what can be rebuilt. The tab being read keeps its view, document and place.
//  It shares the thumbnail, math and diagram caches, which empty too: what it
//  already shows stays on screen, and what it draws next renders again.
//

import AppKit
import Darwin
import Dispatch

@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private var source: DispatchSourceMemoryPressure?

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { MemoryPressureMonitor.releaseMemory() } }
        source.resume()
        self.source = source
    }

    static func releaseMemory() {
        WindowRegistry.shared.releaseHiddenTabsUnderPressure()
        ThumbnailImageCache.shared.removeAll()
        MarkdownEditorView.releaseRenderCaches()
        malloc_zone_pressure_relief(nil, 0)
    }
}
