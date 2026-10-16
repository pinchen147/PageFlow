//
//  TitlebarDoubleClick.swift
//  PageFlow
//
//  The pure decision of what a titlebar double-click performs, from the
//  user's System Settings choice.
//

import Foundation

/// Maps the system preference behind System Settings > Desktop & Dock >
/// "Double-click a window's title bar to ..." (NSGlobalDomain key
/// `AppleActionOnDoubleClick`) onto the action a custom titlebar performs.
/// There is no public AppKit API that performs "the configured action";
/// custom-chrome apps (Chromium, iTerm2) read the default and switch — so
/// does PageFlow. Pure, so the mapping is table-tested.
enum TitlebarDoubleClick {
    enum Action: Equatable {
        case zoom
        case minimize
        case fill
        case none
    }

    /// An absent key means the macOS default, Zoom ("Maximize" is the raw
    /// value the setting writes for Zoom). Unknown future values resolve to
    /// `.none` — doing nothing is safer than guessing.
    static func action(for preference: String?) -> Action {
        switch preference {
        case nil, "Maximize": return .zoom
        case "Minimize": return .minimize
        case "Fill": return .fill
        case "None": return .none
        default: return .none
        }
    }
}
