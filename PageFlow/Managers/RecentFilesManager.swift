//
//  RecentFilesManager.swift
//  PageFlow
//
//  Manages recently opened PDF files with UserDefaults persistence
//

import Foundation
import Observation
import os.log

@Observable
@MainActor
final class RecentFilesManager {
    private let logger = Logger(subsystem: "com.pageflow", category: "RecentFilesManager")
    private let maxRecentFiles = 10
    private let recentFilesKey = "recentFiles"
    private let defaults = UserDefaults.standard

    var recentFiles: [URL] = []

    init() {
        loadRecentFiles()
    }

    func addRecentFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else { return }

        var updatedFiles = recentFiles.filter { $0 != url }
        updatedFiles.insert(url, at: 0)

        if updatedFiles.count > maxRecentFiles {
            updatedFiles = Array(updatedFiles.prefix(maxRecentFiles))
        }

        recentFiles = updatedFiles
        saveRecentFiles()
    }

    func clearRecentFiles() {
        recentFiles = []
        defaults.removeObject(forKey: recentFilesKey)
    }

    private func loadRecentFiles() {
        guard let data = defaults.data(forKey: recentFilesKey) else { return }

        do {
            let urls = try JSONDecoder().decode([URL].self, from: data)
            recentFiles = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        } catch {
            logger.error("Failed to decode recent files: \(error.localizedDescription)")
        }
    }

    private func saveRecentFiles() {
        do {
            let data = try JSONEncoder().encode(recentFiles)
            defaults.set(data, forKey: recentFilesKey)
        } catch {
            logger.error("Failed to encode recent files: \(error.localizedDescription)")
        }
    }
}
