import Foundation
import os.log

/// Local recovery copies, independent of the user's original files.
nonisolated final class MarkdownRecoveryStore: @unchecked Sendable {
    struct Record: Codable, Sendable {
        var id: UUID
        var title: String
        var originalURL: URL?
        var source: String
        /// New records keep the exact native body separate; nil reads legacy joined sources.
        var commentBlock: String? = nil
        var updatedAt: Date
    }

    static let shared: MarkdownRecoveryStore = {
        #if DEBUG
        if let directory = RecoveryQA.directory { return MarkdownRecoveryStore(directory: directory) }
        #endif
        return MarkdownRecoveryStore(directory: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("PageFlow/Recovery", isDirectory: true))
    }()

    let directory: URL
    private let queue = DispatchQueue(label: "com.pageflow.markdown-recovery", qos: .utility)
    private enum Pending {
        case checkpoint(Record, (@Sendable (String) -> Void)?)
        case remove
    }
    private let admissionLock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var drainScheduled = false
    private var lastRecords: [UUID: Record] = [:]
    private let logger = Logger(subsystem: "com.pageflow", category: "MarkdownRecovery")
    init(directory: URL) { self.directory = directory }
    /// Admission is synchronous; the serial writer orders saves and removals
    /// even when an editor closes before its last checkpoint reaches disk.
    func checkpoint(_ record: Record, onFailure: (@Sendable (String) -> Void)? = nil) {
        enqueue(.checkpoint(record, onFailure), for: record.id)
    }

    func remove(_ id: UUID) { enqueue(.remove, for: id) }

    /// Only the newest pending intent for a document survives a slow writer.
    /// A removal supersedes queued checkpoints; a later live edit may replace it.
    private func enqueue(_ operation: Pending, for id: UUID) {
        admissionLock.lock()
        pending[id] = operation
        if !drainScheduled {
            drainScheduled = true
            queue.async { [self] in drain() }
        }
        admissionLock.unlock()
    }

    private func drain() {
        while true {
            admissionLock.lock()
            guard !pending.isEmpty else {
                drainScheduled = false
                admissionLock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            admissionLock.unlock()
            for (id, operation) in batch {
                switch operation {
                case .checkpoint(let record, let onFailure): write(record, onFailure: onFailure)
                case .remove: removeFromDisk(id)
                }
            }
        }
    }

    private func write(_ record: Record, onFailure: (@Sendable (String) -> Void)?) {
        if let previous = lastRecords[record.id], previous.originalURL == record.originalURL,
           previous.title == record.title, previous.source.hasSameSource(as: record.source) {
            switch (previous.commentBlock, record.commentBlock) {
            case (nil, nil): return
            case let (old?, new?) where old.hasSameSource(as: new): return
            default: break
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = fileURL(record.id)
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastRecords[record.id] = record
        } catch {
            logger.error("Could not checkpoint a Markdown recovery copy: \(error.localizedDescription)")
            onFailure?("Couldn’t save a recovery copy. Save this note to protect your changes.")
        }
    }

    private func removeFromDisk(_ id: UUID) {
        let url = fileURL(id)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            lastRecords.removeValue(forKey: id)
        } catch {
            logger.error("Could not remove a Markdown recovery copy: \(error.localizedDescription)")
        }
    }

    /// Close/quit fences already-admitted work; ordinary typing never waits for I/O.
    func flush() { queue.sync {} }

    func load() async -> [Record] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                )) ?? []
                let records = files.filter { $0.pathExtension == "json" }.compactMap { url -> Record? in
                    do {
                        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
                        guard url.lastPathComponent == fileURL(record.id).lastPathComponent else { return nil }
                        return record
                    } catch {
                        logger.error("Could not read a Markdown recovery copy: \(error.localizedDescription)")
                        return nil
                    }
                }.sorted { $0.updatedAt < $1.updatedAt }
                continuation.resume(returning: records)
            }
        }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }
}
