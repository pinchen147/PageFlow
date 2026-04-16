//
//  URL+PageFlowDocumentIdentity.swift
//  PageFlow
//
//  Canonical file URL helpers for document identity comparisons.
//

import Foundation

extension URL {
    var pageFlowCanonicalDocumentURL: URL {
        guard isFileURL else { return self }
        return standardizedFileURL.resolvingSymlinksInPath()
    }
}
