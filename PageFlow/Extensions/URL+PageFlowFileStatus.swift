//
//  URL+PageFlowFileStatus.swift
//  PageFlow
//
//  Cheap questions an open asks before reading a file's bytes, and the one
//  blocking step that brings a cloud-only file's bytes onto the disk.
//

import Foundation

extension URL {
    /// The file is on a volume that isn't mounted now: an unplugged drive or a
    /// share. Its absence says nothing about the file, unlike one missing from a
    /// mounted volume, which is really gone. `mountedVolumeURLs` answers in the sandbox.
    nonisolated var pageFlowVolumeIsOffline: Bool {
        let components = standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return false }
        let root = "/Volumes/\(components[2])"
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return !mounted.contains { $0.path == root } && !FileManager.default.fileExists(atPath: root)
    }

    /// The file's bytes live only with its cloud provider (iCloud Drive, a File
    /// Provider). Reading it downloads first, which can take a long time
    /// (TN3150); `stat` reports the flag without starting that download.
    var pageFlowIsDataless: Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// The file's logical size in bytes, without reading or downloading it.
    var pageFlowFileSize: Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    /// Downloads a cloud-only file: a coordinated read waits until its bytes are
    /// local. Blocking, so call it off the main thread. Returns whether the file
    /// can now be read.
    nonisolated func pageFlowDownloadContents(isSecurityScoped: Bool) -> Bool {
        let scoped = isSecurityScoped && startAccessingSecurityScopedResource()
        defer { if scoped { stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var readable = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: self, options: [], error: &coordinationError
        ) { local in
            readable = FileManager.default.isReadableFile(atPath: local.path)
        }
        return coordinationError == nil && readable
    }
}
