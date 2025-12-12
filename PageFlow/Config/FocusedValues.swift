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

private struct FocusedShowingOutlineKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct FocusedShowingCommentsKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct FocusedShowingGoToPageKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct FocusedShowingFileImporterKey: FocusedValueKey {
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

    var showingOutline: Binding<Bool>? {
        get { self[FocusedShowingOutlineKey.self] }
        set { self[FocusedShowingOutlineKey.self] = newValue }
    }

    var showingComments: Binding<Bool>? {
        get { self[FocusedShowingCommentsKey.self] }
        set { self[FocusedShowingCommentsKey.self] = newValue }
    }

    var showingGoToPage: Binding<Bool>? {
        get { self[FocusedShowingGoToPageKey.self] }
        set { self[FocusedShowingGoToPageKey.self] = newValue }
    }

    var showingFileImporter: Binding<Bool>? {
        get { self[FocusedShowingFileImporterKey.self] }
        set { self[FocusedShowingFileImporterKey.self] = newValue }
    }
}
