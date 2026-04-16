//
//  RecentFilesManager.swift
//  PageFlow
//
//  Manages recently opened PDF files with UserDefaults persistence
//

import Foundation
import Observation
import os.log

struct RecentFile: Identifiable, Codable, Hashable {
    let url: URL
    let securityScopedBookmarkData: Data?

    var id: String {
        url.pageFlowCanonicalDocumentURL.path
    }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

struct ResolvedRecentFile {
    let url: URL
    let isSecurityScoped: Bool
}

@Observable
@MainActor
final class RecentFilesManager {
    private let logger = Logger(subsystem: "com.pageflow", category: "RecentFilesManager")
    private let maxRecentFiles = 10
    private let recentFilesKey = "recentFiles"
    private let defaults: UserDefaults

    var recentFiles: [RecentFile] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadRecentFiles()
    }

    func addRecentFile(_ url: URL, isSecurityScoped: Bool = false) {
        guard url.pathExtension.lowercased() == "pdf" else { return }

        let canonicalURL = url.pageFlowCanonicalDocumentURL
        let recentFile = RecentFile(
            url: url,
            securityScopedBookmarkData: bookmarkData(for: url, isSecurityScoped: isSecurityScoped)
        )

        var updatedFiles = recentFiles.filter { $0.url.pageFlowCanonicalDocumentURL != canonicalURL }
        updatedFiles.insert(recentFile, at: 0)

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

    func resolveRecentFile(_ recentFile: RecentFile) -> ResolvedRecentFile? {
        if let bookmarkData = recentFile.securityScopedBookmarkData {
            do {
                var isStale = false
                let resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ).pageFlowCanonicalDocumentURL

                guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                    removeRecentFile(recentFile)
                    return nil
                }

                if isStale {
                    refreshBookmarkData(for: recentFile, resolvedURL: resolvedURL)
                }

                return ResolvedRecentFile(url: resolvedURL, isSecurityScoped: true)
            } catch {
                logger.error("Failed to resolve recent file bookmark: \(error.localizedDescription)")
                removeRecentFile(recentFile)
                return nil
            }
        }

        let resolvedURL = recentFile.url.pageFlowCanonicalDocumentURL
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            removeRecentFile(recentFile)
            return nil
        }

        return ResolvedRecentFile(url: resolvedURL, isSecurityScoped: false)
    }

    private func loadRecentFiles() {
        guard let data = defaults.data(forKey: recentFilesKey) else { return }

        do {
            let decodedFiles = try JSONDecoder().decode([RecentFile].self, from: data)
            recentFiles = decodedFiles.filter(shouldRetainRecentFile)
        } catch {
            do {
                let legacyURLs = try JSONDecoder().decode([URL].self, from: data)
                recentFiles = legacyURLs
                    .map { RecentFile(url: $0.pageFlowCanonicalDocumentURL, securityScopedBookmarkData: nil) }
                    .filter { FileManager.default.fileExists(atPath: $0.url.path) }
                saveRecentFiles()
            } catch {
                logger.error("Failed to decode recent files: \(error.localizedDescription)")
            }
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

    private func bookmarkData(for url: URL, isSecurityScoped: Bool) -> Data? {
        guard url.isFileURL else { return nil }

        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            if isSecurityScoped {
                logger.error("Failed to create security-scoped bookmark: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func refreshBookmarkData(for recentFile: RecentFile, resolvedURL: URL) {
        guard let index = recentFiles.firstIndex(where: { $0.id == recentFile.id }) else { return }

        recentFiles[index] = RecentFile(
            url: resolvedURL,
            securityScopedBookmarkData: bookmarkData(for: resolvedURL, isSecurityScoped: true)
        )
        saveRecentFiles()
    }

    private func removeRecentFile(_ recentFile: RecentFile) {
        recentFiles.removeAll { $0.id == recentFile.id }
        saveRecentFiles()
    }

    private func shouldRetainRecentFile(_ recentFile: RecentFile) -> Bool {
        if recentFile.securityScopedBookmarkData != nil {
            return true
        }

        return FileManager.default.fileExists(atPath: recentFile.url.path)
    }
}
