// DEBUG-only external-open probe. Run an isolated app with
// PAGEFLOW_QA_OPEN_DOCUMENT=1; scratch files only, no user clipboard or drafts.
#if DEBUG
import AppKit

@MainActor
enum OpenDocumentQA {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PAGEFLOW_QA_OPEN_DOCUMENT"] != nil }

    static func startIfRequested() {
        guard isRequested else { return }
        Task { await run() }
    }

    private struct WindowState: Codable {
        let number: Int
        let visible: Bool
        let key: Bool
        let sheetClass: String?
        let tabIDs: [String]
        let paths: [String]
    }

    private struct CaseReport: Encodable {
        let route: String
        var preconditions: [String: Bool] = [:]
        var checks: [String: Bool] = [:]
        var before: [WindowState] = []
        var after: [WindowState] = []
        var panelEvents: [String] = []
        var observedMountToOpenMilliseconds: Double = 0
        var observationMilliseconds: Double = 0
        var qualified: Bool { !preconditions.isEmpty && preconditions.values.allSatisfy { $0 } }
        var passed: Bool { qualified && !checks.isEmpty && checks.values.allSatisfy { $0 } }

        private enum CodingKeys: String, CodingKey {
            case route, preconditions, checks, before, after, panelEvents
            case observedMountToOpenMilliseconds, observationMilliseconds, qualified, passed
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(route, forKey: .route)
            try values.encode(preconditions, forKey: .preconditions)
            try values.encode(checks, forKey: .checks)
            try values.encode(before, forKey: .before)
            try values.encode(after, forKey: .after)
            try values.encode(panelEvents, forKey: .panelEvents)
            try values.encode(observedMountToOpenMilliseconds, forKey: .observedMountToOpenMilliseconds)
            try values.encode(observationMilliseconds, forKey: .observationMilliseconds)
            try values.encode(qualified, forKey: .qualified)
            try values.encode(passed, forKey: .passed)
        }
    }

    private struct Report: Encodable {
        let runID: String
        let bundleID: String
        let executable: String
        let processID: Int32
        let status: String
        let exitStatus: Int32
        let cases: [CaseReport]
        let errors: [String]
    }

    @MainActor
    private final class PanelWatcher {
        var events: [String] = []
        private var seen = Set<Int>()
        private var timer: Timer?
        private let started = Date()

        func start() {
            let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }

        func poll() {
            for panel in NSApp.windows.compactMap({ $0 as? NSOpenPanel }) where panel.isVisible {
                guard seen.insert(panel.windowNumber).inserted else { continue }
                let parent = panel.sheetParent?.windowNumber.description ?? "none"
                events.append("NSOpenPanel window=\(panel.windowNumber) parent=\(parent) elapsedMs=\(Date().timeIntervalSince(started) * 1000)")
                panel.cancel(nil)
            }
        }

        func stop() { poll(); timer?.invalidate(); timer = nil }
    }

    private static func run() async {
        guard !TestEnvironment.isRunningTests, !QAReplay.isRequested, !WindowCloseQA.isRequested,
              let delegate = AppDelegate.shared else { finish([], errors: ["Standalone OpenDocumentQA required"]) }
        NSApp.activate(ignoringOtherApps: true)
        guard let initial = await initialWindow() else { finish([], errors: ["Initial WindowGroup placeholder did not register"]) }
        let mountObserved = Date()
        guard initial.tabManager.hasOnlyPlaceholderTab, initial.window.attachedSheet == nil,
              delegate.pendingURLs.isEmpty, delegate.pendingRestoreWindows.isEmpty else {
            finish([], errors: ["Initial state is not an empty, picker-free isolated launch"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pageflow-open-qa-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sentinelManager = TabManager(createInitialTab: false)
            guard let sentinel = delegate.createNewWindow(with: sentinelManager),
                  await registered(sentinel, owner: sentinelManager) else { finish([], errors: ["Sentinel did not register"]) }
            var cases = [await probe("initial-window-group", owner: initial.tabManager, window: initial.window,
                                     mountObserved: mountObserved, duplicateBatch: false, directory: directory, delegate: delegate)]
            initial.tabManager.closeFilePicker()
            guard await closeScratchWindow(initial.window, owner: initial.tabManager) else {
                finish(cases, errors: ["Initial scratch window did not dismiss its panel and actually close/unregister"])
            }
            let owner = TabManager()
            guard let window = delegate.createNewWindow(with: owner), await registered(window, owner: owner) else {
                finish(cases, errors: ["Hosted placeholder did not register"])
            }
            cases.append(await probe("app-created-hosted-window-duplicate-batch", owner: owner, window: window,
                                     mountObserved: Date(), duplicateBatch: true, directory: directory, delegate: delegate))
            owner.closeFilePicker()
            try? FileManager.default.removeItem(at: directory)
            finish(cases, errors: [])
        } catch { finish([], errors: [String(describing: error)]) }
    }

    private static func probe(_ route: String, owner: TabManager, window: NSWindow, mountObserved: Date,
                              duplicateBatch: Bool, directory: URL, delegate: AppDelegate) async -> CaseReport {
        var result = CaseReport(route: route)
        let url = directory.appendingPathComponent(route + ".md")
        let source = "# Open probe\n\nExact e\u{301} 😀\t  \n"
        do { try Data(source.utf8).write(to: url) }
        catch { result.preconditions["scratchFileWritten"] = false; return result }
        let oldSession = owner.activeSession
        let oldPDF = owner.activePDFManager
        let oldTabID = owner.activeTabID
        let watcher = PanelWatcher()
        watcher.start()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        await sleep(0.1)
        result.before = snapshot()
        let expectedWindows = result.before.count
        result.preconditions = [
            "registeredVisibleOwner": WindowRegistry.shared.window(for: owner) === window && window.isVisible,
            "realPDFPlaceholder": owner.hasOnlyPlaceholderTab && oldSession?.content.pdf != nil && oldPDF?.hasDocument == false,
            "placeholderStillSameSession": owner.activeSession === oldSession,
            "ownerIsKeyAndMain": NSApp.keyWindow === window && NSApp.mainWindow === window,
            "noPanelBeforeOpen": watcher.events.isEmpty && window.attachedSheet == nil,
            "twoScratchWindows": expectedWindows == 2,
            "openedWithinPlaceholderTimer": Date().timeIntervalSince(mountObserved) < 0.45,
        ]
        result.observedMountToOpenMilliseconds = Date().timeIntervalSince(mountObserved) * 1000
        guard result.qualified else { watcher.stop(); result.panelEvents = watcher.events; return result }
        let started = Date()
        delegate.application(NSApp, open: duplicateBatch ? [url, url] : [url])
        let openedSession = owner.activeSession
        // A second actual callback must also deduplicate the same canonical file.
        delegate.application(NSApp, open: [url])
        await sleep(1.2)
        watcher.stop()
        result.observationMilliseconds = Date().timeIntervalSince(started) * 1000
        result.panelEvents = watcher.events
        result.after = snapshot()
        let canonical = url.pageFlowCanonicalDocumentURL
        let matches = WindowRegistry.shared.allOpenTabs().flatMap(\.tabs).filter {
            $0.documentURL?.pageFlowCanonicalDocumentURL == canonical
        }
        let content = owner.activeMarkdownContent
        let editor = window.contentView.flatMap(findEditor)
        result.checks = [
            "oneCanonicalMarkdownSession": matches.count == 1 && content != nil,
            "oneTabInOwner": owner.tabs.count == 1 && owner.activeTabID == oldTabID,
            "duplicateOpenKeepsSameSession": owner.activeSession === openedSession,
            "expectedWindowCount": result.after.count == expectedWindows,
            "ownerWindowSurvives": window.isVisible && WindowRegistry.shared.window(for: owner) === window,
            "noUnexpectedOpenPanel": watcher.events.isEmpty,
            "noAttachedOpenPanel": !NSApp.windows.contains { $0.attachedSheet is NSOpenPanel },
            "exactDocumentSource": content?.documentManager.text.utf16.elementsEqual(source.utf16) == true,
            "exactMountedEditorSource": editor?.string.utf16.elementsEqual(source.utf16) == true,
            "diskUnchanged": (try? Data(contentsOf: url)) == Data(source.utf8),
            "pendingURLsDrained": delegate.pendingURLs.isEmpty,
        ]
        return result
    }

    private static func closeScratchWindow(_ window: NSWindow, owner: TabManager) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        // Cancelling a panel starts a native sheet-dismissal animation. A close
        // during that animation is ignored, so wait before the real close action.
        while window.attachedSheet != nil || NSApp.modalWindow != nil {
            guard Date() < deadline else { return false }
            await sleep(0.02)
        }
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        WindowChromeController.attached(to: window)?.setTrafficLightsVisible(true, animated: false)
        while window.standardWindowButton(.closeButton)?.isEnabled != true {
            guard Date() < deadline else { return false }
            await sleep(0.02)
        }
        window.performClose(nil)
        while window.isVisible || WindowRegistry.shared.window(for: owner) != nil {
            guard Date() < deadline else { return false }
            await sleep(0.02)
        }
        return true
    }

    private static func snapshot() -> [WindowState] {
        WindowRegistry.shared.allOpenTabs().map { group in
            WindowState(number: group.window.windowNumber, visible: group.window.isVisible, key: group.window.isKeyWindow,
                        sheetClass: group.window.attachedSheet.map { String(describing: type(of: $0)) },
                        tabIDs: group.tabs.map { $0.id.uuidString }, paths: group.tabs.compactMap { $0.documentURL?.path })
        }
    }

    private static func initialWindow() async -> WindowTabGroup? {
        for _ in 0..<500 {
            if AppDelegate.shared?.windowContentBuilder != nil,
               let group = WindowRegistry.shared.allOpenTabs().first(where: {
                   $0.window.isVisible && $0.window.identifier != PageFlowWindowIdentifiers.userCreated
               }) { return group }
            await sleep(0.01)
        }
        return nil
    }

    private static func registered(_ window: NSWindow, owner: TabManager) async -> Bool {
        for _ in 0..<100 {
            if window.isVisible && WindowRegistry.shared.window(for: owner) === window { return true }
            await sleep(0.01)
        }
        return false
    }

    private static func findEditor(in view: NSView) -> NSTextView? {
        guard !view.isHidden else { return nil }
        if let text = view as? NSTextView, String(describing: type(of: text)).contains("NativeTextView") { return text }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private static func sleep(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func finish(_ cases: [CaseReport], errors: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let passed = errors.isEmpty && cases.count == 2 && cases.allSatisfy(\.passed)
        let failed = cases.contains { $0.qualified && !$0.passed }
        let code: Int32 = passed ? 0 : (failed ? 1 : 2)
        let report = Report(runID: env["PAGEFLOW_QA_RUN_ID"] ?? UUID().uuidString,
                            bundleID: Bundle.main.bundleIdentifier ?? "unknown", executable: Bundle.main.bundlePath,
                            processID: ProcessInfo.processInfo.processIdentifier,
                            status: passed ? "passed" : (failed ? "failed" : "invalid"), exitStatus: code, cases: cases, errors: errors)
        let directory = env["PAGEFLOW_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pageflow-open-report-\(report.runID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("open-document.json"), options: .atomic)
            print("OPEN DOCUMENT QA \(report.status): \(directory.path)")
            fflush(stdout)
            exit(code)
        } catch {
            FileHandle.standardError.write(Data("OPEN DOCUMENT QA invalid: \(error)\n".utf8))
            exit(2)
        }
    }
}
#endif
