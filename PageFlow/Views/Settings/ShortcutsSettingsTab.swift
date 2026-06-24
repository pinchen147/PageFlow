//
//  ShortcutsSettingsTab.swift
//  PageFlow
//
//  Settings tab for customizing keyboard shortcuts
//

import SwiftUI
import AppKit

struct ShortcutsSettingsTab: View {
    var body: some View {
        Form {
            ForEach(ShortcutCatalog.grouped(), id: \.0) { group in
                Section(group.0.rawValue) {
                    ForEach(group.1) { action in
                        ShortcutRow(actionID: action.id, label: action.title)
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
                .pageFlowLiquidGlassSurface(.settingsRow)

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

                    if let warning = validation?.warning {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(validation?.blocksConfirm == true ? .red : .orange)
                            .fixedSize()
                    }

                    Button("✓") {
                        confirmShortcut()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.spacingSM)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassSurface(.settingsAction(enabled: canConfirm, activeTint: 0.10))
                    .disabled(!canConfirm)

                    Button("✕") {
                        cancelRecording()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DesignTokens.spacingSM)
                    .padding(.vertical, DesignTokens.spacingXS)
                    .pageFlowLiquidGlassSurface(.settingsRow.with(strokeOpacity: 0.14))
                }
            } else {
                Button(currentDisplayString) {
                    startRecording()
                }
                .buttonStyle(.plain)
                .frame(width: DesignTokens.shortcutButtonWidth)
                .padding(.vertical, DesignTokens.spacingXS)
                .pageFlowLiquidGlassSurface(.settingsRow)
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

    /// Vetting of the in-progress recording (nil until a key is captured).
    private var validation: ShortcutValidation? {
        pendingShortcut.map { ShortcutCatalog.validate($0, for: actionID) }
    }

    /// Confirm is allowed once a key is captured and it isn't reserved / too weak.
    /// A mere conflict only warns — the user may deliberately reassign.
    private var canConfirm: Bool {
        guard let validation else { return false }
        return !validation.blocksConfirm
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
        guard let shortcut = pendingShortcut,
              !ShortcutCatalog.validate(shortcut, for: actionID).blocksConfirm else { return }
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
