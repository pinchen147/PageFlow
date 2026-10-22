//
//  MarkdownSavePanel.swift
//  PageFlow
//
//  The single builder for the Markdown Save-As `NSSavePanel`. Both ⌘⇧S
//  (`TabManager.saveMarkdownDocumentAs`) and the quit-time path
//  (`AppDelegate.runSyncSaveAs`) route here so the allowed content types and the
//  default file name never disagree (previously the two sites differed: one
//  checked all markdown extensions, the other only `.md`, offering a
//  `notes.markdown` tab inconsistently). Lives in the markdown layer so
//  AppDelegate never has to know the markdown UTTypes.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum MarkdownSavePanel {
    /// Builds + runs the Markdown Save-As panel modally and returns the chosen
    /// destination URL, or `nil` if the user cancelled. `defaultName` is offered
    /// in the name field with a Markdown extension appended when it lacks one — so
    /// a `notes.markdown` default is preserved, while an extensionless `Untitled`
    /// becomes `Untitled.md`. Allowed types come from `URL.pageFlowMarkdownExtensions`,
    /// the single authority, so they can't drift from the open gate.
    static func runModal(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = URL.pageFlowMarkdownExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = markdownFileName(for: defaultName)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Appends a `.md` extension to `name` unless it already ends in any of the
    /// Markdown family extensions — the one consistent rule both call sites share.
    static func markdownFileName(for name: String) -> String {
        let lower = name.lowercased()
        let hasMarkdownExt = URL.pageFlowMarkdownExtensions.contains { lower.hasSuffix(".\($0)") }
        return hasMarkdownExt ? name : "\(name).md"
    }
}
