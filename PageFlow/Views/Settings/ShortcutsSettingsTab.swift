//
//  ShortcutsSettingsTab.swift
//  PageFlow
//
//  Settings tab for customizing keyboard shortcuts
//

import SwiftUI
import AppKit

struct ShortcutsSettingsTab: View {
    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("nextPage", "Next Page"),
            ("previousPage", "Previous Page"),
            ("goBack", "Back"),
            ("goForward", "Forward"),
            ("goToPage", "Go to Page...")
        ]),
        ("Zoom", [
            ("zoomIn", "Zoom In"),
            ("zoomOut", "Zoom Out"),
            ("actualSize", "Actual Size"),
            ("zoomToFit", "Zoom to Fit")
        ]),
        ("Annotations", [
            ("highlight", "Highlight"),
            ("underline", "Underline"),
            ("comment", "Add Comment"),
            ("bookmark", "Toggle Bookmark")
        ]),
        ("Edit", [
            ("copyPage", "Copy Page"),
            ("cutPage", "Cut Page"),
            ("pastePage", "Paste Page"),
            ("rotateClockwise", "Rotate Clockwise"),
            ("rotateCounterClockwise", "Rotate Counter-Clockwise"),
            ("deletePage", "Delete Page")
        ]),
        ("Other", [
            ("search", "Find..."),
            ("save", "Save"),
            ("toggleSidebar", "Toggle Sidebar"),
            ("toggleTopBar", "Toggle Top Bar Visibility"),
            ("toggleToolbar", "Toggle Toolbar Visibility"),
            ("togglePageIndicator", "Toggle Page Number Visibility"),
            ("copyPageAsMarkdown", "Copy Page as Markdown"),
            ("copyDocumentAsMarkdown", "Copy Document as Markdown")
        ])
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.0) { action, label in
                        ShortcutRow(actionID: action, label: label)
                    }
                }
            }

            Section {
                Button("Reset All to Defaults") {
                    SettingsManager.shared.resetShortcuts()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingXS)
                .pageFlowLiquidGlassSurface(
                    cornerRadius: DesignTokens.spacingSM,
                    tintOpacity: 0.08,
                    interactive: true,
                    variant: .clear,
                    strokeOpacity: 0.16
                )

                Text("Changes require restarting PageFlow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ShortcutRow: View {
    let actionID: String
    let label: String

    @State private var isRecording = false
    @State private var pendingShortcut: ShortcutModel?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            if isRecording {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(pendingShortcut?.displayString ?? "Press keys...")
                        .foregroundStyle(.secondary)
                        .frame(width: DesignTokens.shortcutKeyDisplayWidth)

                    Button("✓") {
                        confirmShortcut()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.spacingSM)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassSurface(
                        cornerRadius: DesignTokens.spacingSM,
                        tintOpacity: pendingShortcut == nil ? 0.04 : 0.10,
                        interactive: pendingShortcut != nil,
                        variant: .clear,
                        strokeOpacity: pendingShortcut == nil ? 0.08 : 0.16
                    )
                    .disabled(pendingShortcut == nil)

                    Button("✕") {
                        cancelRecording()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.spacingSM)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassSurface(
                        cornerRadius: DesignTokens.spacingSM,
                        tintOpacity: 0.08,
                        interactive: true,
                        variant: .clear,
                        strokeOpacity: 0.14
                    )
                }
            } else {
                Button(currentDisplayString) {
                    startRecording()
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.shortcutButtonWidth)
                .padding(.vertical, DesignTokens.spacingXS)
                .pageFlowLiquidGlassSurface(
                    cornerRadius: DesignTokens.spacingSM,
                    tintOpacity: 0.08,
                    interactive: true,
                    variant: .clear,
                    strokeOpacity: 0.16
                )
            }
        }
        .onDisappear {
            // Clean up event monitor if view is removed while recording
            stopRecording()
        }
    }

    private var currentDisplayString: String {
        ShortcutModel.current(for: actionID).displayString
    }

    private func startRecording() {
        isRecording = true
        pendingShortcut = nil

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                cancelRecording()
                return nil
            }

            if let shortcut = ShortcutModel.from(event: event) {
                pendingShortcut = shortcut
            }
            return nil
        }
    }

    private func confirmShortcut() {
        guard let shortcut = pendingShortcut else { return }
        SettingsManager.shared.customShortcuts[actionID] = shortcut
        stopRecording()
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        pendingShortcut = nil
    }
}
