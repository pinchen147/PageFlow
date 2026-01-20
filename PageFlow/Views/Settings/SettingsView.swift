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
        .background(WindowAccessor())
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.standardWindowButton(.closeButton)?.keyEquivalent = "\u{1b}" // Escape
                window.standardWindowButton(.closeButton)?.keyEquivalentModifierMask = []
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
