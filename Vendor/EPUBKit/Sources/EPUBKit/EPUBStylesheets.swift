import Foundation

/// A book's stylesheets, read and parsed once for all its chapters. One sheet
/// is commonly linked by every chapter and can run to hundreds of kilobytes,
/// and parsing it would otherwise cost more than rendering the chapter.
/// Chapters rendering on different threads share this.
final class EPUBStylesheets: @unchecked Sendable {
    /// Bytes kept while the book is read: past this, sheets are read and parsed
    /// each time rather than held.
    static let openLimit = 16 * 1024 * 1024
    /// Bytes kept while it is out of sight, however many chapters style then.
    /// A 220 KB sheet costs about 2.2 MB here and 37 ms (Release) to parse again.
    static let hiddenLimit = 4 * 1024 * 1024
    /// An image rule takes about this many times the bytes of its text (a
    /// 220 KB sheet's rules measured 1.8 MB).
    private static let parsedImageRulesFactor = 8

    private let parse: (String) -> [CSSRules.Rule]
    private let parseImageRules: (String) -> EPUBFixedCSS
    private let limits: (open: Int, hidden: Int)
    private let lock = NSLock()
    // Guarded by `lock`, never held while reading or parsing: a far page styled
    // on the main thread must not wait behind a background chapter's parse. Two
    // chapters asking at once may each parse, which costs less than that wait.
    private var texts: [String: String] = [:]
    private var writingRules: [String: [CSSRules.Rule]] = [:]
    /// By sheet, so chapters sharing a big sheet beside their own `<style>`
    /// parse it once.
    private var imageRules: [String: EPUBFixedCSS] = [:]
    /// The last chapter's rules put together; chapters commonly link the same.
    private var lastImageCSS: (sheets: [String], css: EPUBFixedCSS)?
    private var limit: Int
    private(set) var retained = 0

    init(parse: @escaping (String) -> [CSSRules.Rule] = CSSRules.writingRules,
         parseImageRules: @escaping (String) -> EPUBFixedCSS = EPUBStylesheets.imageRules,
         openLimit: Int = EPUBStylesheets.openLimit, hiddenLimit: Int = EPUBStylesheets.hiddenLimit) {
        self.parse = parse
        self.parseImageRules = parseImageRules
        limits = (openLimit, hiddenLimit)
        limit = openLimit
    }

    private static func imageRules(in sheet: String) -> EPUBFixedCSS {
        var css = EPUBFixedCSS()
        css.add(sheet, directory: "")
        return css
    }

    /// The sheet at `path`, read with `read` the first time.
    func text(at path: String, read: () -> Data?) -> String? {
        if let known = lock.withLock({ texts[path] }) { return known }
        guard let data = read() else { return nil }
        // The keywords are ASCII whatever the file's encoding.
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock {
            if texts[path] == nil, retain(text.utf8.count) { texts[path] = text }
        }
        return text
    }

    /// What a sheet says about writing.
    func writingRules(in css: String) -> [CSSRules.Rule] {
        if let known = lock.withLock({ writingRules[css] }) { return known }
        let parsed = parse(css)
        lock.withLock {
            if writingRules[css] == nil, retain(css.utf8.count) { writingRules[css] = parsed }
        }
        return parsed
    }

    /// A chapter's sheets, read for what they say of its images' sizes.
    func imageCSS(for sheets: [String]) -> EPUBFixedCSS {
        if let last = lock.withLock({ lastImageCSS }), last.sheets == sheets { return last.css }
        var css = EPUBFixedCSS()
        var allKept = true
        for sheet in sheets {
            if let known = lock.withLock({ imageRules[sheet] }) {
                css.append(known)
                continue
            }
            let parsed = parseImageRules(sheet)
            css.append(parsed)
            lock.withLock {
                if imageRules[sheet] == nil {
                    if retain(sheet.utf8.count * Self.parsedImageRulesFactor) { imageRules[sheet] = parsed } else { allKept = false }
                }
            }
        }
        // One of these at a time: it holds nothing the rules above don't, but
        // its own list of them, so a sheet not kept isn't kept this way either.
        if allKept { lock.withLock { lastImageCSS = (sheets, css) } }
        return css
    }

    /// Whether the sheet at `path` would be read and parsed anew.
    func holds(_ path: String) -> Bool { lock.withLock { texts[path] != nil } }

    /// The book goes out of sight: a book's usual few sheets stay, so showing
    /// it again has nothing to parse; anything more goes, and what a pass still
    /// running reads from now on isn't kept past that either.
    func shrink() {
        lock.withLock {
            limit = limits.hidden
            guard retained > limit else { return }
            texts = [:]
            writingRules = [:]
            imageRules = [:]
            lastImageCSS = nil
            retained = 0
        }
    }

    /// The book is being read again.
    func grow() { lock.withLock { limit = limits.open } }

    private func retain(_ size: Int) -> Bool {
        guard retained + size <= limit else { return false }
        retained += size
        return true
    }
}
