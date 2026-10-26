// DEBUG-only semantic close probe. Run in an isolated app sandbox with
// PAGEFLOW_QA_WINDOW_CLOSE=markdown or pdf. Uses scratch documents, keeps a
// clean sentinel window open, writes window-close.json, then exits 0/1/2 for
// pass/qualified failure/invalid fixture. Normal launches never enter this code.
// PAGEFLOW_QA_WINDOW_CLOSE_SCENARIO defaults to cancel; other scenarios are
// dont-save, save, save-failure, save-as-cancel and mixed-cancel (last two Markdown only).

#if DEBUG
import AppKit
import PDFKit

@MainActor
enum WindowCloseQA {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PAGEFLOW_QA_WINDOW_CLOSE"] != nil
    }

    static func startIfRequested() {
        guard isRequested else { return }
        Task { await run() }
    }

    private enum Kind: String, Codable { case markdown, pdf }
    private enum Scenario: String, Codable {
        case cancel, dontSave = "dont-save", save, saveFailure = "save-failure"
        case saveAsCancel = "save-as-cancel", mixedCancel = "mixed-cancel"

        var retainsWindow: Bool { self != .dontSave && self != .save }
        var alertActions: [String] {
            switch self {
            case .cancel: return ["Cancel"]
            case .dontSave: return ["Don't Save"]
            case .save, .saveFailure, .saveAsCancel: return ["Save"]
            case .mixedCancel: return ["Don't Save", "Cancel"]
            }
        }
    }

    private struct ViewDiagnostic: Encodable {
        let viewClass: String
        let hidden: Bool
        let alpha: CGFloat
        let enabled: Bool?
    }

    private struct ButtonDiagnostic: Encodable {
        let enabled: Bool
        let hidden: Bool
        let hiddenByAncestor: Bool
        let alpha: CGFloat
        let target: String
        let action: String
        let ancestors: [ViewDiagnostic]
    }

    private struct WindowDiagnostic: Encodable {
        let appActive: Bool
        let activationPolicy: Int
        let frontmostBundleID: String?
        let windowNumber: Int
        let keyWindowNumber: Int?
        let mainWindowNumber: Int?
        let isKey: Bool
        let isMain: Bool
        let canBecomeKey: Bool
        let canBecomeMain: Bool
        let styleMask: UInt
        let attachedSheetNumber: Int?
        let modalWindowNumber: Int?
        let chromeControllerAttached: Bool
        let closeButton: ButtonDiagnostic?
    }

    private struct CaseReport: Encodable {
        let route: String
        let kind: Kind
        let scenario: Scenario
        var windowClass = ""
        var delegateClass = "nil"
        var controllerClass = "nil"
        var preconditions: [String: Bool] = [:]
        var checks: [String: Bool] = [:]
        var diagnostics: [String: WindowDiagnostic] = [:]
        var activationWaitMilliseconds: Double = 0
        var errors: [String] = []
        var qualified: Bool { !preconditions.isEmpty && preconditions.values.allSatisfy { $0 } }
        var outcome: String {
            if !qualified || !errors.isEmpty { return "invalid" }
            return !checks.isEmpty && checks.values.allSatisfy { $0 } ? "passed" : "failed"
        }

        private enum CodingKeys: String, CodingKey {
            case route, kind, scenario, windowClass, delegateClass, controllerClass, preconditions, checks, diagnostics
            case activationWaitMilliseconds, errors, qualified, outcome
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(route, forKey: .route)
            try values.encode(kind, forKey: .kind)
            try values.encode(scenario, forKey: .scenario)
            try values.encode(windowClass, forKey: .windowClass)
            try values.encode(delegateClass, forKey: .delegateClass)
            try values.encode(controllerClass, forKey: .controllerClass)
            try values.encode(preconditions, forKey: .preconditions)
            try values.encode(checks, forKey: .checks)
            try values.encode(diagnostics, forKey: .diagnostics)
            try values.encode(activationWaitMilliseconds, forKey: .activationWaitMilliseconds)
            try values.encode(errors, forKey: .errors)
            try values.encode(qualified, forKey: .qualified)
            try values.encode(outcome, forKey: .outcome)
        }
    }

    private struct RunReport: Encodable {
        let runID: String
        let kind: String
        let scenario: String
        let status: String
        let exitStatus: Int32
        let cases: [CaseReport]
        let errors: [String]
    }

    private struct DocumentProbe {
        let undo: UndoManager
        let preconditions: [String: Bool]
        let sourceIntact: @MainActor () -> Bool
        let undoRedoIntact: @MainActor () -> Bool
        let savedDiskMatches: @MainActor () -> Bool
    }

    @MainActor
    private final class CloseAttempt {
        let window: NSWindow
        let scenario: Scenario
        let deadline = Date().addingTimeInterval(5)
        var observedAlert = false
        var clickedCancel = false
        var clickedDontSave = false
        var clickedSave = false
        var savePanelObserved = false
        var savePanelCancelled = false
        var alertCount = 0
        var observedClose = false
        var timedOut = false
        private var timer: Timer?
        private var observer: NSObjectProtocol?
        private var handledPanels: [NSWindow] = []

        init(window: NSWindow, scenario: Scenario) {
            self.window = window
            self.scenario = scenario
        }

        func start() {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.observedClose = true }
            }
            let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollAlert() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        private func pollAlert() {
            guard !clickedCancel && !savePanelCancelled else { return }
            if Date() >= deadline {
                timedOut = true
                if NSApp.modalWindow != nil { NSApp.abortModal() }
                if let sheet = window.attachedSheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.cancel.rawValue) }
                timer?.invalidate()
                return
            }
            for panel in [NSApp.modalWindow, window.attachedSheet].compactMap({ $0 }) {
                if scenario == .saveAsCancel, clickedSave, let savePanel = panel as? NSSavePanel {
                    savePanelObserved = true
                    savePanelCancelled = true
                    savePanel.cancel(nil)
                    return
                }
                guard alertCount < scenario.alertActions.count,
                      !handledPanels.contains(where: { $0 === panel }) else { continue }
                let buttons = panel.contentView.map(Self.buttons(in:)) ?? []
                guard buttons.contains(where: { $0.title == "Save" }),
                      buttons.contains(where: { $0.title == "Don't Save" }),
                      buttons.contains(where: { $0.title == "Cancel" }),
                      let action = buttons.first(where: { $0.title == scenario.alertActions[alertCount] && $0.isEnabled }) else { continue }
                observedAlert = true
                handledPanels.append(panel)
                alertCount += 1
                clickedCancel = clickedCancel || action.title == "Cancel"
                clickedDontSave = clickedDontSave || action.title == "Don't Save"
                clickedSave = clickedSave || action.title == "Save"
                action.performClick(nil)
                return
            }
        }

        private static func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
    }

    private static func run() async {
        let env = ProcessInfo.processInfo.environment
        let kindName = env["PAGEFLOW_QA_WINDOW_CLOSE"] ?? ""
        let scenarioName = env["PAGEFLOW_QA_WINDOW_CLOSE_SCENARIO"] ?? "cancel"
        guard let kind = Kind(rawValue: kindName), let scenario = Scenario(rawValue: scenarioName),
              (kind == .markdown || (scenario != .saveAsCancel && scenario != .mixedCancel)), !TestEnvironment.isRunningTests,
              !QAReplay.isRequested else {
            finish(kind: kindName, cases: [], errors: ["Use markdown or pdf in a standalone app without QAReplay/XCTest"])
        }
        guard !QAPresentation.runsInBackground else {
            finish(kind: kindName, cases: [], errors: ["Deferred: native close-button and sheet routing require a foreground key/main window; background policy forbids activation"])
        }
        QAPresentation.activateIfAllowed()
        guard let initial = await initialWindow(), let delegate = AppDelegate.shared else {
            finish(kind: kindName, cases: [], errors: ["No initial WindowGroup registration or app delegate"])
        }
        initial.tabManager.closeFilePicker()
        guard initial.tabManager.tabs.allSatisfy({ $0.documentURL == nil }),
              initial.tabManager.dirtyDocuments().isEmpty else {
            finish(kind: kindName, cases: [], errors: ["Initial window is not a clean scratch placeholder"])
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pageflow-window-close-\(UUID().uuidString)", isDirectory: true)
        var reports: [CaseReport] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sentinelManager = TabManager(createInitialTab: false)
            guard let sentinel = delegate.createNewWindow(with: sentinelManager),
                  await registered(sentinel, manager: sentinelManager) else {
                finish(kind: kindName, cases: [], errors: ["Clean sentinel did not register"])
            }
            reports.append(await probe(route: "initial-window-group", kind: kind, scenario: scenario,
                                       manager: initial.tabManager, window: initial.window,
                                       sentinel: sentinel, sentinelManager: sentinelManager, directory: directory))
            let createdManager = TabManager()
            guard let created = delegate.createNewWindow(with: createdManager),
                  await registered(created, manager: createdManager) else {
                finish(kind: kindName, cases: reports, errors: ["App-created target did not register"])
            }
            reports.append(await probe(route: "app-created-hosted-window", kind: kind, scenario: scenario,
                                       manager: createdManager, window: created,
                                       sentinel: sentinel, sentinelManager: sentinelManager, directory: directory))
        } catch {
            finish(kind: kindName, cases: reports, errors: [String(describing: error)])
        }
        try? FileManager.default.removeItem(at: directory)
        finish(kind: kindName, cases: reports, errors: [])
    }

    private static func probe(route: String, kind: Kind, scenario: Scenario, manager: TabManager, window: NSWindow,
                              sentinel: NSWindow, sentinelManager: TabManager, directory: URL) async -> CaseReport {
        var report = CaseReport(route: route, kind: kind, scenario: scenario)
        report.windowClass = String(describing: type(of: window))
        report.delegateClass = window.delegate.map { String(describing: type(of: $0)) } ?? "nil"
        report.controllerClass = window.windowController.map { String(describing: type(of: $0)) } ?? "nil"
        let routeDirectory = directory.appendingPathComponent(route, isDirectory: true)
        let url = routeDirectory.appendingPathComponent("source." + (kind == .markdown ? "md" : "pdf"))
        do {
            try FileManager.default.createDirectory(at: routeDirectory, withIntermediateDirectories: true)
            if kind == .markdown {
                try Data("# Close probe\r\n\r\nOriginal e\u{301} 😀\t  \r\n".utf8).write(to: url)
            } else {
                let document = PDFDocument()
                document.insert(PDFPage(), at: 0)
                guard document.write(to: url) else { throw ProbeError("Could not create scratch PDF") }
            }
            let diskBefore = try Data(contentsOf: url)
            let filesBefore = try FileManager.default.contentsOfDirectory(atPath: routeDirectory.path).sorted()
            var diskOracleURL = url
            var background: (session: TabSession, probe: DocumentProbe, url: URL, bytes: Data)?
            manager.closeFilePicker()
            if scenario == .mixedCancel {
                let backgroundURL = routeDirectory.appendingPathComponent("background.pdf")
                let pdf = PDFDocument()
                pdf.insert(PDFPage(), at: 0)
                guard pdf.write(to: backgroundURL) else { throw ProbeError("Could not create background scratch PDF") }
                let bytes = try Data(contentsOf: backgroundURL)
                manager.openDocument(url: backgroundURL, isSecurityScoped: false)
                guard await loaded(.pdf, url: backgroundURL, manager: manager, window: window),
                      await activateAndWait(window), let session = manager.activeSession else {
                    throw ProbeError("Mixed background PDF did not mount and activate")
                }
                background = (session, try prepare(.pdf, session: session, window: window, saveURL: backgroundURL), backgroundURL, bytes)
            }
            if scenario == .saveAsCancel {
                manager.newMarkdownDocument()
            } else {
                manager.openDocument(url: url, isSecurityScoped: false)
            }
            QAPresentation.show(window)
            guard await loaded(kind, url: scenario == .saveAsCancel ? nil : url, manager: manager, window: window),
                  let session = manager.activeSession else { throw ProbeError("Scratch document did not mount") }
            report.diagnostics["beforeActivation"] = diagnose(window)
            let activationStart = Date()
            let activationReady = await activateAndWait(window)
            report.activationWaitMilliseconds = Date().timeIntervalSince(activationStart) * 1000
            report.diagnostics["afterActivation"] = diagnose(window)
            report.preconditions = [
                "activationReadyWithinDeadline": activationReady,
                "appActive": NSApp.isActive,
                "targetKey": window.isKeyWindow,
                "targetMain": window.isMainWindow,
                "targetCanBecomeKey": window.canBecomeKey,
                "targetCanBecomeMain": window.canBecomeMain,
                "targetVisible": window.isVisible,
                "targetClosable": window.styleMask.contains(.closable),
                "closeButtonEnabled": window.standardWindowButton(.closeButton)?.isEnabled == true,
                "targetRegistered": WindowRegistry.shared.window(for: manager) === window,
                "noAttachedSheet": window.attachedSheet == nil,
                "noModalWindow": NSApp.modalWindow == nil,
                "sentinelVisible": sentinel.isVisible,
                "sentinelRegistered": WindowRegistry.shared.window(for: sentinelManager) === sentinel,
                "sentinelClean": sentinelManager.dirtyDocuments().isEmpty,
                "separateSentinel": sentinel !== window,
                "expectedRoute": (window.identifier == PageFlowWindowIdentifiers.userCreated) == (route == "app-created-hosted-window"),
                "diskUnchangedBeforeClose": try Data(contentsOf: url) == diskBefore,
            ]
            // Complete native activation and hover reveal before the pending edit.
            guard report.qualified else { return report }
            if scenario == .saveFailure {
                let preservedDirectory = directory.appendingPathComponent(route + "-preserved", isDirectory: true)
                try FileManager.default.moveItem(at: routeDirectory, to: preservedDirectory)
                try Data("blocked parent".utf8).write(to: routeDirectory)
                diskOracleURL = preservedDirectory.appendingPathComponent(url.lastPathComponent)
                report.preconditions["destinationParentIsFile"] = (try routeDirectory.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            }
            if scenario == .saveAsCancel {
                report.preconditions["untitledWithoutDestination"] = session.content.markdown?.documentManager.documentURL == nil
            }
            if let background {
                report.preconditions["mixedBackgroundDirty"] = background.session.content.document.isDirty
                report.preconditions["mixedBackgroundUndoAvailable"] = background.probe.undo.canUndo
            }
            let document = try prepare(kind, session: session, window: window,
                                       saveURL: scenario == .saveAsCancel ? nil : url)
            report.preconditions.merge(document.preconditions) { _, new in new }
            report.diagnostics["beforeClose"] = diagnose(window)
            report.preconditions["closeButtonStillEnabledAfterEdit"] = window.standardWindowButton(.closeButton)?.isEnabled == true
            guard report.qualified else { return report }
            let undo = document.undo
            let canUndo = undo.canUndo
            let canRedo = undo.canRedo
            let tabsBefore = manager.tabs.map(\.id)
            let attempt = CloseAttempt(window: window, scenario: scenario)
            attempt.start()
            defer { attempt.stop() }
            window.performClose(nil)
            for _ in 0..<100 {
                if attempt.clickedCancel || attempt.savePanelCancelled || attempt.observedClose || attempt.timedOut { break }
                await sleep()
            }
            try? await Task.sleep(for: .milliseconds(200))
            report.checks = [
                "saveAlertObserved": attempt.observedAlert,
                "watcherCompletedWithinDeadline": !attempt.timedOut,
                "sentinelSurvived": sentinel.isVisible && WindowRegistry.shared.window(for: sentinelManager) === sentinel,
            ]
            if scenario.retainsWindow {
                report.checks.merge([
                    "noWillClose": !attempt.observedClose,
                    "windowStillVisible": window.isVisible,
                    "sameRegisteredWindow": WindowRegistry.shared.window(for: manager) === window,
                    "sameSession": manager.sessions[session.id] === session && manager.activeTabID == session.id,
                    "sameAllTabs": manager.tabs.map(\.id) == tabsBefore,
                    "sameUndoManager": session.undoManager === undo,
                    "sameUndoAvailability": undo.canUndo == canUndo && undo.canRedo == canRedo,
                    "sameLiveSource": document.sourceIntact(),
                    "diskUnchanged": try Data(contentsOf: diskOracleURL) == diskBefore,
                ]) { _, new in new }
            } else {
                report.checks.merge([
                    "willCloseObserved": attempt.observedClose,
                    "windowClosed": !window.isVisible,
                    "windowUnregistered": WindowRegistry.shared.window(for: manager) == nil,
                    "sessionsReleased": manager.sessions.isEmpty && manager.tabs.isEmpty,
                    "undoCleared": !undo.canUndo && !undo.canRedo,
                ]) { _, new in new }
            }
            switch scenario {
            case .cancel:
                report.checks["cancelClicked"] = attempt.clickedCancel
            case .dontSave:
                report.checks["dontSaveClicked"] = attempt.clickedDontSave
                report.checks["diskUnchanged"] = try Data(contentsOf: url) == diskBefore
            case .save:
                report.checks["saveClicked"] = attempt.clickedSave
                report.checks["savedDiskMatchesLiveSource"] = document.savedDiskMatches()
            case .saveFailure:
                report.checks["saveClicked"] = attempt.clickedSave
                report.checks["failedDestinationStillBlocked"] = (try routeDirectory.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            case .saveAsCancel:
                report.checks["saveClicked"] = attempt.clickedSave
                report.checks["savePanelObserved"] = attempt.savePanelObserved
                report.checks["savePanelCancelled"] = attempt.savePanelCancelled
                let filesAfter = try FileManager.default.contentsOfDirectory(atPath: routeDirectory.path).sorted()
                report.checks["noSaveAsFileCreated"] = session.content.markdown?.documentManager.documentURL == nil
                    && filesAfter == filesBefore
            case .mixedCancel:
                report.checks["dontSaveClicked"] = attempt.clickedDontSave
                report.checks["cancelClicked"] = attempt.clickedCancel
                report.checks["twoAlertsObserved"] = attempt.alertCount == 2
                if let background {
                    report.checks["backgroundSourceIntact"] = manager.sessions[background.session.id] === background.session
                        && background.probe.sourceIntact()
                    report.checks["backgroundDiskUnchanged"] = try Data(contentsOf: background.url) == background.bytes
                }
            }
            if scenario.retainsWindow && report.checks.values.allSatisfy({ $0 }) {
                report.checks["nativeUndoRedoStillWorks"] = document.undoRedoIntact()
                if let background { report.checks["backgroundUndoRedoStillWorks"] = background.probe.undoRedoIntact() }
            }
        } catch {
            report.errors.append(String(describing: error))
        }
        return report
    }

    private static func prepare(_ kind: Kind, session: TabSession, window: NSWindow, saveURL: URL?) throws -> DocumentProbe {
        guard let undo = session.undoManager else { throw ProbeError("No native document Undo manager") }
        undo.groupsByEvent = false
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        switch kind {
        case .markdown:
            guard let content = session.content.markdown, let root = window.contentView,
                  let editor = findEditor(in: root), window.makeFirstResponder(editor) else {
                throw ProbeError("No focused native Markdown editor")
            }
            let original = Array(editor.string.utf16)
            undo.beginUndoGrouping()
            editor.insertText("Pending e\u{301} 😀\t  \r\n", replacementRange: NSRange(location: 0, length: 0))
            editor.breakUndoCoalescing()
            undo.endUndoGrouping()
            let edited = Array(editor.string.utf16)
            let savedBytes = TextFileCodec.encode(editor.string, fidelity: content.documentManager.fidelity).data
            return DocumentProbe(undo: undo, preconditions: [
                "nativeEditChangedSource": edited != original,
                "liveEditNotYetPublished": Array(content.documentManager.text.utf16) != edited,
                "nativeUndoAvailable": undo.canUndo,
            ], sourceIntact: {
                editor.window === window && Array(editor.string.utf16) == edited
                    && Array(content.documentManager.text.utf16) == edited
            }, undoRedoIntact: {
                undo.undo()
                content.reconcileLiveText()
                guard Array(editor.string.utf16) == original,
                      Array(content.documentManager.text.utf16) == original, undo.canRedo else { return false }
                undo.redo()
                content.reconcileLiveText()
                return Array(editor.string.utf16) == edited && Array(content.documentManager.text.utf16) == edited
            }, savedDiskMatches: {
                guard let saveURL else { return false }
                return (try? Data(contentsOf: saveURL)) == savedBytes
            })
        case .pdf:
            guard let manager = session.pdfManager, let pdf = manager.document,
                  let page = pdf.page(at: 0), let root = window.contentView,
                  let pdfView = findPDFView(in: root, document: pdf) else { throw ProbeError("No mounted live PDF page") }
            let original = page.rotation
            undo.beginUndoGrouping()
            manager.rotatePage(at: 0, clockwise: true)
            undo.endUndoGrouping()
            let edited = page.rotation
            return DocumentProbe(undo: undo, preconditions: [
                "nativeEditChangedSource": edited != original,
                "documentDirty": manager.isDirty,
                "nativeUndoAvailable": undo.canUndo,
            ], sourceIntact: {
                pdfView.window === window && pdfView.document === pdf && manager.document === pdf
                    && pdf.pageCount == 1 && pdf.page(at: 0) === page && page.rotation == edited
            }, undoRedoIntact: {
                undo.undo()
                guard page.rotation == original, undo.canRedo else { return false }
                undo.redo()
                return manager.document === pdf && page.rotation == edited
            }, savedDiskMatches: {
                guard let saveURL, let saved = PDFDocument(url: saveURL) else { return false }
                return saved.pageCount == 1 && saved.page(at: 0)?.rotation == edited
            })
        }
    }

    private static func initialWindow() async -> WindowTabGroup? {
        for _ in 0..<500 {
            if AppDelegate.shared?.windowContentBuilder != nil,
               let initial = WindowRegistry.shared.allOpenTabs().first(where: {
                   $0.window.identifier != PageFlowWindowIdentifiers.userCreated && $0.window.isVisible
               }) { return initial }
            await sleep()
        }
        return nil
    }

    private static func activateAndWait(_ window: NSWindow) async -> Bool {
        guard !QAPresentation.runsInBackground else { return false }
        for index in 0..<250 {
            if index % 25 == 0 {
                QAPresentation.activateIfAllowed()
                QAPresentation.show(window)
                window.makeMain()
                WindowChromeController.attached(to: window)?.setTrafficLightsVisible(true, animated: false)
            }
            if NSApp.isActive && window.isKeyWindow && window.isMainWindow,
               window.standardWindowButton(.closeButton)?.isEnabled == true,
               window.attachedSheet == nil && NSApp.modalWindow == nil { return true }
            await sleep()
        }
        return false
    }

    private static func diagnose(_ window: NSWindow) -> WindowDiagnostic {
        let closeButton = window.standardWindowButton(.closeButton).map { button in
            var ancestors: [ViewDiagnostic] = []
            var ancestor = button.superview
            while let view = ancestor {
                ancestors.append(ViewDiagnostic(viewClass: String(describing: type(of: view)),
                                                hidden: view.isHidden, alpha: view.alphaValue,
                                                enabled: (view as? NSControl)?.isEnabled))
                ancestor = view.superview
            }
            return ButtonDiagnostic(enabled: button.isEnabled, hidden: button.isHidden,
                                    hiddenByAncestor: button.isHiddenOrHasHiddenAncestor, alpha: button.alphaValue,
                                    target: button.target.map { String(describing: type(of: $0)) } ?? "nil",
                                    action: button.action.map(NSStringFromSelector) ?? "nil", ancestors: ancestors)
        }
        return WindowDiagnostic(appActive: NSApp.isActive, activationPolicy: NSApp.activationPolicy().rawValue,
                                frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                windowNumber: window.windowNumber, keyWindowNumber: NSApp.keyWindow?.windowNumber,
                                mainWindowNumber: NSApp.mainWindow?.windowNumber, isKey: window.isKeyWindow,
                                isMain: window.isMainWindow, canBecomeKey: window.canBecomeKey,
                                canBecomeMain: window.canBecomeMain, styleMask: window.styleMask.rawValue,
                                attachedSheetNumber: window.attachedSheet?.windowNumber,
                                modalWindowNumber: NSApp.modalWindow?.windowNumber,
                                chromeControllerAttached: WindowChromeController.attached(to: window) != nil,
                                closeButton: closeButton)
    }

    private static func registered(_ window: NSWindow, manager: TabManager) async -> Bool {
        for _ in 0..<250 {
            if WindowRegistry.shared.window(for: manager) === window && window.isVisible { return true }
            await sleep()
        }
        return false
    }

    private static func loaded(_ kind: Kind, url: URL?, manager: TabManager, window: NSWindow) async -> Bool {
        for _ in 0..<500 {
            if kind == .markdown, let content = manager.activeMarkdownContent,
               content.documentManager.documentURL?.standardizedFileURL == url?.standardizedFileURL,
               let root = window.contentView, let editor = findEditor(in: root), !editor.string.isEmpty { return true }
            if kind == .pdf, let pdf = manager.activePDFManager,
               pdf.documentURL?.standardizedFileURL == url?.standardizedFileURL, pdf.pageCount == 1,
               let document = pdf.document, let root = window.contentView,
               findPDFView(in: root, document: document) != nil { return true }
            await sleep()
        }
        return false
    }

    private static func findEditor(in view: NSView) -> NSTextView? {
        guard !view.isHidden else { return nil }
        if let editor = view as? NSTextView, String(describing: type(of: editor)).contains("NativeTextView") { return editor }
        return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
    }

    private static func findPDFView(in view: NSView, document: PDFDocument) -> PDFView? {
        guard !view.isHidden else { return nil }
        if let pdfView = view as? PDFView, pdfView.document === document { return pdfView }
        return view.subviews.lazy.compactMap { findPDFView(in: $0, document: document) }.first
    }

    private static func sleep() async { try? await Task.sleep(for: .milliseconds(20)) }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func finish(kind: String, cases: [CaseReport], errors: [String]) -> Never {
        let env = ProcessInfo.processInfo.environment
        let runID = env["PAGEFLOW_QA_RUN_ID"] ?? UUID().uuidString
        let directory = env["PAGEFLOW_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pageflow-close-qa/\(runID)", isDirectory: true)
        let qualifiedFailure = cases.contains { $0.outcome == "failed" }
        let passed = errors.isEmpty && cases.count == 2 && cases.allSatisfy { $0.outcome == "passed" }
        let exitStatus: Int32 = passed ? 0 : (qualifiedFailure ? 1 : 2)
        let report = RunReport(runID: runID, kind: kind, scenario: env["PAGEFLOW_QA_WINDOW_CLOSE_SCENARIO"] ?? "cancel",
                               status: passed ? "passed" : (qualifiedFailure ? "failed" : "invalid"),
                               exitStatus: exitStatus, cases: cases, errors: errors)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("window-close.json"), options: .atomic)
            print("WINDOW CLOSE QA \(report.status): \(directory.path)")
            fflush(stdout)
            exit(exitStatus)
        } catch {
            FileHandle.standardError.write(Data("WINDOW CLOSE QA invalid: report write failed: \(error)\n".utf8))
            exit(2)
        }
    }
}
#endif
