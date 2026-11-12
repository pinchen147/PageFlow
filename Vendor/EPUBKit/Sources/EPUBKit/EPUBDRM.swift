import Foundation

/// Tells a DRM-protected book from one that only obfuscates its fonts.
enum DRMDetector {
    /// Font obfuscation (IDPF and Adobe) hides embedded fonts, not text;
    /// such books read normally.
    static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC"
    ]

    /// Files only a protected book carries: Apple FairPlay's sinf and a
    /// Readium LCP license.
    static func rejectProtectedMarkers(in archive: ArchiveReader) throws {
        if archive.contains("META-INF/sinf.xml") || archive.contains("META-INF/license.lcpl") {
            throw EPUBError.drmProtected
        }
    }

    /// Any encryption other than font obfuscation on a spine document means
    /// the text can't be read.
    static func rejectEncryptedContent(in archive: ArchiveReader, package: ParsedPackage) throws {
        guard archive.contains("META-INF/encryption.xml"),
              let data = try? archive.read("META-INF/encryption.xml", limit: 4 * 1024 * 1024),
              let document = try? XMLDocumentParser.parse(data) else { return }
        let documents = Set(package.spine.map(\.path))
            .union(package.manifest.values.filter { $0.mediaType == "application/xhtml+xml" }.map(\.path))
        for encrypted in document.elements(named: "EncryptedData") {
            let algorithm = encrypted.firstDescendant(named: "EncryptionMethod")?.attribute(named: "Algorithm") ?? ""
            guard !fontObfuscation.contains(algorithm),
                  let uri = encrypted.firstDescendant(named: "CipherReference")?.attribute(named: "URI"),
                  let path = ArchivePath.normalized(uri.removingFragment) else { continue }
            if documents.contains(path) { throw EPUBError.drmProtected }
        }
    }
}
