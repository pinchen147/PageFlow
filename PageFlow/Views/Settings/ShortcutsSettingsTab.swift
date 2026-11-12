//
//  ShortcutsSettingsTab.swift
//  PageFlow
//
//  Settings tab for customizing keyboard shortcuts
//

import SwiftUI
import AppKit

struct ShortcutsSettingsTab: View {
    /// Held by the window, so its search can open this pane on a shortcut.
    @Binding var query: String
    @State private var settingsManager = SettingsManager.shared

    /// The sections with the shortcuts the search matches (all of them when it is empty).
    private var groups: [(ShortcutAction.Category, [ShortcutAction])] {
        _ = settingsManager.customShortcuts   // a rebinding re-runs a key search
        return ShortcutCatalog.grouped().compactMap { category, actions in
            let matching = actions.filter { ShortcutCatalog.matches($0, query: query) }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search shortcuts", text: $query, prompt: Text("Search by name or keys, like Bold or ⌘B"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }

            if groups.isEmpty {
                Section {
                    Text("No shortcuts match \u{201C}\(query)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(groups, id: \.0) { group in
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

                Text("Changes apply at once. While recording, ⌫ leaves a command with no shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct ShortcutRow: View {
    let actionID: String
    let label: String

    @State private var isRecording = false
    @State private var pendingShortcut: ShortcutModel?
    @State private var eventMonitor: Any?
    @State private var recordingWindow: NSWindow?
    @State private var showingReplacement = false
    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                Text(label)
                if ShortcutCatalog.legacyMarkdownIDs[ShortcutCatalog.canonicalID(for: actionID)] != nil {
                    Text("PDF, EPUB and Markdown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let action = ShortcutCatalog.action(for: actionID) {
                    let alternates = ShortcutCatalog.alternateShortcuts(for: action, current: ShortcutModel.currentForMarkdown(for: actionID))
                    if !alternates.isEmpty {
                        Text("Alternates: \(alternates.map(\.displayString).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let discrepancy = settingsManager.shortcutDiscrepancy(for: actionID) {
                    Text(discrepancy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()

            if isRecording {
                HStack(spacing: DesignTokens.spacingXS) {
                    Text(pendingShortcut?.displayString ?? "Press keys, or ⌫ for none")
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
                    .accessibilityLabel("Save shortcut")
                    .disabled(!canConfirm)

                    Button("✕") {
                        cancelRecording()
                    }
                    .accessibilityLabel("Cancel recording")
                }
            } else {
                Button(currentDisplayString) {
                    startRecording()
                }
                .frame(minWidth: DesignTokens.shortcutButtonWidth)
                .monospacedDigit()
            }
        }
        .onDisappear {
            // Clean up event monitor if view is removed while recording
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object as? NSWindow === recordingWindow, !showingReplacement { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .alert("Replace shortcut?", isPresented: $showingReplacement) {
            Button("Replace", role: .destructive) { savePendingShortcut() }
            Button("Cancel", role: .cancel) { stopRecording() }
        } message: {
            Text(replacementMessage)
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
    /// A conflict proceeds to a separate Replace/Cancel confirmation.
    private var canConfirm: Bool {
        guard let validation else { return false }
        return !validation.blocksConfirm
    }

    private func startRecording() {
        guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
        recordingWindow = window
        isRecording = true
        pendingShortcut = nil

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === recordingWindow, recordingWindow?.isKeyWindow == true,
                  recordingWindow?.attachedSheet == nil else {
                stopRecording()
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53, modifiers.isEmpty { // Escape
                cancelRecording()
                return nil
            }
            if event.keyCode == 51 || event.keyCode == 117, modifiers.isEmpty { // Delete: no shortcut
                pendingShortcut = ShortcutModel.none
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
        if !ShortcutCatalog.conflictingActions(forCombo: shortcut, excluding: actionID).isEmpty {
            removeRecordingMonitor()
            showingReplacement = true
        } else {
            savePendingShortcut()
        }
    }

    private var replacementMessage: String {
        guard let shortcut = pendingShortcut else { return "" }
        let owners = ShortcutCatalog.conflictingActions(forCombo: shortcut, excluding: actionID).map(\.title).joined(separator: ", ")
        return "Use \(shortcut.displayString) for \(label) and remove it from \(owners) where their document contexts overlap? Other contexts keep their shortcuts."
    }

    private func savePendingShortcut() {
        if let shortcut = pendingShortcut, !ShortcutCatalog.validate(shortcut, for: actionID).blocksConfirm {
            settingsManager.setShortcut(shortcut, for: actionID)
        }
        stopRecording()
    }

    private func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        removeRecordingMonitor()
        showingReplacement = false
        recordingWindow = nil
        isRecording = false
        pendingShortcut = nil
    }

    private func removeRecordingMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
