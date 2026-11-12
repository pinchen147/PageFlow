//
//  AnnotationsSettingsTab.swift
//  PageFlow
//
//  Settings pane for customizing highlight, underline and comment colors
//

import SwiftUI
import AppKit

struct AnnotationsSettingsTab: View {
    private typealias Presets = ReferenceWritableKeyPath<SettingsManager, [SettingsManager.ColorPreset]>

    private var settings: SettingsManager { SettingsManager.shared }

    var body: some View {
        Form {
            presetSection(
                "Highlight Colors", \.highlightPresets, fallback: .yellow,
                add: { $0.addHighlightPreset() }, remove: { $0.removeHighlightPreset(at: $1) }
            )
            presetSection(
                "Underline Colors", \.underlinePresets, fallback: .black,
                add: { $0.addUnderlinePreset() }, remove: { $0.removeUnderlinePreset(at: $1) }
            )
            presetSection(
                "Comment Colors", \.commentPresets, fallback: .gray,
                add: { $0.addCommentPreset() }, remove: { $0.removeCommentPreset(at: $1) }
            )

            Section {
                Button("Reset Colors to Defaults") {
                    settings.resetColors()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func presetSection(
        _ title: String,
        _ presets: Presets,
        fallback: NSColor,
        add: @escaping (SettingsManager) -> Void,
        remove: @escaping (SettingsManager, Int) -> Void
    ) -> some View {
        Section {
            ForEach(settings[keyPath: presets]) { preset in
                PresetRow(
                    name: nameBinding(of: preset.id, in: presets),
                    color: colorBinding(of: preset.id, in: presets, fallback: fallback),
                    canDelete: settings[keyPath: presets].count > 1,
                    onDelete: {
                        guard let index = settings[keyPath: presets].firstIndex(where: { $0.id == preset.id }) else { return }
                        remove(settings, index)
                    }
                )
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button {
                    add(settings)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add to \(title)")
            }
        }
    }

    private func nameBinding(of id: SettingsManager.ColorPreset.ID, in presets: Presets) -> Binding<String> {
        let settings = settings
        return Binding(
            get: { settings[keyPath: presets].first { $0.id == id }?.name ?? "" },
            set: { newValue in
                guard let index = settings[keyPath: presets].firstIndex(where: { $0.id == id }) else { return }
                settings[keyPath: presets][index].name = newValue
            }
        )
    }

    private func colorBinding(of id: SettingsManager.ColorPreset.ID, in presets: Presets, fallback: NSColor) -> Binding<NSColor> {
        let settings = settings
        return Binding(
            get: { settings[keyPath: presets].first { $0.id == id }?.color ?? fallback },
            set: { newValue in
                guard let index = settings[keyPath: presets].firstIndex(where: { $0.id == id }) else { return }
                var updated = settings[keyPath: presets][index]
                updated.color = newValue
                settings[keyPath: presets][index] = updated
            }
        )
    }
}

struct PresetRow: View {
    @Binding var name: String
    @Binding var color: NSColor
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .labelsHidden()

            Spacer()

            ColorWellView(color: $color)
                .frame(width: DesignTokens.colorWellWidth, height: DesignTokens.colorWellHeight)

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignTokens.presetRowHeight)
    }
}
