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

private struct FocusedShowingSearchKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct FocusedSearchFocusRequestKey: FocusedValueKey {
    typealias Value = Binding<Int>
}

private struct FocusedAlwaysOnTopKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

// MARK: - FocusedValues Extension

extension FocusedValues {
    var tabManager: TabManager? {
        get { self[FocusedTabManagerKey.self] }
        set { self[FocusedTabManagerKey.self] = newValue }
    }

    var showingSearch: Binding<Bool>? {
        get { self[FocusedShowingSearchKey.self] }
        set { self[FocusedShowingSearchKey.self] = newValue }
    }

    var searchFocusRequest: Binding<Int>? {
        get { self[FocusedSearchFocusRequestKey.self] }
        set { self[FocusedSearchFocusRequestKey.self] = newValue }
    }

    var alwaysOnTop: Binding<Bool>? {
        get { self[FocusedAlwaysOnTopKey.self] }
        set { self[FocusedAlwaysOnTopKey.self] = newValue }
    }
}
