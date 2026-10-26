#if DEBUG
import AppKit

/// Presentation policy shared by automated QA and app-hosted tests.
@MainActor
enum QAPresentation {
    static var runsInBackground: Bool {
        if TestEnvironment.isRunningTests { return true }
        let environment = ProcessInfo.processInfo.environment
        // Foreground opt-in is reserved for a separately approved manual run.
        if environment["PAGEFLOW_QA_BACKGROUND"] == "0" { return false }
        return environment.keys.contains { $0.hasPrefix("PAGEFLOW_") && $0.contains("QA") }
    }

    static func prepare() {
        guard runsInBackground, let app = NSApp, app.activationPolicy() == .regular else { return }
        _ = app.setActivationPolicy(.accessory)
    }

    static func activateIfAllowed() {
        guard !runsInBackground else { return }
        NSApp?.activate(ignoringOtherApps: true)
    }

    static func show(_ window: NSWindow) {
        if runsInBackground {
            if window.level > .normal { window.orderOut(nil) }
            else { window.orderBack(nil) }
        }
        else { window.makeKeyAndOrderFront(nil) }
    }
}
#endif
