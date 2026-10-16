//
//  FocusedValues.swift
//  PageFlow
//
//  Exposes per-window state to menu commands via FocusedValue.
//

import SwiftUI

// MARK: - Focused Value Keys

private struct FocusedTabManagerKey: FocusedValueKey {
    typealias Value = TabManager
}

// MARK: - FocusedValues Extension

extension FocusedValues {
    var tabManager: TabManager? {
        get { self[FocusedTabManagerKey.self] }
        set { self[FocusedTabManagerKey.self] = newValue }
    }
}
