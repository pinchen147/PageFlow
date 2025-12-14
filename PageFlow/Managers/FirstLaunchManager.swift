import Foundation
import AppKit
import UniformTypeIdentifiers

/// Manages first-launch experience and default PDF reader settings
@Observable
final class FirstLaunchManager {
    private let hasShownDefaultPromptKey = "hasShownDefaultPDFPrompt"

    /// Check if PageFlow is currently the default PDF reader
    var isDefaultPDFReader: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let pdfUTI = UTType.pdf.identifier as CFString
        guard let currentHandler = LSCopyDefaultRoleHandlerForContentType(pdfUTI, .all)?.takeRetainedValue() as String? else {
            return false
        }
        return currentHandler.lowercased() == bundleIdentifier.lowercased()
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
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            showErrorAlert(message: "Could not determine app bundle identifier.")
            return
        }

        let pdfUTI = UTType.pdf.identifier as CFString
        let status = LSSetDefaultRoleHandlerForContentType(pdfUTI, .all, bundleIdentifier as CFString)

        if status == noErr {
            // Verify it actually worked
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.isDefaultPDFReader == true {
                    self?.showSuccessAlert()
                } else {
                    self?.openSystemPreferencesForDefaultApps()
                }
            }
        } else {
            openSystemPreferencesForDefaultApps()
        }
    }

    /// Open System Settings to let user manually set default PDF app
    private func openSystemPreferencesForDefaultApps() {
        let alert = NSAlert()
        alert.messageText = "Set Default PDF Reader"
        alert.informativeText = """
        To set PageFlow as your default PDF reader:

        1. Right-click any PDF file in Finder
        2. Select "Get Info" (or press ⌘I)
        3. Under "Open with:", select PageFlow
        4. Click "Change All..."

        This will make PageFlow open all PDF files.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showSuccessAlert() {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = "PageFlow is now your default PDF reader. All PDF files will open in PageFlow."
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
