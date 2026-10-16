import AppKit

// Classify source edits before AppKit changes the native UTF-16 storage.
extension NativeTextViewCoordinator {
    func editMayChangeBlockStructure(
        in text: NSString,
        affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        if affectedCharRange.location == NSNotFound { return true }
        let replacement = replacementString ?? ""
        if replacement.unicodeScalars.contains(where: isBlockStructuralScalar) {
            return true
        }
        if affectedCharRange.length > 0,
           NSMaxRange(affectedCharRange) <= text.length {
            let removed = text.substring(with: affectedCharRange)
            if removed.unicodeScalars.contains(where: isBlockStructuralScalar) {
                return true
            }
        }
        if editTouchesDoubleDollarDelimiter(
            in: text,
            affectedCharRange: affectedCharRange,
            replacement: replacement
        ) {
            return true
        }
        if replacement.contains(" "),
           spaceCouldCompleteBlockSyntax(at: affectedCharRange.location, in: text) {
            return true
        }
        // An info-string edit keeps the fence's role but changes its block's
        // language, so the block restyles even though no structural scalar moved.
        if let lines = editedLines(in: text, affectedCharRange: affectedCharRange, replacement: replacement),
           !fenceSignatures(lines.before).isEmpty || !fenceSignatures(lines.after).isEmpty {
            return true
        }
        return false
    }

    private func isBlockStructuralScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\n", "\r", "#", "`", "|", ">", "-", "*", "+", "_":
            return true
        default:
            return false
        }
    }

    func editMayRequireFullDocumentRestyle(
        in text: NSString,
        affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let replacement = replacementString ?? ""
        guard let lines = editedLines(in: text, affectedCharRange: affectedCharRange, replacement: replacement) else {
            return true
        }
        // A fence that gains or loses its role (opener vs. possible closer) flips
        // every line below it; typing a language after an opener does not.
        if fenceSignatures(lines.before) != fenceSignatures(lines.after) { return true }
        return editTouchesDoubleDollarDelimiter(
            in: text,
            affectedCharRange: affectedCharRange,
            replacement: replacement
        )
    }

    /// The full lines an edit touches, before and after it applies.
    private func editedLines(
        in text: NSString,
        affectedCharRange: NSRange,
        replacement: String
    ) -> (before: NSString, after: NSString)? {
        guard affectedCharRange.location != NSNotFound,
              affectedCharRange.location >= 0,
              NSMaxRange(affectedCharRange) <= text.length else { return nil }
        let lines = text.lineRange(for: affectedCharRange)
        let before = text.substring(with: lines) as NSString
        let after = NSMutableString(string: before)
        after.replaceCharacters(in: NSRange(location: affectedCharRange.location - lines.location,
                                            length: affectedCharRange.length), with: replacement)
        return (before, after)
    }

    /// What decides each fence line's role in its block: the marker run, and
    /// whether an info string rules it out as a closer.
    private struct FenceSignature: Equatable {
        let character: unichar
        let markerLength: Int
        let hasInfo: Bool
    }

    private func fenceSignatures(_ source: NSString) -> [FenceSignature] {
        var signatures: [FenceSignature] = []
        var location = 0
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            if let opening = FencedCode.opening(in: source, line: line) {
                let info = source.substring(with: opening.info).trimmingCharacters(in: .whitespacesAndNewlines)
                signatures.append(FenceSignature(character: opening.character,
                                                 markerLength: opening.marker.length,
                                                 hasInfo: !info.isEmpty))
            }
            location = NSMaxRange(line)
        }
        return signatures
    }

    private func editTouchesDoubleDollarDelimiter(
        in text: NSString,
        affectedCharRange: NSRange,
        replacement: String
    ) -> Bool {
        guard affectedCharRange.location != NSNotFound else { return true }
        let affectedEnd = affectedCharRange.location + affectedCharRange.length
        guard affectedCharRange.location <= text.length,
              affectedEnd <= text.length else {
            return false
        }

        let replacementHasDollar = replacement.unicodeScalars.contains("$")
        let removedHasDollar = affectedCharRange.length > 0
            && text.substring(with: affectedCharRange).unicodeScalars.contains("$")
        guard replacementHasDollar || removedHasDollar else { return false }

        let oldStart = max(0, affectedCharRange.location - 1)
        let oldEnd = min(text.length, affectedEnd + 1)
        if oldEnd > oldStart {
            let oldWindow = text.substring(with: NSRange(location: oldStart, length: oldEnd - oldStart))
            if oldWindow.contains("$$") { return true }
        }

        let beforeStart = max(0, affectedCharRange.location - 1)
        let beforeLength = affectedCharRange.location - beforeStart
        let before = beforeLength > 0
            ? text.substring(with: NSRange(location: beforeStart, length: beforeLength))
            : ""

        let afterStart = affectedEnd
        let afterEnd = min(text.length, afterStart + 1)
        let after = afterEnd > afterStart
            ? text.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
            : ""

        return (before + replacement + after).contains("$$")
    }

}
