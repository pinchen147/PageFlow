import Foundation

/// PDF open parameters use one-based page numbers; model navigation is zero-based.
nonisolated enum PDFPageLink {
    static func pageIndex(in fragment: String?) -> Int? {
        guard let fragment,
              let items = URLComponents(string: "?" + fragment)?.queryItems else { return nil }
        let pages = items.filter { $0.name == "page" }
        guard pages.count == 1, let value = pages[0].value, !value.isEmpty,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let page = Int(value), page > 0 else { return nil }
        return page - 1
    }
}
