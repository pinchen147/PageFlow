//
//  PerfTrace.swift
//  MarkdownEngine
//
//  Phase timers for the editor's hot paths (a ⌘A format, a restyle, the
//  tokenizer, the inline parser). Off unless PAGEFLOW_PERF_TRACE is set, and
//  then each `time` call adds its wall-clock cost to a per-label total that
//  `dump` prints and clears. The QA harness and the perf tests read them; the
//  release path pays one static bool check per label.
//

import Foundation

/// Opt-in phase timers for the editor's hot paths (set `PAGEFLOW_PERF_TRACE`).
public enum PerfTrace {
    /// Whether tracing is on for this process.
    public static let enabled = ProcessInfo.processInfo.environment["PAGEFLOW_PERF_TRACE"] != nil
    /// Guards the totals and stamps: the background parse records off main.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var totals: [String: Double] = [:]

    /// Runs `body` and adds its wall-clock milliseconds to `label`'s total.
    @inline(__always)
    public static func time(_ label: String, _ body: () -> Void) {
        guard enabled else { body(); return }
        let start = CFAbsoluteTimeGetCurrent()
        body()
        add(label, since: start)
    }

    /// Adds the milliseconds elapsed since `start` to `label`'s total.
    public static func add(_ label: String, since start: CFAbsoluteTime) {
        guard enabled else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lock.withLock { totals[label, default: 0] += elapsed }
    }

    /// Wall-clock milestones (ms since the first stamp), printed with the
    /// next dump: where an open spends time outside the timed sections.
    nonisolated(unsafe) private static var stamps: [(String, CFAbsoluteTime)] = []

    /// Records a wall-clock milestone named `label`.
    public static func stamp(_ label: String) {
        guard enabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLock { stamps.append((label, now)) }
    }

    /// Prints the milestones and every label's accumulated milliseconds, largest
    /// first, to standard error, then resets both.
    public static func dump(_ prefix: String) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        if let first = stamps.first {
            let line = stamps.map { String(format: "%@=%.0f", $0.0, ($0.1 - first.1) * 1000) }.joined(separator: " ")
            FileHandle.standardError.write(Data("PERF-STAMPS \(prefix): \(line)\n".utf8))
            stamps = []
        }
        let line = totals.sorted { $0.value > $1.value }
            .map { String(format: "%@=%.1f", $0.key, $0.value) }
            .joined(separator: " ")
        FileHandle.standardError.write(Data("PERF \(prefix): \(line)\n".utf8))
        totals = [:]
    }
}
