import Foundation
import AppKit
import UniformTypeIdentifiers

/// Manages first-launch experience and default PDF reader settings
@Observable
final class FirstLaunchManager {
    private let hasShownDefaultPromptKey = "hasShownDefaultPDFPrompt"
    private var isSettingDefaultPDFReader = false

    /// Check if PageFlow is currently the default PDF reader
    var isDefaultPDFReader: Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: UTType.pdf) else {
            return false
        }
        // Bundle identifiers are shared by installed, downloaded, and development copies.
        return applicationURL.resolvingSymlinksInPath().standardizedFileURL
            == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Check if this is first launch and show default PDF reader prompt if needed
    func handleFirstLaunch() {
        guard !hasShownDefaultPrompt else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showDefaultPDFReaderPrompt()
        }
    }

    private var hasShownDefaultPrompt: Bool {
        UserDefaults.standard.bool(forKey: hasShownDefaultPromptKey)
    }

    private func markPromptAsShown() {
        UserDefaults.standard.set(true, forKey: hasShownDefaultPromptKey)
    }

    /// Show native alert asking user to set PageFlow as default PDF reader
    private func showDefaultPDFReaderPrompt() {
        let alert = NSAlert()
        alert.messageText = "Set PageFlow as Default PDF Reader?"
        alert.informativeText = "Would you like to set PageFlow as your default application for opening PDF files?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set as Default")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        markPromptAsShown()

        if response == .alertFirstButtonReturn {
            setAsDefaultPDFReader()
        }
    }

    /// Set PageFlow as the default handler for PDF documents (callable from menu)
    func setAsDefaultPDFReader() {
        guard !isSettingDefaultPDFReader else { return }
        let applicationURL = Bundle.main.bundleURL
        guard applicationURL.pathExtension == "app" else {
            showErrorAlert(message: "Could not determine the running PageFlow application location.")
            return
        }

        isSettingDefaultPDFReader = true
        // This API identifies this copy and waits for any macOS consent prompt.
        NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: UTType.pdf) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSettingDefaultPDFReader = false
                if let error {
                    self.showManualDefaultInstructions(reason: error.localizedDescription)
                } else if self.isDefaultPDFReader {
                    self.showSuccessAlert()
                } else {
                    let selectedApplication = NSWorkspace.shared.urlForApplication(toOpen: UTType.pdf)?.path
                        ?? "No application"
                    self.showManualDefaultInstructions(
                        reason: "macOS still resolves PDF files to: \(selectedApplication)."
                    )
                }
            }
        }
    }

    private func showManualDefaultInstructions(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Default PDF Reader Was Not Changed"
        alert.informativeText = """
        \(reason)

        To set PageFlow as your default PDF reader:

        1. Right-click any PDF file in Finder
        2. Select "Get Info" (or press ⌘I)
        3. Under "Open with:", select this PageFlow copy at \(Bundle.main.bundleURL.path)
        4. Click "Change All..."

        A PDF with its own "Open with" setting may need to be changed individually.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = "PageFlow is now your default PDF reader. PDFs with an individual \"Open with\" setting may still open in another application."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
