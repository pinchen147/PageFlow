#if DEBUG
import AppKit
import Darwin
import MarkdownEngine

@MainActor
enum ImageControlsQA {
    struct Result {
        var failures: [String] = []
        var gestures = 0
        var samples = 0
        var maxShift = 0.0
        var slowestMilliseconds = 0.0
        var hoverMilliseconds: Double?
        // Whole native handlers, including setup/commit; never per-frame claims.
        var resizeGestureMilliseconds: Double?
        var cropGestureMilliseconds: Double?
        var notes: [String] = []
        var manualCases: [String] = [
            "Resize frame <=8ms and crop frame <=4ms require frame instrumentation; aggregate gesture times do not qualify them.",
            "Physical pointer input, VoiceOver navigation, IME marked text, narrow/zoomed layout and full menu copy/size/delete cases require manual qualification.",
            "Hover zero-layout-pass verification requires layout instrumentation; the native handler timing and zero-storage-edit check do not establish it."
        ]
    }

    /// One bounded pass through native controls. Never repeats gestures for timing.
    static func run(textView: NSTextView, window: NSWindow, lineY _: (Int) -> Double?) async -> Result {
        var result = Result()
        guard !QAPresentation.runsInBackground else {
            result.failures.append("Image controls require a native key window; background QA stops before activation or input. Foreground qualification remains pending separate owner approval.")
            return result
        }
        let original = textView.string
        let originalUTF16 = Array(original.utf16)
        var sourceCheckBuffer = [UInt16](repeating: 0, count: originalUTF16.count)
        func matchesOriginalSource() -> Bool {
            let current = textView.string as NSString
            guard current.length == originalUTF16.count else { return false }
            guard !originalUTF16.isEmpty else { return true }
            // Native bulk extraction avoids Swift UTF16 iteration over the full
            // fixture inside every synchronous attribute-preview notification.
            return sourceCheckBuffer.withUnsafeMutableBufferPointer { actual in
                current.getCharacters(actual.baseAddress!, range: NSRange(location: 0, length: current.length))
                return originalUTF16.withUnsafeBufferPointer { expected in
                    memcmp(actual.baseAddress!, expected.baseAddress!, expected.count * MemoryLayout<UInt16>.stride) == 0
                }
            }
        }
        // Swift String equality folds canonical-equivalent Unicode. Source and
        // Undo qualification require the exact original UTF16 sequence.
        func sameSource(_ lhs: String, _ rhs: String) -> Bool {
            lhs.utf16.elementsEqual(rhs.utf16)
        }
        guard let storage = textView.textStorage, let scroll = textView.enclosingScrollView else {
            result.failures.append("Image controls require native storage and a scroll view")
            return result
        }
        // Long notes style only the viewport. Find the source first, then seat that
        // paragraph before requiring its rendered-image attributes.
        let sourcePrefix = (original as NSString).substring(to: min((original as NSString).length, 12_000))
        let expression = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(!\[(?!\[)[^\r\n]*\]\([^\r\n]*\))[ \t]*$"#)
        let matches = expression?.matches(in: sourcePrefix, range: NSRange(location: 0, length: sourcePrefix.utf16.count)) ?? []
        // Stacked images cannot supply a readable witness in the same viewport.
        // Select an uncropped image immediately followed by actual prose instead.
        let match = matches.first { match in
            let token = (sourcePrefix as NSString).substring(with: match.range(at: 1))
            guard !token.contains("crop=") else { return false }
            let following = (sourcePrefix as NSString).substring(from: NSMaxRange(match.range))
            guard let line = following.split(whereSeparator: \.isNewline).first(where: {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }), let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
            return first.isLetter || first.isNumber
        }
        guard let match else {
            result.failures.append("No uncropped source image followed by prose near the start of the fixture (editor length \(storage.length))")
            return result
        }
        let candidate = match.range(at: 1)
        let followingStart = NSMaxRange(match.range)
        let following = (sourcePrefix as NSString).substring(from: followingStart)
        let firstProseCharacter = (following as NSString).range(of: #"\S"#, options: .regularExpression)
        guard firstProseCharacter.location != NSNotFound else {
            result.failures.append("Selected image has no following prose source location")
            return result
        }
        let proseOffset = followingStart + firstProseCharacter.location
        let proseParagraph = (original as NSString).paragraphRange(for: NSRange(location: proseOffset, length: 0))
        // Seat the fixture in a usable native viewport before focus/layout.
        // Keep the entire test window inside the available display rectangle.
        if let available = (window.screen ?? NSScreen.main)?.visibleFrame {
            var frame = window.frame
            frame.size.width = min(available.width, max(frame.width, 900))
            frame.size.height = min(available.height, max(frame.height, 820))
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
            window.setFrame(frame, display: true, animate: false)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        QAPresentation.activateIfAllowed()
        QAPresentation.show(window)
        let activationDeadline = ProcessInfo.processInfo.systemUptime + 1.5
        while (!NSApp.isActive || !window.isKeyWindow), ProcessInfo.processInfo.systemUptime < activationDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSApp.isActive, window.isKeyWindow else {
            result.failures.append("Image setup could not activate the target app/window: active=\(NSApp.isActive), key=\(window.isKeyWindow), canBecomeKey=\(window.canBecomeKey), visible=\(window.isVisible)")
            return result
        }
        // AppKit may enqueue caret reveal while taking focus. Make its actual
        // destination the same ordinary prose location as the seating request.
        textView.setSelectedRange(NSRange(location: proseOffset, length: 0))
        guard window.makeFirstResponder(textView) else {
            result.failures.append("Image setup could not focus the target editor")
            return result
        }
        scroll.layoutSubtreeIfNeeded()
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try? await Task.sleep(for: .milliseconds(80))
        // A restyle can suppress one automatic reveal. Two bounded readiness
        // passes consume that suppression and settle estimates at the same caret;
        // no gesture or interaction timing is retried here.
        for _ in 0..<2 {
            textView.scrollRangeToVisible(NSRange(location: proseOffset, length: 0))
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            try? await Task.sleep(for: .milliseconds(160))
            if let visibleProse = ReadableTextLineProbe.capture(in: textView, minimumLocation: proseOffset),
               visibleProse.range.location < NSMaxRange(proseParagraph),
               !String(decoding: visibleProse.sourceUTF16, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
        }
        guard matchesOriginalSource() else {
            result.failures.append("Native fixture seating changed the source")
            return result
        }
        var token: NSRange?
        var imageAnchor: Int?
        storage.enumerateAttribute(NSAttributedString.Key("MarkdownBlockSourceRange"), in: candidate) { value, run, stop in
            guard let value = value as? NSValue,
                  storage.attribute(NSAttributedString.Key("MarkdownBlockKind"), at: run.location, effectiveRange: nil) as? String == "image",
                  storage.attribute(NSAttributedString.Key("RenderedBlockImage"), at: run.location, effectiveRange: nil) != nil else { return }
            let relative = value.rangeValue
            let decoded = NSRange(location: max(0, run.location - relative.location), length: relative.length)
            guard decoded == candidate else { return }
            token = decoded
            imageAnchor = run.location
            stop.pointee = true
        }
        guard let token else {
            var viewportDescription = "unavailable"
            if let layout = textView.textLayoutManager, let content = layout.textContentManager,
               let viewport = layout.textViewportLayoutController.viewportRange {
                let start = content.offset(from: layout.documentRange.location, to: viewport.location)
                let end = content.offset(from: layout.documentRange.location, to: viewport.endLocation)
                viewportDescription = "\(start)..<\(end)"
            }
            var attributes: [String] = []
            storage.enumerateAttributes(in: candidate) { values, run, _ in
                guard attributes.count < 8 else { return }
                let kind = values[NSAttributedString.Key("MarkdownBlockKind")] as? String ?? "none"
                let image = values[NSAttributedString.Key("RenderedBlockImage")] != nil
                attributes.append("\(run.location):kind=\(kind),image=\(image)")
            }
            result.failures.append("Source image \(candidate) is not rendered after viewport setup; viewport=\(viewportDescription), editorLength=\(storage.length), hidden=\(textView.isHiddenOrHasHiddenAncestor), attributes=\(attributes.joined(separator: ";"))")
            return result
        }
        let below = NSMaxRange((original as NSString).paragraphRange(for: token))
        guard below < storage.length else {
            result.failures.append("The image fixture needs a paragraph below the image")
            return result
        }
        func button(_ label: String, in view: NSView) -> NSView? {
            guard !view.isHidden else { return nil }
            if let nativeButton = view as? NSButton, nativeButton.title == label { return nativeButton }
            if view.accessibilityLabel() == label || view.accessibilityTitle() == label, view.accessibilityRole() == .button || view.accessibilityRole() == .radioButton || view.accessibilityRole() == .menuButton {
                return view
            }
            for child in view.subviews {
                if let found = button(label, in: child) { return found }
            }
            return nil
        }
        func selectionState() -> String {
            let bar = scroll.subviews.first { String(describing: type(of: $0)) == "MarkdownSelectionBarView" }
            let ring = textView.subviews.first { String(describing: type(of: $0)) == "ImageChromeView" && !$0.isHidden }
            return "key=\(window.isKeyWindow), responder=\(window.firstResponder === textView), selection=\(textView.selectedRange()), ring=\(ring != nil), barHidden=\(bar?.isHiddenOrHasHiddenAncestor.description ?? "missing")"
        }
        func controlHierarchy(in root: NSView) -> String {
            var rows: [String] = []
            func visit(_ view: NSView, depth: Int) {
                guard rows.count < 80, depth < 10 else { return }
                let nativeTitle = (view as? NSButton)?.title ?? ""
                rows.append("\(depth):\(type(of: view)) hidden=\(view.isHidden) label=\(view.accessibilityLabel() ?? "") title=\(view.accessibilityTitle() ?? "") buttonTitle=\(nativeTitle) role=\(view.accessibilityRole()?.rawValue ?? "none")")
                for child in view.subviews { visit(child, depth: depth + 1) }
            }
            visit(root, depth: 0)
            return rows.joined(separator: "; ")
        }
        func press(_ label: String) -> Bool {
            guard let view = button(label, in: scroll) else {
                result.failures.append("No visible accessible control: \(label); \(selectionState()); hierarchy=\(controlHierarchy(in: scroll))")
                return false
            }
            let start = ProcessInfo.processInfo.systemUptime
            let accepted = view.accessibilityPerformPress()
            result.slowestMilliseconds = max(result.slowestMilliseconds, (ProcessInfo.processInfo.systemUptime - start) * 1_000)
            result.gestures += 1
            if !accepted { result.failures.append("Accessible control refused press: \(label)") }
            return accepted
        }
        var witness: ReadableTextLineProbe?
        func sample(label: String) {
            guard let witness, let actual = witness.resample(in: textView) else {
                result.failures.append("Missing fixed readable line measurement: \(label)")
                return
            }
            result.samples += 1
            let delta = Double(actual.windowY - witness.windowY)
            result.maxShift = max(result.maxShift, abs(delta))
            result.notes.append(String(format: "Readable witness %@: delta=%+.3fpt baseline=%.3fpt actual=%.3fpt range=%@",
                label, delta, Double(witness.windowY), Double(actual.windowY), NSStringFromRange(witness.range)))
        }
        func findView(_ name: String, in root: NSView) -> NSView? {
            guard !root.isHiddenOrHasHiddenAncestor else { return nil }
            if String(describing: type(of: root)) == name { return root }
            for child in root.subviews {
                if let found = findView(name, in: child) { return found }
            }
            return nil
        }
        func key(_ code: UInt16, characters: String) {
            guard window.isKeyWindow, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
                result.failures.append("Could not deliver native key \(code) to the key window")
                return
            }
            window.sendEvent(event)
        }
        // A single drag, always terminated by its queued mouse-up. This never
        // enters image-body dragging or creates an NSDraggingSession.
        func drag(from start: NSPoint, to end: NSPoint) -> Double? {
            guard window.isKeyWindow else {
                result.failures.append("Target window lost key status before a handle drag")
                return nil
            }
            let now = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, _ point: NSPoint, _ offset: Double) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now + offset,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1)
            }
            guard let down = event(.leftMouseDown, start, 0), let moved = event(.leftMouseDragged, end, 0.001),
                  let up = event(.leftMouseUp, end, 0.002) else {
                result.failures.append("Could not construct native handle drag")
                return nil
            }
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(moved, atStart: true)
            let began = ProcessInfo.processInfo.systemUptime
            window.sendEvent(down)
            result.gestures += 1
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1_000
            result.slowestMilliseconds = max(result.slowestMilliseconds, elapsed)
            return elapsed
        }
        func requireImageOnlyEdit(_ label: String) -> Bool {
            let selected = textView.selectedRange()
            let current = textView.string as NSString
            let before = original as NSString
            guard selected.location == token.location, NSMaxRange(selected) <= current.length,
                  sameSource(current.substring(to: selected.location), before.substring(to: token.location)),
                  sameSource(current.substring(from: NSMaxRange(selected)), before.substring(from: NSMaxRange(token))) else {
                result.failures.append("\(label) edited outside the selected image or lost object selection")
                return false
            }
            return true
        }
        func undoExactly(_ label: String) async -> Bool {
            guard let undo = textView.undoManager, undo.canUndo else {
                result.failures.append("No Undo after \(label)")
                return false
            }
            undo.undo()
            try? await Task.sleep(for: .milliseconds(120))
            guard matchesOriginalSource() else {
                result.failures.append("One Undo did not restore exact source after \(label)")
                return false
            }
            if label == "resize" {
                result.notes.append("Resize geometry after Undo: \(viewportDiagnostic(in: textView))")
            }
            sample(label: "\(label) Undo")
            return true
        }
        // Exercise the normal image-body selection route, including focus and
        // toolbar suppression reset, rather than only selecting hidden source.
        guard window.isKeyWindow else {
            result.failures.append("Target window lost key status before the image click; \(selectionState())")
            return result
        }
        guard let imageAnchor else {
            result.failures.append("Rendered image has no anchor for native clicking; \(selectionState())")
            return result
        }
        var witnessMinimum = proseOffset
        for _ in 0..<8 {
            guard let candidate = ReadableTextLineProbe.capture(in: textView, minimumLocation: witnessMinimum) else { break }
            let literal = String(decoding: candidate.sourceUTF16, as: UTF16.self)
            if candidate.range.location < NSMaxRange(proseParagraph),
               !literal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                witness = candidate
                break
            }
            witnessMinimum = NSMaxRange(candidate.range)
        }
        guard witness != nil else {
            result.failures.append("No fully visible readable witness before clicking image at \(token.location), prose=\(proseOffset); \(viewportDiagnostic(in: textView))")
            return result
        }
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: imageAnchor, length: 1), actualRange: nil)
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let imageRect = window.convertFromScreen(screenRect).intersection(clip)
        guard !imageRect.isNull, imageRect.width > 32, imageRect.height > 32 else {
            result.failures.append("Image click target is not visible beside its prose witness: \(imageRect); \(selectionState()); \(viewportDiagnostic(in: textView))")
            return result
        }
        let point = NSPoint(x: imageRect.midX, y: imageRect.midY)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.001,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
            result.failures.append("Could not construct the image click")
            return result
        }
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        result.gestures += 1
        try? await Task.sleep(for: .milliseconds(160))
        guard textView.selectedRange() == token,
              textView.subviews.contains(where: { String(describing: type(of: $0)) == "ImageChromeView" && !$0.isHidden }) else {
            result.failures.append("Native image click did not object-select the image; \(selectionState())")
            return result
        }
        sample(label: "object selection")
        guard result.samples == 1 else { return result }
        // Dispatch a real native hover once, measuring handler work rather than
        // the fade duration. Any storage edit during hover violates the contract.
        PerfTrace.dump("image controls before hover")
        var hoverEdits = 0
        let hoverObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil) { _ in MainActor.assumeIsolated { hoverEdits += 1 } }
        if let hover = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            let began = ProcessInfo.processInfo.systemUptime
            NSApp.sendEvent(hover)
            result.hoverMilliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1_000
        } else { result.failures.append("Could not construct native hover") }
        PerfTrace.dump("image controls hover")
        NotificationCenter.default.removeObserver(hoverObserver)
        if hoverEdits != 0 { result.failures.append("Hover edited text storage") }
        if findView("ImageResizeBars", in: textView) == nil {
            result.failures.append("Native hover did not expose the image resize bars")
        }
        if let elapsed = result.hoverMilliseconds, elapsed > 0.5 { result.failures.append("Native hover exceeded 0.5ms: \(elapsed)ms") }
        sample(label: "hover")
        let source = original as NSString
        let image = source.substring(with: token)
        let alignment = image.contains("|center") ? "Align right" : "Align center"
        guard press(alignment) else { return result }
        do {
            guard !matchesOriginalSource() else {
                result.failures.append("Alignment did not edit image metadata")
                return result
            }
            guard requireImageOnlyEdit("Alignment"), await undoExactly("alignment") else { return result }
        }
        // Traverse the real menu with its native keyboard route; the first
        // row is Copy image for this resolved raster, the second Edit alt text.
        guard press("More actions") else { return result }
        do {
            guard let menu = findView("ChromeMenuView", in: scroll), window.firstResponder === menu else {
                result.failures.append("Image menu did not take keyboard focus")
                return result
            }
            if !matchesOriginalSource() { result.failures.append("Opening image menu edited source") }
            key(125, characters: "\u{f701}")
            key(125, characters: "\u{f701}")
            key(36, characters: "\r")
            guard let popover = findView("ImageAltTextPopover", in: scroll),
                  let editor = window.firstResponder as? NSTextView, editor !== textView,
                  editor.isDescendant(of: popover) else {
                result.failures.append("Edit alt text menu row did not focus its native editor")
                return result
            }
            editor.selectAll(nil)
            editor.insertText("   ", replacementRange: editor.selectedRange())
            guard let save = button("Save", in: popover) as? NSButton else {
                result.failures.append("Alt popover has no native Save control; hierarchy=\(controlHierarchy(in: popover))")
                return result
            }
            guard !save.isEnabled else {
                result.failures.append("Alt Save remained enabled for whitespace-only input")
                return result
            }
            editor.selectAll(nil)
            editor.insertText("QA ] | café 🧭", replacementRange: editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(280))
            guard matchesOriginalSource() else {
                result.failures.append("Typing in alt popover edited Markdown before Save")
                return result
            }
            guard save.isEnabled, window.isKeyWindow, save.window === window,
                  !save.isHiddenOrHasHiddenAncestor, save.action != nil else {
                result.failures.append("Native Save is not enabled in the active popover")
                return result
            }
            let saveRect = save.convert(save.bounds, to: nil)
            let savePoint = NSPoint(x: saveRect.midX, y: saveRect.midY)
            let saveHit = window.contentView?.hitTest(savePoint)
            guard save.visibleRect.width > 0, save.visibleRect.height > 0,
                  saveHit === save || saveHit?.isDescendant(of: save) == true else {
                result.failures.append("Native Save button is not the visible hit target at \(savePoint); hit=\(saveHit.map { String(describing: type(of: $0)) } ?? "none")")
                return result
            }
            let saveTimestamp = ProcessInfo.processInfo.systemUptime
            guard let saveDown = NSEvent.mouseEvent(with: .leftMouseDown, location: savePoint, modifierFlags: [],
                timestamp: saveTimestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let saveUp = NSEvent.mouseEvent(with: .leftMouseUp, location: savePoint, modifierFlags: [],
                timestamp: saveTimestamp + 0.001, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                result.failures.append("Could not construct native Save button click")
                return result
            }
            // Deliver the normal mouse tracking path with its mouse-up ready;
            // performClick adds a synthetic flash delay unrelated to an input.
            NSApp.postEvent(saveUp, atStart: true)
            let saveStart = ProcessInfo.processInfo.systemUptime
            window.sendEvent(saveDown)
            result.slowestMilliseconds = max(result.slowestMilliseconds,
                (ProcessInfo.processInfo.systemUptime - saveStart) * 1_000)
            result.gestures += 1
            guard popover.superview == nil, !matchesOriginalSource(), window.firstResponder === textView else {
                result.failures.append("Native Save click did not close the popover, edit source and restore editor focus")
                return result
            }
            do {
                let selected = textView.selectedRange()
                guard selected.location == token.location, NSMaxRange(selected) <= storage.length else {
                    result.failures.append("Alt save lost the image object selection")
                    return result
                }
                let changed = (textView.string as NSString).substring(with: selected)
                if !changed.contains(#"QA \] \| café 🧭"#) {
                    result.failures.append("Alt save did not preserve Unicode and escape Markdown delimiters")
                }
                guard requireImageOnlyEdit("Alt save"), await undoExactly("alt text") else { return result }
            }
        }
        // Use the right resize bar, shrinking to avoid a max-width no-op.
        // The storage observer distinguishes attribute preview from commit.
        try? await Task.sleep(for: .milliseconds(100))
        // TextKit's anchor glyph rect is not the raster rect (notably for
        // right alignment). The selected image's mounted AX group uses the
        // actual rendered raster geometry; hover it to expose the drawn bars.
        guard let resizeGroup = findView("ImageResizeAccessibilityView", in: textView) else {
            result.failures.append("Selected image has no visible native resize geometry; \(selectionState()); \(controlHierarchy(in: textView))")
            return result
        }
        let selectedRaster = resizeGroup.convert(resizeGroup.bounds, to: nil)
        let barPoint = NSPoint(x: selectedRaster.maxX + 6, y: selectedRaster.midY)
        guard let resizeHover = NSEvent.mouseEvent(with: .mouseMoved, location: barPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0) else {
            result.failures.append("Could not construct resize-bar setup hover")
            return result
        }
        NSApp.sendEvent(resizeHover)
        guard let bars = findView("ImageResizeBars", in: textView), bars.alphaValue > 0.9 else {
            result.failures.append("Resize setup hover did not expose native bars at \(selectedRaster); \(selectionState()); \(controlHierarchy(in: textView))")
            return result
        }
        let resizeRect = bars.convert(bars.bounds.insetBy(dx: 12, dy: 0), to: nil)
        let resizeStart = bars.convert(NSPoint(x: bars.bounds.maxX - 6, y: bars.bounds.midY), to: nil)
        let nativePoint = textView.convert(resizeStart, from: nil)
        let hit = window.contentView?.hitTest(resizeStart)
        guard abs(resizeRect.minX - selectedRaster.minX) < 1, abs(resizeRect.minY - selectedRaster.minY) < 1,
              abs(resizeRect.width - selectedRaster.width) < 1, abs(resizeRect.height - selectedRaster.height) < 1,
              clip.contains(resizeStart), textView.visibleRect.contains(nativePoint),
              hit === textView || hit?.isDescendant(of: textView) == true else {
            result.failures.append("Resize bar geometry/hit mismatch: selected=\(selectedRaster), drawn=\(resizeRect), pointer=\(resizeStart), hit=\(hit.map { String(describing: type(of: $0)) } ?? "none"); \(viewportDiagnostic(in: textView))")
            return result
        }
        var previewObserved = false
        var previewChangedSource = false
        var characterEdits = 0
        let resizeObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: storage, queue: nil) { notification in MainActor.assumeIsolated {
                guard let storage = notification.object as? NSTextStorage else { return }
                if storage.editedMask.contains(.editedCharacters) { characterEdits += 1 }
                else if characterEdits == 0 {
                    previewObserved = true
                    if !matchesOriginalSource() { previewChangedSource = true }
                }
            } }
        result.notes.append("Resize geometry before preview: \(viewportDiagnostic(in: textView))")
        PerfTrace.dump("image controls before resize")
        result.resizeGestureMilliseconds = drag(from: resizeStart, to: NSPoint(x: resizeStart.x - 20, y: resizeStart.y))
        PerfTrace.dump("image controls resize")
        result.notes.append("Resize geometry after commit: \(viewportDiagnostic(in: textView))")
        NotificationCenter.default.removeObserver(resizeObserver)
        guard previewObserved, !previewChangedSource, characterEdits == 1, !matchesOriginalSource() else {
            result.failures.append("Resize must preview attributes then commit once: preview=\(previewObserved), prematureSource=\(previewChangedSource), edits=\(characterEdits), raster=\(resizeRect), pointer=\(resizeStart), selection=\(textView.selectedRange())")
            return result
        }
        guard requireImageOnlyEdit("Resize") else { return result }
        let resizedToken = (textView.string as NSString).substring(with: textView.selectedRange())
        let widthPattern = try? NSRegularExpression(pattern: #"(?<!\\)\|([0-9]+)\]\("#)
        guard let widthMatch = widthPattern?.firstMatch(in: resizedToken, range: NSRange(location: 0, length: resizedToken.utf16.count)),
              let writtenWidth = Double((resizedToken as NSString).substring(with: widthMatch.range(at: 1))),
              writtenWidth < resizeRect.width.rounded(), writtenWidth >= 40 else {
            result.failures.append("Resize did not write a smaller valid width as the final alt token")
            return result
        }
        guard await undoExactly("resize") else { return result }
        try? await Task.sleep(for: .milliseconds(100))
        guard press("Crop image") else { return result }
        do {
            if !matchesOriginalSource() { result.failures.append("Entering crop edited Markdown") }
            sample(label: "crop entry")
            guard press("Cancel crop") else { return result }
            do {
                try? await Task.sleep(for: .milliseconds(100))
                if !matchesOriginalSource() { result.failures.append("Cancelling crop edited Markdown") }
                sample(label: "crop cancellation")
                if button("Crop image", in: scroll) == nil { result.failures.append("Cancelling crop did not restore the image toolbar") }
            }
        }
        guard press("Crop image") else { return result }
        do {
            guard let crop = findView("ImageCropView", in: scroll), window.firstResponder === crop else {
                result.failures.append("Crop overlay did not take native focus")
                return result
            }
            // The qualification fixture starts uncropped. Its visible image
            // rect is the initial overlay frame, fitted/clamped to its bounds.
            guard !image.contains("crop=") else {
                result.failures.append("Crop gesture qualification needs an initially uncropped fixture")
                return result
            }
            var frame = crop.convert(resizeRect, from: nil)
            let available = crop.bounds.insetBy(dx: 16, dy: 16)
            if frame.width > available.width || frame.height > available.height {
                let scale = min(available.width / frame.width, available.height / frame.height)
                frame.size = NSSize(width: frame.width * scale, height: frame.height * scale)
                frame.origin = NSPoint(x: available.midX - frame.width / 2, y: available.midY - frame.height / 2)
            }
            frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
            let edge = crop.convert(NSPoint(x: frame.maxX, y: frame.midY), to: nil)
            let moved = crop.convert(NSPoint(x: frame.maxX - frame.width * 0.2, y: frame.midY), to: nil)
            result.cropGestureMilliseconds = drag(from: edge, to: moved)
            if !matchesOriginalSource() { result.failures.append("Crop drag edited source before Apply") }
            sample(label: "crop preview")
            guard press("Apply crop") else { return result }
            do {
                guard requireImageOnlyEdit("Crop apply") else { return result }
                let croppedToken = (textView.string as NSString).substring(with: textView.selectedRange())
                let cropPattern = try? NSRegularExpression(pattern: #"(?<!\\)\|crop=([0-9.]+),([0-9.]+),([0-9.]+),([0-9.]+)(?=\|[0-9]+\]\()"#)
                guard !matchesOriginalSource(),
                      let cropMatch = cropPattern?.firstMatch(in: croppedToken, range: NSRange(location: 0, length: croppedToken.utf16.count)),
                      let width = Double((croppedToken as NSString).substring(with: cropMatch.range(at: 3))),
                      abs(width - 0.8) < 0.01 else {
                    result.failures.append("Crop Apply did not commit the selected image's 20-percent edge crop")
                    return result
                }
                guard await undoExactly("crop apply") else { return result }
            }
        }
        result.notes.append("Attempted one native selection, hover, alignment/Undo, menu keyboard route, escaped Unicode alt save/Undo, resize handle drag/Undo, crop cancel, crop edge drag/Apply/Undo; readable witness sampled only at unchanged-source checkpoints.")
        if result.maxShift >= 1 { result.failures.append("Image controls shifted the line below the image by \(result.maxShift) pt") }
        if result.slowestMilliseconds > 100 { result.failures.append("An image control held the main thread for \(result.slowestMilliseconds) ms") }
        return result
    }

    private static func viewportDiagnostic(in textView: NSTextView) -> String {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let storage = textView.textStorage,
              let viewport = layout.textViewportLayoutController.viewportRange else { return "viewport unavailable" }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        var rows = ["selection=\(textView.selectedRange()), window=\(textView.window.map { NSStringFromRect($0.frame) } ?? "none"), visible=\(NSStringFromRect(visible)), viewport=\(content.offset(from: content.documentRange.location, to: viewport.location))..\(content.offset(from: content.documentRange.location, to: viewport.endLocation))"]
        var fragments = 0
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragments < 16 else { return false }
            fragments += 1
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            let offset = fragment.textElement?.elementRange.map { content.offset(from: content.documentRange.location, to: $0.location) } ?? -1
            rows.append("fragment offset=\(offset) frame=\(NSStringFromRect(frame)) state=\(fragment.state)")
            for line in fragment.textLineFragments.prefix(4) where line.characterRange.location != NSNotFound {
                let range = NSRange(location: offset + line.characterRange.location, length: line.characterRange.length)
                var fonts: [CGFloat] = []
                var raster = false
                if range.location >= 0, range.length > 0, NSMaxRange(range) <= storage.length {
                    storage.enumerateAttributes(in: range) { attributes, _, _ in
                        if let font = attributes[.font] as? NSFont, fonts.count < 4, !fonts.contains(font.pointSize) { fonts.append(font.pointSize) }
                        if attributes[NSAttributedString.Key("RenderedBlockImage")] is NSImage { raster = true }
                    }
                }
                let lineFrame = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                rows.append("line range=\(range) frame=\(NSStringFromRect(lineFrame)) fonts=\(fonts) raster=\(raster)")
            }
            return frame.minY < visible.maxY
        }
        return rows.joined(separator: "; ")
    }

}
#endif
