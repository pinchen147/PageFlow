import AppKit

struct ImageCommandTarget {
    var token: MarkdownToken
    var altRange: NSRange
    var tokens: ImageAltTokens
    var request: EmbeddedImageRequest
    var isEmbed: Bool { token.kind == .imageEmbed }
}

extension NativeTextViewCoordinator {
    /// Reads only the selected token. Image operations never parse the entire note.
    func selectedImageTarget() -> ImageCommandTarget? {
        guard let object = objectSelection else { return nil }
        return imageTarget(for: object)
    }

    /// Resize can target a hovered image while another selection stays active.
    func imageTarget(for object: ObjectSelection) -> ImageCommandTarget? {
        guard let main = textView,
              NSMaxRange(object.token) <= (main.string as NSString).length else { return nil }
        let text = main.string as NSString
        let raw = text.substring(with: object.token)
        guard let local = MarkdownTokenizer.parseTokensViaAST(in: raw, memoizing: false).first(where: {
            ($0.kind == .imageLink || $0.kind == .imageEmbed) && $0.range.location == 0
        }) else { return nil }
        func shift(_ range: NSRange) -> NSRange { NSRange(location: range.location + object.token.location, length: range.length) }
        let token = MarkdownToken(kind: local.kind, range: shift(local.range), contentRange: shift(local.contentRange), markerRanges: local.markerRanges.map(shift))
        if token.kind == .imageEmbed {
            let alt = text.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: alt) else { return nil }
            return ImageCommandTarget(token: token, altRange: token.contentRange, tokens: ImageAltTokens.parse(alt),
                                      request: EmbeddedImageRequest(name: reference.name, id: reference.nodeID?.uuidString, requestedWidth: reference.requestedWidth))
        }
        guard token.markerRanges.count >= 4 else { return nil }
        let start = NSMaxRange(token.markerRanges[0])
        let alt = NSRange(location: start, length: token.markerRanges[1].location - start)
        guard let destination = InlineParser.linkDestination(in: text, openParen: token.markerRanges[2].location) else { return nil }
        return ImageCommandTarget(token: token, altRange: alt, tokens: ImageAltTokens.parse(text.substring(with: alt)), request: EmbeddedImageRequest(name: destination))
    }

    var imageColumnWidth: CGFloat {
        guard let main = textView else { return 672 }
        let width = main.textContainer?.size.width ?? configuration.readingWidth ?? 672
        return max(40, width - 2 * (main.textContainer?.lineFragmentPadding ?? 0))
    }

    /// A single interior edit keeps comment anchors attached and groups all metadata in one undo.
    @discardableResult
    func editImage(_ target: ImageCommandTarget, actionName: String, preservingSelection: Bool = false,
                   change: (inout ImageAltTokens) -> Void) -> Bool {
        guard let main = textView, preservingSelection || objectSelection?.token == target.token.range else { return false }
        var tokens = target.tokens
        change(&tokens)
        let replacement = ImageAltTokens.format(tokens)
        let source = main.string
        let previousAlt = (source as NSString).substring(with: target.altRange)
        guard previousAlt != replacement else { return false }
        let delta = (replacement as NSString).length - target.altRange.length
        let selected: NSRange
        if preservingSelection {
            let previous = main.selectedRange()
            func mapped(_ position: Int) -> Int {
                if position <= target.altRange.location { return position }
                if position >= NSMaxRange(target.altRange) { return position + delta }
                return target.altRange.location + min(position - target.altRange.location, (replacement as NSString).length)
            }
            let start = mapped(previous.location)
            selected = NSRange(location: start, length: max(0, mapped(NSMaxRange(previous)) - start))
        } else {
            selected = NSRange(location: target.token.range.location, length: target.token.range.length + delta)
        }
        let undo = main.undoManager
        let ownsGroup = undo?.groupingLevel == 0
        if ownsGroup { undo?.beginUndoGrouping() }
        // Ordinary metadata stays in one paragraph (§12.4). Imported alt text
        // can contain Unicode separators that a description edit sanitizes away;
        // keep the full paragraph-chain repair for those exceptional sources.
        let reflowsParagraphChain = previousAlt.rangeOfCharacter(from: .newlines) != nil
            || replacement.rangeOfCharacter(from: .newlines) != nil
        let written = replaceSourceRanges([target.altRange], with: replacement, expectedSource: source,
                                          actionName: actionName, reflowsParagraphChain: reflowsParagraphChain,
                                          selectionAfter: selected)
        if ownsGroup { undo?.endUndoGrouping() }
        if written {
            // didChangeText schedules the normal trailing-edge publication.
            // Keep pointer input local; save/close flush the authoritative native
            // source through MarkdownEditorController.commitPendingText().
            #if DEBUG
            let selectionStart = CFAbsoluteTimeGetCurrent()
            #endif
            if !preservingSelection {
                if let image = Self.renderedImage(around: selected, in: main.textStorage!) { selectImage(image, in: main) }
                main.window?.makeFirstResponder(main)
            }
            selectionBar?.setNeedsUpdate()
            #if DEBUG
            PerfTrace.add("image.edit.selection", since: selectionStart)
            #endif
        }
        return written
    }

    func setImageAlignment(_ alignment: ImageAltTokens.Alignment) {
        guard let target = selectedImageTarget() else { return }
        editImage(target, actionName: "Align Image") { $0.alignment = alignment }
    }

    func setImageDescription(_ description: String) {
        guard let target = selectedImageTarget(), !target.isEmbed else { return }
        let sanitized = ImageAltTokens.sanitizedDescription(description)
        guard !sanitized.isEmpty else { return }
        if editImage(target, actionName: "Edit Alt Text", change: { $0.description = sanitized }) {
            MarkdownTableEditingSession.announce("Alt text saved")
        }
    }

    func setImageWidth(_ width: CGFloat, actionName: String) {
        guard let target = selectedImageTarget() else { return }
        setImageWidth(width, for: target, actionName: actionName)
    }

    func setImageWidth(_ width: CGFloat, for target: ImageCommandTarget, actionName: String,
                       preservingSelection: Bool = false) {
        let clamped = min(max(width.rounded(), 40), imageColumnWidth)
        editImage(target, actionName: actionName, preservingSelection: preservingSelection) { $0.width = clamped }
    }

    func applyImageCrop(_ rect: CGRect, fullWidth: CGFloat) {
        guard let target = selectedImageTarget() else { return }
        let full = ImageAltTokens.isFullRect(rect)
        let width = min(max((fullWidth * rect.width).rounded(), 40), imageColumnWidth)
        editImage(target, actionName: "Crop Image") { $0.crop = full ? nil : rect; $0.width = width }
        selectionBar?.suppressImageUntilClick()
        MarkdownTableEditingSession.announce(full ? "Crop removed" : "Image cropped")
    }

    func copySelectedImage(to pasteboard: NSPasteboard = .general) {
        guard let target = selectedImageTarget(),
              let image = configuration.services.images.fullResolutionImage(for: target.request)
                ?? configuration.services.images.image(for: target.request),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let result: CGImage
        if let crop = target.tokens.crop {
            let rect = CGRect(x: crop.minX * CGFloat(cg.width), y: crop.minY * CGFloat(cg.height), width: crop.width * CGFloat(cg.width), height: crop.height * CGFloat(cg.height))
            guard let cropped = cg.cropping(to: rect) else { return }
            result = cropped
        } else { result = cg }
        let bitmap = NSBitmapImageRep(cgImage: result)
        pasteboard.clearContents()
        if let png = bitmap.representation(using: .png, properties: [:]) { pasteboard.setData(png, forType: .png) }
        if let tiff = bitmap.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }
}
