//
//  AnnotationsSettingsTab.swift
//  PageFlow
//
//  Settings tab for customizing highlight and underline colors
//

import SwiftUI
import AppKit

struct AnnotationsSettingsTab: View {
    private var settings: SettingsManager { SettingsManager.shared }

    var body: some View {
        Form {
            Section {
                ForEach(settings.highlightPresets) { preset in
                    PresetRow(
                        name: Binding(
                            get: {
                                SettingsManager.shared.highlightPresets.first { $0.id == preset.id }?.name ?? ""
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.highlightPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                SettingsManager.shared.highlightPresets[index].name = newValue
                            }
                        ),
                        color: Binding(
                            get: {
                                SettingsManager.shared.highlightPresets.first { $0.id == preset.id }?.color ?? .yellow
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.highlightPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                var updated = SettingsManager.shared.highlightPresets[index]
                                updated.color = newValue
                                SettingsManager.shared.highlightPresets[index] = updated
                            }
                        ),
                        canDelete: settings.highlightPresets.count > 1,
                        onDelete: {
                            guard let index = SettingsManager.shared.highlightPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                            SettingsManager.shared.removeHighlightPreset(at: index)
                        }
                    )
                }
            } header: {
                HStack {
                    Text("Highlight Colors")
                    Spacer()
                    Button(action: { SettingsManager.shared.addHighlightPreset() }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                            .pageFlowLiquidGlassSurface(.settingsRow)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(settings.underlinePresets) { preset in
                    PresetRow(
                        name: Binding(
                            get: {
                                SettingsManager.shared.underlinePresets.first { $0.id == preset.id }?.name ?? ""
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.underlinePresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                SettingsManager.shared.underlinePresets[index].name = newValue
                            }
                        ),
                        color: Binding(
                            get: {
                                SettingsManager.shared.underlinePresets.first { $0.id == preset.id }?.color ?? .black
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.underlinePresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                var updated = SettingsManager.shared.underlinePresets[index]
                                updated.color = newValue
                                SettingsManager.shared.underlinePresets[index] = updated
                            }
                        ),
                        canDelete: settings.underlinePresets.count > 1,
                        onDelete: {
                            guard let index = SettingsManager.shared.underlinePresets.firstIndex(where: { $0.id == preset.id }) else { return }
                            SettingsManager.shared.removeUnderlinePreset(at: index)
                        }
                    )
                }
            } header: {
                HStack {
                    Text("Underline Colors")
                    Spacer()
                    Button(action: { SettingsManager.shared.addUnderlinePreset() }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                            .pageFlowLiquidGlassSurface(.settingsRow)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                ForEach(settings.commentPresets) { preset in
                    PresetRow(
                        name: Binding(
                            get: {
                                SettingsManager.shared.commentPresets.first { $0.id == preset.id }?.name ?? ""
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.commentPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                SettingsManager.shared.commentPresets[index].name = newValue
                            }
                        ),
                        color: Binding(
                            get: {
                                SettingsManager.shared.commentPresets.first { $0.id == preset.id }?.color ?? .gray
                            },
                            set: { newValue in
                                guard let index = SettingsManager.shared.commentPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                                var updated = SettingsManager.shared.commentPresets[index]
                                updated.color = newValue
                                SettingsManager.shared.commentPresets[index] = updated
                            }
                        ),
                        canDelete: settings.commentPresets.count > 1,
                        onDelete: {
                            guard let index = SettingsManager.shared.commentPresets.firstIndex(where: { $0.id == preset.id }) else { return }
                            SettingsManager.shared.removeCommentPreset(at: index)
                        }
                    )
                }
            } header: {
                HStack {
                    Text("Comment Colors")
                    Spacer()
                    Button(action: { SettingsManager.shared.addCommentPreset() }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                            .pageFlowLiquidGlassSurface(.settingsRow)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    SettingsManager.shared.resetColors()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingXS)
                .pageFlowLiquidGlassSurface(.settingsRow)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct PresetRow: View {
    @Binding var name: String
    @Binding var color: NSColor
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            TextField("", text: $name)
                .textFieldStyle(.plain)

            Spacer()

            ColorWellView(color: $color)
                .frame(width: DesignTokens.colorWellWidth, height: DesignTokens.colorWellHeight)

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
                        .frame(width: 20, height: 20)
                        .pageFlowLiquidGlassSurface(.settingsRow.with(strokeOpacity: 0.12))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DesignTokens.presetRowHeight)
    }
}
