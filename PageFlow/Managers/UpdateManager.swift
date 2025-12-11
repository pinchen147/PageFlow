//
//  UpdateManager.swift
//  PageFlow
//
//  Created by Claude Code on 12/12/25.
//

import Foundation

#if ENABLE_SPARKLE
import Sparkle
#endif

/// Manages app updates via Sparkle. Only active when ENABLE_SPARKLE is defined.
@Observable
final class UpdateManager {
    #if ENABLE_SPARKLE
    private let updaterController: SPUStandardUpdaterController

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
    #else
    var canCheckForUpdates: Bool { false }
    #endif

    init() {
        #if ENABLE_SPARKLE
        // startingUpdater: true enables automatic update checks on launch
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
    }

    /// Manually triggers an update check.
    func checkForUpdates() {
        #if ENABLE_SPARKLE
        updaterController.checkForUpdates(nil)
        #endif
    }
}
