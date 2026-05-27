//
//  SettingsView.swift
//  PageFlow
//
//  Main settings window with tabbed interface
//

import SwiftUI
import AppKit

struct SettingsView: View {
    private enum Tab: Hashable {
        case general
        case annotations
        case shortcuts
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tab.general)

            AnnotationsSettingsTab()
                .tabItem {
                    Label("Annotations", systemImage: "highlighter")
                }
                .tag(Tab.annotations)

            ShortcutsSettingsTab()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(Tab.shortcuts)
        }
        .frame(width: DesignTokens.settingsWindowWidth, height: DesignTokens.settingsWindowHeight)
        .background(SettingsWindowAccessor())
    }
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowAccessorView {
        SettingsWindowAccessorView()
    }

    func updateNSView(_ nsView: SettingsWindowAccessorView, context: Context) {
        nsView.configureWindowIfNeeded()
    }
}

private final class SettingsWindowAccessorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let closeButton = window?.standardWindowButton(.closeButton),
              closeButton.keyEquivalent != "\u{1b}" else {
            return
        }

        closeButton.keyEquivalent = "\u{1b}" // Escape
        closeButton.keyEquivalentModifierMask = []
    }
}
