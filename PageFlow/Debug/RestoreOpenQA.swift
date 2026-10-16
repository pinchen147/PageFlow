// DEBUG-only cold-launch restore probe. Requires a disposable app identity.
#if DEBUG
import AppKit

@MainActor
enum RestoreOpenQA {
    private struct WindowState: Codable, Equatable {
        let number: Int
        let visible: Bool
        let tabIDs: [String]
        let paths: [String]
    }

    private struct Report: Encodable {
        let runID: String
        let bundleID: String
        let scenario: String
        let status: String
        let exitStatus: Int32
        let qualified: Bool
        let passed: Bool
        let preconditions: [String: Bool]
        let checks: [String: Bool]
        let windows: [WindowState]
        let visibleNativeWindowNumbers: [Int]
        let observationMilliseconds: Double
        let errors: [String]
    }

    /// Seeds only a uniquely identified disposable process, immediately before
    /// the ordinary launch restore reads its persisted session.
    static func prepareIfRequested(delegate: AppDelegate) {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["PAGEFLOW_QA_RESTORE_OPEN"] else { return }
        guard let runID = env["PAGEFLOW_QA_RUN_ID"], !runID.isEmpty,
              Bundle.main.bundleIdentifier == "com.raccoontechnologies.PageFlow.RestoreQA." + runID,
              let output = env["PAGEFLOW_QA_OUTPUT_DIR"], output.hasPrefix("/"),
              ["duplicate", "distinct", "finder"].contains(scenario),
              !TestEnvironment.isRunningTests, !QAReplay.isRequested,
              !WindowCloseQA.isRequested, !OpenDocumentQA.isRequested else {
            finish(scenario: scenario, preconditions: [:], checks: [:], elapsed: 0,
                   errors: ["A fresh RestoreQA.<runID> clone, absolute output directory, and one valid scenario are required"])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pageflow-restore-qa-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let shared = directory.appendingPathComponent("shared.md")
            let distinct = directory.appendingPathComponent("distinct.md")
            let sources = [shared: "# Shared restore\n\nExact e\u{301} 😀\t  \n",
                           distinct: "# Distinct control\n\nIndependent é 🐾\t  \n"]
            for (url, source) in sources { try Data(source.utf8).write(to: url, options: .atomic) }
            let sharedTab = RestoreTab(path: shared.pageFlowCanonicalDocumentURL.path, bookmark: nil)
            let distinctTab = RestoreTab(path: distinct.pageFlowCanonicalDocumentURL.path, bookmark: nil)
            let state = SessionRestoreState(windows: [
                WindowSessionState(tabs: [sharedTab], activeIndex: 0),
                WindowSessionState(tabs: scenario == "distinct" ? [distinctTab] : [sharedTab, distinctTab], activeIndex: 0),
            ])
            var preconditions = [
                "scratchSourcesWritten": sources.allSatisfy { (try? Data(contentsOf: $0.key)) == Data($0.value.utf8) },
                "emptyPersistedSession": SessionRestoreStore.shared.load().isEmpty,
                "noPendingRestoreBeforeSeed": delegate.pendingRestoreWindows.isEmpty,
                "noPendingURLsBeforeSeed": delegate.pendingURLs.isEmpty,
                "isolatedBundle": true,
            ]
            guard preconditions.values.allSatisfy({ $0 }) else {
                finish(scenario: scenario, preconditions: preconditions, checks: [:], elapsed: 0,
                       errors: ["Disposable launch was not fresh"])
            }
            SessionRestoreStore.shared.save(state)
            preconditions["persistedTwoWindowsExactly"] = SessionRestoreStore.shared.load() == state
            if scenario == "finder" {
                preconditions["finderBeforeAnyRegistration"] = WindowRegistry.shared.allOpenTabs().isEmpty
                guard preconditions["finderBeforeAnyRegistration"] == true else {
                    finish(scenario: scenario, preconditions: preconditions, checks: [:], elapsed: 0,
                           errors: ["Launch hook occurred after a manager registered; pending-Finder scenario is unqualified"])
                }
                delegate.application(NSApp, open: [shared])
                preconditions["realDelegateQueuedFinderURL"] = delegate.pendingURLs == [shared.pageFlowCanonicalDocumentURL]
            }
            let frozenPreconditions = preconditions
            Task { await observe(delegate: delegate, scenario: scenario, sources: sources,
                                 directory: directory, preconditions: frozenPreconditions) }
        } catch {
            finish(scenario: scenario, preconditions: [:], checks: [:], elapsed: 0,
                   errors: ["Scratch setup failed: \(error)"])
        }
    }

    private static func observe(delegate: AppDelegate, scenario: String, sources: [URL: String],
                                directory: URL, preconditions: [String: Bool]) async {
        NSApp.activate(ignoringOtherApps: true)
        let started = Date()
        var last = snapshot()
        var stableSince = Date()
        // Observe beyond both the automatic-picker and placeholder-dismissal
        // delays. Waiting never registers a manager or suppresses either path.
        while Date().timeIntervalSince(started) < 8 {
            try? await Task.sleep(for: .milliseconds(50))
            let current = snapshot()
            if current != last { last = current; stableSince = Date() }
            if Date().timeIntervalSince(started) >= 1.5,
               Date().timeIntervalSince(stableSince) >= 0.5,
               delegate.windowContentBuilder != nil, delegate.pendingRestoreWindows.isEmpty,
               !current.isEmpty { break }
        }
        let groups = WindowRegistry.shared.allOpenTabs()
        let visible = groups.filter { $0.window.isVisible }
        let sessions = groups.flatMap { $0.tabManager.sessions.values }
        let canonicalSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.pageFlowCanonicalDocumentURL, $0.value) })
        let checks: [String: Bool] = [
            "restoreBufferDrained": delegate.pendingRestoreWindows.isEmpty,
            "pendingFinderURLsDrained": delegate.pendingURLs.isEmpty,
            "stableWindowSet": Date().timeIntervalSince(stableSince) >= 0.5,
            "twoDistinctDocumentWindows": visible.count == 2 && visible.allSatisfy { $0.tabs.count == 1 },
            "oneSessionPerCanonicalDocument": canonicalSources.keys.allSatisfy { url in
                sessions.filter { $0.content.markdown?.documentManager.documentURL?.pageFlowCanonicalDocumentURL == url }.count == 1
            },
            "exactDocumentSource": sessions.count == 2 && sessions.allSatisfy { session in
                guard let manager = session.content.markdown?.documentManager,
                      let url = manager.documentURL?.pageFlowCanonicalDocumentURL,
                      let expected = canonicalSources[url] else { return false }
                return manager.text.utf16.elementsEqual(expected.utf16)
            },
            "noEmptyPlaceholder": !visible.contains { $0.tabManager.hasOnlyPlaceholderTab || $0.tabs.isEmpty },
            "noUnregisteredVisibleDocumentWindow": nativeWindows().count == visible.count,
            "noOpenPanel": !NSApp.windows.contains { ($0 is NSOpenPanel && $0.isVisible) || $0.attachedSheet is NSOpenPanel },
            "diskUnchanged": sources.allSatisfy { (try? Data(contentsOf: $0.key)) == Data($0.value.utf8) },
        ]
        try? FileManager.default.removeItem(at: directory)
        finish(scenario: scenario, preconditions: preconditions, checks: checks,
               elapsed: Date().timeIntervalSince(started) * 1000, errors: [])
    }

    private static func snapshot() -> [WindowState] {
        WindowRegistry.shared.allOpenTabs().map { group in
            WindowState(number: group.window.windowNumber, visible: group.window.isVisible,
                        tabIDs: group.tabs.map { $0.id.uuidString },
                        paths: group.tabs.compactMap { $0.documentURL?.pageFlowCanonicalDocumentURL.path })
        }.sorted { $0.number < $1.number }
    }

    private static func nativeWindows() -> [Int] {
        NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
            .map(\.windowNumber).sorted()
    }

    private static func finish(scenario: String, preconditions: [String: Bool], checks: [String: Bool],
                               elapsed: Double, errors: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let qualified = !preconditions.isEmpty && preconditions.values.allSatisfy { $0 } && errors.isEmpty
        let passed = qualified && !checks.isEmpty && checks.values.allSatisfy { $0 }
        let code: Int32 = passed ? 0 : (qualified ? 1 : 2)
        let report = Report(runID: env["PAGEFLOW_QA_RUN_ID"] ?? "missing",
                            bundleID: Bundle.main.bundleIdentifier ?? "missing", scenario: scenario,
                            status: passed ? "passed" : (qualified ? "failed" : "invalid"), exitStatus: code,
                            qualified: qualified, passed: passed, preconditions: preconditions, checks: checks,
                            windows: snapshot(), visibleNativeWindowNumbers: nativeWindows(),
                            observationMilliseconds: elapsed, errors: errors)
        guard let output = env["PAGEFLOW_QA_OUTPUT_DIR"], output.hasPrefix("/") else { exit(2) }
        do {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("restore-open.json"), options: .atomic)
            print("RESTORE OPEN QA \(report.status): \(directory.path)")
            fflush(stdout)
            exit(code)
        } catch {
            FileHandle.standardError.write(Data("RESTORE OPEN QA invalid: \(error)\n".utf8))
            exit(2)
        }
    }
}
#endif
