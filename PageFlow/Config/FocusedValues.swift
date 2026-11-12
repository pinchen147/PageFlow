//
//  FocusedValues.swift
//  PageFlow
//
//  Exposes per-window state to menu commands via FocusedValue.
//

import SwiftUI

// MARK: - Focused Value Keys

/// A cached focus value must not own a closed window's manager.
struct FocusedTabManagerReference {
    weak var manager: TabManager?
}

private struct FocusedTabManagerKey: FocusedValueKey {
    typealias Value = FocusedTabManagerReference
}

// MARK: - FocusedValues Extension

extension FocusedValues {
    var tabManagerReference: FocusedTabManagerReference? {
        get { self[FocusedTabManagerKey.self] }
        set { self[FocusedTabManagerKey.self] = newValue }
    }
}
