import Foundation
import ZIPFoundation

final class ArchiveReader {
    private let archive: Archive
    private let entries: [String: Entry]
    private var expandedBytes = 0
    private let expandedLimit: Int
    /// The book's stylesheets, shared by every reader of it.
    let stylesheets: EPUBStylesheets

    init(url: URL, expandedLimit: Int = 256 * 1024 * 1024, stylesheets: EPUBStylesheets = EPUBStylesheets()) throws {
        self.expandedLimit = expandedLimit
        self.stylesheets = stylesheets
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: .utf8)
        } catch {
            throw EPUBError.unreadableArchive
        }
        var indexed: [String: Entry] = [:]
        for entry in archive where entry.type == .file {
            guard indexed.count < 10_000 else { throw EPUBError.resourceLimit }
            // An entry whose name can't be addressed (e.g. a literal "%")
            // is unreachable from the package, so skip it; only a genuinely
            // ambiguous duplicate makes the archive untrustworthy.
            guard let path = ArchivePath.normalized(entry.path), path == entry.path else { continue }
            guard indexed[path] == nil else { throw EPUBError.unreadableArchive }
            indexed[path] = entry
        }
        entries = indexed
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    /// How many files the archive holds.
    var entryCount: Int { entries.count }

    /// An entry's size once inflated.
    func size(of path: String) -> Int? { entries[path].map { Int($0.uncompressedSize) } }

    func read(_ path: String, limit: Int) throws -> Data {
        guard let normalized = ArchivePath.normalized(path), normalized == path,
              let entry = entries[path] else {
            throw EPUBError.missingResource(path)
        }
        guard entry.uncompressedSize <= UInt32(limit),
              expandedBytes <= expandedLimit - Int(entry.uncompressedSize) else {
            throw EPUBError.resourceLimit
        }
        var data = Data()
        do {
            _ = try archive.extract(entry, bufferSize: 64 * 1024, skipCRC32: false) { chunk in
                guard data.count <= limit - chunk.count else { throw EPUBError.resourceLimit }
                data.append(chunk)
            }
        } catch let error as EPUBError {
            throw error
        } catch {
            throw EPUBError.invalidContent(path)
        }
        expandedBytes += data.count
        return data
    }

    /// Writes an entry no larger than `limit` to a new file at `url`, for one
    /// too large to hold in memory. A cancelled task stops it.
    func extract(_ path: String, to url: URL, limit: Int) throws {
        guard let entry = entries[path] else { throw EPUBError.missingResource(path) }
        guard entry.uncompressedSize <= limit else { throw EPUBError.resourceLimit }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw EPUBError.invalidContent(path) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var written = 0
        _ = try archive.extract(entry, bufferSize: 256 * 1024, skipCRC32: false) { chunk in
            try Task.checkCancellation()
            written += chunk.count
            guard written <= limit else { throw EPUBError.resourceLimit }
            try file.write(contentsOf: chunk)
        }
    }

    /// The first `length` bytes of an entry no larger than `limit` (or all of
    /// a shorter one), so an image's header is read without inflating it.
    func readPrefix(_ path: String, length: Int, limit: Int) throws -> Data {
        guard let entry = entries[path], Int(entry.uncompressedSize) > length else {
            return try read(path, limit: length)
        }
        guard entry.uncompressedSize <= UInt32(limit) else { throw EPUBError.resourceLimit }
        struct Enough: Error {}
        var data = Data()
        do {
            _ = try archive.extract(entry, bufferSize: 16 * 1024, skipCRC32: true) { chunk in
                data.append(chunk)
                if data.count >= length { throw Enough() }
            }
        } catch is Enough {
        } catch {
            throw EPUBError.invalidContent(path)
        }
        expandedBytes += data.count
        return data
    }
}

enum ArchivePath {
    static func normalized(_ raw: String, relativeTo base: String? = nil) -> String? {
        guard let decoded = raw.removingPercentEncoding, !decoded.isEmpty,
              !decoded.hasPrefix("/"), !decoded.contains("\\"),
              !decoded.contains("\0") else { return nil }
        let path = base.map { "\($0)/\(decoded)" } ?? decoded
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
