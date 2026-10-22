//
//  QAReplay.swift
//  PageFlow
//
//  DEBUG-only, env-gated scenarios driven inside the REAL app — full
//  TabManager routing, real settings, real AppKit event delivery — with the
//  engine's ScrollTrace ledger as the oracle. The headless engine harness
//  cannot reproduce the field jumps (timing, responsive scrolling, the
//  magnification bounce); this runs the same gestures where they happen and
//  measures what the reader would see.
//
//  Environment:
//    PAGEFLOW_QA_SCENARIO  scroll-read | click-sweep | zoom-steps | switch-restore
//                          | type-burst | math-edit | format-burst | undo-check
//                          | table-nav | table-wrap-type | selection-bar | image-select | all
//    PAGEFLOW_QA_DOC       document to open (must be readable by the sandboxed app,
//                          e.g. inside the container's tmp directory)
//    PAGEFLOW_QA_EXIT      "1" exits 0 on pass, 1 on failure
//    PAGEFLOW_QA_RUN_ID    receipt identity for this replay
//    PAGEFLOW_QA_OUTPUT_DIR report destination (default: a unique temp directory)
//
//  Output: complete JSON reports, a run manifest and a summary. Missing probes,
//  correctness failures and report-write errors fail the run. Inert in Release.
//

#if DEBUG
import AppKit
import MarkdownEngine

@MainActor
enum QAReplay {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["PAGEFLOW_QA_SCENARIO"] != nil }

    static func startIfRequested() {
        guard isRequested else { return }
        // Line-buffered stdout so the QA lines interleave with the engine's
        // stderr traces when both go to one file.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { await run() }
    }

    // MARK: - Report

    struct ScenarioResult: Codable {
        let scenario: String
        let document: String
        var gestures = 0
        /// Origin changes nobody asked for (ScrollTrace) and the largest one.
        var unattributed = 0
        var unattributedMaxDelta: CGFloat = 0
        /// Largest on-screen movement of the probed line while the user did nothing.
        var maxIdleDrift: CGFloat = 0
        /// Largest on-screen movement of a line the user just interacted with.
        var maxInteractionShift: CGFloat = 0
        var openMilliseconds: Double?
        var footprintMB: Double?
        var perKeyMilliseconds: Double?
        /// Callback/whole-gesture elapsed times; these are not per-frame timings.
        var hoverCallbackMilliseconds: Double?
        var resizeGestureMilliseconds: Double?
        var cropGestureMilliseconds: Double?
        var notes: [String] = []
        var failures: [String] = []
        var measuredSamples = 0
        var passed: Bool { failures.isEmpty }

        mutating func validate() {
            if gestures == 0 { failures.append("No gestures executed") }
            if measuredSamples == 0 { failures.append("No valid geometry measurements") }
            for (label, value) in [("idle drift", maxIdleDrift), ("interaction shift", maxInteractionShift)] {
                if !value.isFinite || value < 0 || value >= 1 {
                    failures.append("\(label) must be finite and below 1pt; measured \(value)")
                }
            }
            for (label, value) in [("hover callback", hoverCallbackMilliseconds),
                                   ("resize gesture", resizeGestureMilliseconds), ("crop gesture", cropGestureMilliseconds)] {
                if let value, !value.isFinite || value < 0 {
                    failures.append("Invalid \(label): \(value)")
                }
            }
            for (label, value) in [("open time", openMilliseconds), ("footprint", footprintMB), ("key time", perKeyMilliseconds)] {
                if let value, !value.isFinite || value <= 0 {
                    failures.append("Invalid \(label): \(value)")
                }
            }
        }

        var summary: String {
            var fields = ["QA \(passed ? "PASS" : "FAIL") \(scenario) \(document)",
                          "gestures=\(gestures)", "samples=\(measuredSamples)",
                          "unattributed=\(unattributed)",
                          "unattributedMax=\(format(unattributedMaxDelta))",
                          "idleDrift=\(format(maxIdleDrift))",
                          "interactionShift=\(format(maxInteractionShift))"]
            if let openMilliseconds { fields.append("open=\(format(openMilliseconds))ms") }
            if let footprintMB { fields.append("footprint=\(format(footprintMB))MB") }
            if let perKeyMilliseconds { fields.append("perKey=\(format(perKeyMilliseconds))ms") }
            return fields.joined(separator: " ")
        }

        private func format(_ value: CGFloat) -> String { String(format: "%.1f", value) }
        private func format(_ value: Double) -> String { String(format: "%.1f", value) }
    }

    // MARK: - Run

    private static func run() async {
        let env = ProcessInfo.processInfo.environment
        let requested = env["PAGEFLOW_QA_SCENARIO"] ?? "all"
        let scenarios = requested == "all" ? supportedScenarios :
            requested.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !scenarios.isEmpty, Set(scenarios).count == scenarios.count,
              scenarios.allSatisfy(supportedScenarios.contains) else {
            finish(scenarios: scenarios, results: [], failures: ["Invalid or duplicate scenario: \(requested)"])
            return
        }
        QAPresentation.prepare()
        let foregroundScenarios: Set<String> = ["selection-bar", "image-select", "image-controls", "shortcuts", "checklist", "hover", "comments", "click-sweep", "table-chrome", "table-nav", "table-wrap-type", "type-burst", "math-edit", "format-burst", "undo-check"]
        if QAPresentation.runsInBackground, !foregroundScenarios.isDisjoint(with: scenarios) {
            finish(scenarios: scenarios, results: [], failures: ["Deferred: requested scenarios require an explicitly approved foreground session"])
            return
        }
        let documentPath = env["PAGEFLOW_QA_DOC"]
        QAPresentation.activateIfAllowed()

        guard let tabManager = await waitForTabManager() else {
            finish(scenarios: scenarios, results: [], failures: ["No window/TabManager appeared"])
            return
        }
        var openResult: (milliseconds: Double, footprintMB: Double)?
        if let documentPath {
            openResult = await open(URL(fileURLWithPath: documentPath), in: tabManager)
            guard openResult != nil else {
                finish(scenarios: scenarios, results: [], failures: ["\(documentPath) did not open as a markdown tab"])
                return
            }
        }
        await sleep(0.5)
        guard let content = tabManager.activeMarkdownContent,
              let textView = liveEditor(in: tabManager),
              let window = textView.window,
              let scrollView = textView.enclosingScrollView else {
            finish(scenarios: scenarios, results: [], failures: ["No live-preview editor found in the target window"])
            return
        }

        let documentName = content.documentManager.documentTitle
        let context = Context(tabManager: tabManager, content: content, window: window, textView: textView, scrollView: scrollView, documentName: documentName)
        var results: [ScenarioResult] = []
        for name in scenarios {
            var result = ScenarioResult(scenario: name, document: documentName)
            if name == scenarios.first, let openResult {
                result.openMilliseconds = openResult.milliseconds
                result.footprintMB = openResult.footprintMB
            }
            ScrollTrace.reset(keepingBaselines: true)
            FileHandle.standardError.write(Data("QA >> \(name)\n".utf8))
            switch name {
            case "scroll-read": await scrollRead(context, &result)
            case "click-sweep": await clickSweep(context, &result)
            case "zoom-steps": await zoomSteps(context, &result)
            case "type-burst": await typeBurst(context, &result)
            case "math-edit": await mathEdit(context, &result)
            case "format-burst": await formatBurst(context, &result)
            case "undo-check": await undoCheck(context, &result)
            case "switch-restore": await switchRestore(context, &result)
            case "table-nav": await tableNav(context, &result)
            case "table-wrap-type": await tableWrapType(context, &result)
            case "selection-bar": await selectionBar(context, &result)
            case "table-chrome": await tableChrome(context, &result)
            case "comments": await comments(context, &result)
            case "hover": await hover(context, &result)
            case "checklist": await checklist(context, &result)
            case "shortcuts": await shortcuts(context, &result)
            case "image-select": await imageSelect(context, &result)
            case "image-drop": await imageDrop(context, &result)
            case "block-move": await blockMove(context, &result)
            case "image-controls":
                let check = await ImageControlsQA.run(textView: context.textView, window: context.window, lineY: { screenY(of: $0, in: context.textView).map(Double.init) })
                result.failures += check.failures
                result.gestures += check.gestures
                result.measuredSamples += check.samples
                result.maxInteractionShift = max(result.maxInteractionShift, CGFloat(check.maxShift))
                result.hoverCallbackMilliseconds = check.hoverMilliseconds
                result.resizeGestureMilliseconds = check.resizeGestureMilliseconds
                result.cropGestureMilliseconds = check.cropGestureMilliseconds
                result.notes.append(String(format: "Bounded native image controls; slowest control %.1f ms", check.slowestMilliseconds))
                for (label, elapsed) in [("hover callback", check.hoverMilliseconds),
                                         ("resize gesture including commit", check.resizeGestureMilliseconds),
                                         ("crop gesture", check.cropGestureMilliseconds)] {
                    if let elapsed {
                        guard elapsed.isFinite, elapsed >= 0 else {
                            result.failures.append("Invalid timing for \(label)")
                            continue
                        }
                        result.notes.append(String(format: "%@: %.2f ms (whole callback/gesture, not a frame measurement)", label, elapsed))
                    }
                }
                result.notes += check.notes
                result.notes += check.manualCases.map { "Pending separate qualification: \($0)" }
            default: result.failures.append("Unknown scenario")
            }
            let trace = ScrollTrace.snapshot()
            result.unattributed = trace.unattributedCount
            result.unattributedMaxDelta = trace.unattributedMaxDelta
            result.validate()
            results.append(result)
        }
        finish(scenarios: scenarios, results: results)
    }

    private struct Context {
        let tabManager: TabManager
        let content: MarkdownContent
        let window: NSWindow
        let textView: NSTextView
        let scrollView: NSScrollView
        let documentName: String
    }

    // MARK: - Scenarios

    /// Reading: wheel down through the document, then back up. Between bursts
    /// the user does nothing for 250 ms — any movement then is a jump.
    private static func scrollRead(_ c: Context, _ r: inout ScenarioResult) async {
        r.notes.append(String(format: "geometry: clip %.0f wide, text view x=%.0f w=%.0f, container w=%.0f, text container w=%.0f",
                              c.scrollView.contentView.bounds.width, c.textView.frame.minX, c.textView.frame.width,
                              c.textView.superview?.frame.width ?? -1, c.textView.textContainer?.size.width ?? -1))
        for direction in [-1, 1] as [Int32] {
            for step in 0..<60 {
                guard wheel(c.scrollView, deltaY: direction * 60) else {
                    r.failures.append("Could not create scroll event")
                    return
                }
                r.gestures += 1
                await sleep(0.016)
                if step % 10 == 9 {
                    let drift = await idleDrift(c.textView)
                    r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
                }
            }
        }
    }

    /// Click each initially visible readable text line at a fixed native mouse point.
    /// The clicked line stays under the caret through a reveal or collapse;
    /// content above a changing block can move as the viewport follows that caret.
    private static func clickSweep(_ c: Context, _ r: inout ScenarioResult) async {
        guard let storage = c.textView.textStorage else {
            r.failures.append("Click sweep has no native text storage")
            return
        }
        let targets = visibleFragmentStarts(in: c.textView, limit: 14)
        if targets.isEmpty { r.failures.append("No visible click targets") }
        var qualifiedInputs = 0
        var qualifiedProbes = 0
        var excludedRaster = 0
        var excludedCollapsed = 0
        var excludedPartial = 0
        var excludedChrome = 0
        let renderedImageKey = NSAttributedString.Key("RenderedBlockImage")
        r.notes.append("click coverage: fully visible readable native text; raster grid/image anchors, collapsed source rows, clipped lines and table chrome (grips, handle, add bars) excluded")
        func lineTopWindowY(_ geometry: MathProbeGeometry) -> CGFloat {
            c.textView.convert(NSPoint(x: geometry.lineFrame.minX, y: geometry.lineFrame.minY), to: nil).y
        }
        for location in targets {
            r.notes.append(mathGeometryDiagnostic("click @\(location) before target", location: location, in: c))
            r.notes.append(mathGeometryDiagnostic("click @\(location) before caret", location: c.textView.selectedRange().location, in: c))
            guard let targetBefore = mathProbeGeometry(at: location, in: c.textView), targetBefore.isVisible else {
                r.failures.append("Click @\(location): input target no longer visibly laid out before gesture")
                continue
            }
            var hasRaster = false
            var hasReadableFont = false
            storage.enumerateAttributes(in: targetBefore.lineRange) { attributes, _, _ in
                if attributes[renderedImageKey] is NSImage { hasRaster = true }
                if let font = attributes[.font] as? NSFont, font.pointSize.isFinite, font.pointSize >= 1 {
                    hasReadableFont = true
                }
            }
            if hasRaster {
                excludedRaster += 1
                r.notes.append("click @\(location) excluded: raster grid/image line has no one-to-one readable source-line hit target")
                continue
            }
            if targetBefore.lineFrame.height < 1 || !hasReadableFont {
                excludedCollapsed += 1
                r.notes.append("click @\(location) excluded: collapsed source line height=\(targetBefore.lineFrame.height) readableNativeFont=\(hasReadableFont)")
                continue
            }
            if targetBefore.lineFrame.minY < targetBefore.viewport.minY
                || targetBefore.lineFrame.maxY > targetBefore.viewport.maxY {
                excludedPartial += 1
                r.notes.append("click @\(location) excluded: clipped text line can legitimately scroll when the caret is revealed")
                continue
            }
            let clickPoint = NSPoint(x: targetBefore.lineFrame.minX + 1, y: targetBefore.lineFrame.midY)
            guard targetBefore.viewport.contains(clickPoint) else {
                r.failures.append("Click @\(location): fixed mouse point is outside the visible source line")
                continue
            }
            let windowPoint = c.textView.convert(clickPoint, to: nil)
            // Table chrome (an add-row bar under a table) takes the click by design (doc 24 §5.3.4).
            if let hit = c.window.contentView?.hitTest(c.window.contentView?.convert(windowPoint, from: nil) ?? windowPoint),
               String(describing: type(of: hit)).contains("TableChrome") {
                excludedChrome += 1
                r.notes.append("click @\(location) excluded: the point is on table chrome, which acts on click")
                continue
            }
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                                                timestamp: timestamp, windowNumber: c.window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                                              timestamp: timestamp + 0.001, windowNumber: c.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                r.failures.append("Click @\(location): could not create native mouse events")
                continue
            }
            let sourceBefore = Array(c.textView.string.utf16)
            let targetYBefore = lineTopWindowY(targetBefore)
            qualifiedInputs += 1
            // These source lines are diagnostic: a table collapse between a
            // heading and the clicked blank can legitimately move the heading.
            let watched = visibleFragmentStarts(in: c.textView, limit: 12)
            let topsBefore = watched.map { start -> (Int, MathProbeGeometry?, CGFloat?) in
                let geometry = mathProbeGeometry(at: start, in: c.textView)
                return (start, geometry, geometry.map(lineTopWindowY))
            }
            let originBefore = c.scrollView.contentView.bounds.origin.y
            r.notes.append("click @\(location) fixedMousePoint=\(NSStringFromPoint(windowPoint)) line=\(NSStringFromRange(targetBefore.lineRange)) lineTopWindowY=\(targetYBefore)")
            QAPresentation.show(c.window)
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
            r.gestures += 1
            await sleep(0.08)
            r.notes.append(mathGeometryDiagnostic("click @\(location) after target", location: location, in: c))
            r.notes.append(mathGeometryDiagnostic("click @\(location) after caret", location: c.textView.selectedRange().location, in: c))
            let exactSource = c.textView.string.utf16.elementsEqual(sourceBefore)
            r.notes.append("click @\(location) exactUTF16Source=\(exactSource) sourceLength=\(sourceBefore.count)")
            let originDelta = c.scrollView.contentView.bounds.origin.y - originBefore
            if abs(originDelta) >= 1 {
                let movers = ScrollTrace.snapshot().recent.suffix(4).map { "\($0.mutator ?? "?") Δ\(String(format: "%.1f", $0.delta))" }
                r.notes.append("click @\(location): signed scroll origin delta \(String(format: "%+.1f", originDelta))pt by \(movers.joined(separator: ", "))")
                for (start, before, windowYBefore) in topsBefore {
                    guard let before, let windowYBefore, let after = mathProbeGeometry(at: start, in: c.textView) else {
                        r.notes.append("   diagnostic line @\(start): layout missing after fold")
                        continue
                    }
                    r.notes.append(String(format: "   line @%d doc-shift %+.1f window-shift %+.1f source=%@",
                                          start, after.lineFrame.minY - before.lineFrame.minY,
                                          lineTopWindowY(after) - windowYBefore, String(reflecting: before.source)))
                }
            }
            guard exactSource else {
                r.failures.append("Click @\(location): mouse gesture changed the exact source")
                continue
            }
            let selection = c.textView.selectedRange()
            guard selection.location != NSNotFound, selection.location <= sourceBefore.count,
                  selection.length <= sourceBefore.count - selection.location,
                  selection.location >= targetBefore.lineRange.location,
                  NSMaxRange(selection) <= NSMaxRange(targetBefore.lineRange),
                  let selectedLine = mathProbeGeometry(at: selection.location, in: c.textView),
                  selectedLine.isVisible, selectedLine.lineFrame.height >= 1,
                  selectedLine.lineRange == targetBefore.lineRange,
                  selectedLine.source.utf16.elementsEqual(targetBefore.source.utf16) else {
                r.failures.append("Click @\(location): native mouse selection did not resolve the fixed source line")
                continue
            }
            guard let targetAfter = mathProbeGeometry(at: location, in: c.textView), targetAfter.isVisible,
                  targetAfter.lineFrame.height >= 1,
                  targetAfter.lineRange == targetBefore.lineRange,
                  targetAfter.source.utf16.elementsEqual(targetBefore.source.utf16) else {
                r.failures.append("Click @\(location): fixed source-line probe is missing, hidden or changed after gesture")
                continue
            }
            let moved = measurement(abs(lineTopWindowY(targetAfter) - targetYBefore),
                                    label: "visible clicked source line @\(location)", result: &r)
            qualifiedProbes += 1
            if moved >= 1 { r.notes.append("click @\(location): clicked source line moved \(String(format: "%.1f", moved))pt") }
            r.maxInteractionShift = max(r.maxInteractionShift, moved)
        }
        r.notes.append("click setup: initialTargets=\(targets.count) excludedRaster=\(excludedRaster) excludedCollapsed=\(excludedCollapsed) excludedPartial=\(excludedPartial) excludedChrome=\(excludedChrome) qualifiedTextInputs=\(qualifiedInputs) qualifiedFixedProbes=\(qualifiedProbes)")
        if qualifiedInputs < 2 || qualifiedProbes < 2 {
            r.failures.append("Click sweep requires at least two qualified visible mouse inputs and fixed source-line measurements")
        }
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Zooming: ⌘+ ×3, ⌘− ×3, ⌘0, then Ctrl-wheel ticks. The document point
    /// under the viewport center must survive the zoom, its settle and idle.
    private static func zoomSteps(_ c: Context, _ r: inout ScenarioResult) async {
        // The ruler is CONTENT: the top visible line's screen position once the
        // magnification has landed (50 ms) versus after the settle and after an
        // idle second. The origin legitimately moves when the settle lays out
        // the note above the viewport (an estimated chain becoming exact moves
        // every document coordinate by the same amount, and the pin follows).
        func measure(_ action: () -> Void) async {
            action()
            r.gestures += 1
            await sleep(0.05)
            let originAfterZoom = c.scrollView.contentView.bounds.midY
            let top = topLine(in: c.textView)
            let afterZoom = top.flatMap { screenY(ofLineKey: $0.key, near: $0.location, in: c.textView) }
            await sleep(0.35)
            let originAfterSettle = c.scrollView.contentView.bounds.midY
            let afterSettle = top.flatMap { screenY(ofLineKey: $0.key, near: $0.location, in: c.textView) }
            await sleep(0.6)
            let afterIdle = top.flatMap { screenY(ofLineKey: $0.key, near: $0.location, in: c.textView) }
            let shift = measurement(afterZoom.flatMap { before in afterSettle.map { abs($0 - before) } },
                                    label: "zoom settle probe", result: &r)
            r.maxInteractionShift = max(r.maxInteractionShift, shift)
            if let afterZoom, let afterSettle {
                if abs(afterSettle - afterZoom) >= 1 {
                    r.notes.append(String(format: "zoom %.3f: top line moved %.1fpt between the zoom and the settle (origin %+.1f)",
                                          c.scrollView.magnification, afterSettle - afterZoom, originAfterSettle - originAfterZoom))
                }
            } else if abs(originAfterSettle - originAfterZoom) >= 1 {
                r.notes.append(String(format: "zoom %.3f: top line not measurable; origin %+.1f between the zoom and the settle",
                                      c.scrollView.magnification, originAfterSettle - originAfterZoom))
            }
            let drift = measurement(afterSettle.flatMap { before in afterIdle.map { abs($0 - before) } },
                                    label: "zoom idle probe", result: &r)
            r.maxIdleDrift = max(r.maxIdleDrift, drift)
        }
        for _ in 0..<3 { await measure { c.content.zoomIn() } }
        for _ in 0..<3 { await measure { c.content.zoomOut() } }
        await measure { c.content.resetZoom() }
        for delta in [40, 40, -40, -40] as [Int32] {
            await measure {
                if !wheel(c.scrollView, deltaY: delta, control: true) {
                    r.failures.append("Could not create zoom-wheel event")
                }
            }
        }
        c.content.resetZoom()
        await sleep(0.4)
    }

    /// Typing: 30 characters into a visible prose line, then removed again.
    /// Neither the scroll position nor the top visible line may move; per-key
    /// cost is the O(edit) guard.
    private static func typeBurst(_ c: Context, _ r: inout ScenarioResult) async {
        // The first prose line below the top one: typing on a rendered image's
        // line replaces the selected image (doc 26 §3.1), and tables, code,
        // math and diagrams are edited as blocks. A note that opens on blocks
        // (images-240k.md) is scrolled to its first prose line.
        var visible = visibleFragmentStarts(in: c.textView, limit: 40)
        var prose = proseLineStarts(visible, in: c.textView)
        if prose.isEmpty, let first = visible.first,
           let line = proseLineStarts(paragraphStarts(from: first, count: 400, in: c.textView), in: c.textView).first {
            ScrollTrace.stamp("qa.scrollToProse")
            c.textView.scrollRangeToVisible(NSRange(location: line, length: 0))
            await sleep(0.3)
            visible = visibleFragmentStarts(in: c.textView, limit: 40)
            prose = proseLineStarts(visible, in: c.textView)
        }
        guard let top = visible.first, let location = prose.first(where: { $0 > top }) ?? prose.first else {
            r.failures.append("No visible prose line to type into")
            return
        }
        // A copy: in an optimized build the bridged `string` can alias the live storage.
        let original = Array(c.textView.string.utf16)
        c.textView.setSelectedRange(NSRange(location: location, length: 0))
        await sleep(0.1)
        let topBefore = screenY(of: top, in: c.textView)
        let originBefore = c.scrollView.contentView.bounds.origin.y
        var total = 0.0
        for _ in 0..<30 {
            let start = CFAbsoluteTimeGetCurrent()
            c.textView.insertText("x", replacementRange: c.textView.selectedRange())
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            total += elapsed
            PerfTrace.dump(String(format: "key %.1fms", elapsed))
            r.gestures += 1
            await sleep(0.016)
        }
        r.perKeyMilliseconds = total / 30
        let scrolled = abs(c.scrollView.contentView.bounds.origin.y - originBefore)
        if scrolled >= 1 { r.notes.append("typing @\(location): scroll origin moved \(String(format: "%.1f", scrolled))pt") }
        if top < location {
            let moved = measurement(topBefore.flatMap { before in
                screenY(of: top, in: c.textView).map { abs($0 - before) }
            }, label: "typing probe", result: &r)
            if moved >= 1 { r.notes.append("typing @\(location): top line @\(top) moved \(String(format: "%.1f", moved))pt") }
            r.maxInteractionShift = max(r.maxInteractionShift, moved)
        }
        var expected = original
        expected.insert(contentsOf: Array(repeating: 0x78, count: 30), at: location)
        let typed = Array(c.textView.string.utf16)
        guard typed == expected else {
            let first = zip(typed, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                ?? min(typed.count, expected.count)
            let context = { (units: [UInt16]) in
                String(decoding: units[max(0, first - 20)..<min(units.count, first + 40)], as: UTF16.self)
            }
            r.notes.append("typing @\(location): source differs from \(first): got \(String(reflecting: context(typed))), "
                           + "expected \(String(reflecting: context(expected)))")
            r.failures.append("Typing did not insert the exact requested source")
            return
        }
        c.textView.insertText("", replacementRange: NSRange(location: location, length: 30))
        if Array(c.textView.string.utf16) != original { r.failures.append("Typing cleanup changed the original source") }
        await sleep(0.1)
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Tables from the keyboard (doc 24 §8.1): for each of the first six
    /// tables, ↓ from the line above into the first row and ↑ back out, 20
    /// times, then a caret placed in a body cell. A cell editor must take the
    /// keyboard every time, the table must stay rendered (never pipes), the
    /// line below it must not move, and the source must not change.
    private static func tableNav(_ c: Context, _ r: inout ScenarioResult) async {
        let ns = c.textView.string as NSString
        let original = c.textView.string
        let renderedImage = NSAttributedString.Key("RenderedBlockImage")
        var tables: [(start: Int, end: Int, bodyCell: Int)] = []
        var cursor = 0
        while tables.count < 6, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            guard next < ns.length else { break }
            let separator = ns.lineRange(for: NSRange(location: next, length: 0))
            if line.location > 0, ns.substring(with: line).hasPrefix("|"),
               ns.substring(with: separator).hasPrefix("|"), ns.substring(with: separator).contains("---") {
                var end = NSMaxRange(separator)
                while end < ns.length, ns.substring(with: ns.lineRange(for: NSRange(location: end, length: 0))).hasPrefix("|") {
                    end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
                }
                let body = NSMaxRange(separator)
                if body < end { tables.append((line.location, end, body + 2)) }
                cursor = end
                continue
            }
            cursor = next
        }
        guard !tables.isEmpty else {
            r.failures.append("No table to navigate; use a table fixture or choose another scenario")
            return
        }
        func cellHasKeyboard() -> Bool {
            c.window.firstResponder.map { String(describing: type(of: $0)).contains("TableCellTextView") } ?? false
        }
        // A scenario before this one may have left a cell focused: start from
        // the top of the note with the text holding the keyboard.
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<20 where cellHasKeyboard() { await sleep(0.05) }
        await sleep(0.3)
        var slowest = 0.0
        for table in tables {
            var aboveEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &aboveEnd, for: NSRange(location: table.start - 1, length: 0))
            ScrollTrace.stamp("qa.centre")
            c.textView.scrollRangeToVisible(NSRange(location: table.start, length: 0))
            let probe = table.end < ns.length ? table.end : aboveEnd
            // Setup is navigation: wait until the table is rendered and the
            // probe line holds still for two samples (a long note styles the
            // viewport after the scroll).
            var probeBefore: CGFloat?
            var previous: CGFloat?
            let deadline = CFAbsoluteTimeGetCurrent() + 3
            while CFAbsoluteTimeGetCurrent() < deadline {
                await sleep(0.1)
                let now = screenY(of: probe, in: c.textView)
                let rendered = c.textView.textStorage?.attribute(renderedImage, at: table.start, effectiveRange: nil) != nil
                if rendered, let now, let previous, abs(now - previous) < 0.1 { probeBefore = now; break }
                previous = now
            }
            guard let probeBefore else {
                r.failures.append("Table @\(table.start): the table and its probe line never settled before entry")
                continue
            }
            var entries: [Double] = []
            for round in 0..<20 {
                c.window.makeFirstResponder(c.textView)
                c.textView.setSelectedRange(NSRange(location: aboveEnd, length: 0))
                let start = CFAbsoluteTimeGetCurrent()
                c.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
                let entry = (CFAbsoluteTimeGetCurrent() - start) * 1000
                entries.append(entry)
                slowest = max(slowest, entry)
                r.gestures += 1
                await sleep(0.03)
                if !cellHasKeyboard() { r.failures.append("Table @\(table.start) round \(round): ↓ did not focus a cell") }
                if c.textView.textStorage?.attribute(renderedImage, at: table.start, effectiveRange: nil) == nil {
                    r.failures.append("Table @\(table.start) round \(round): ↓ unfolded the table's source")
                }
                let moved = measurement(screenY(of: probe, in: c.textView).map { abs($0 - probeBefore) },
                                        label: "table probe", result: &r)
                if moved >= 1 { r.notes.append(String(format: "table @%d round %d: line below moved %.1fpt", table.start, round, moved)) }
                r.maxInteractionShift = max(r.maxInteractionShift, moved)
                (c.window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.moveUp(_:)))
                r.gestures += 1
                await sleep(0.03)
            }
            let sorted = entries.sorted()
            r.notes.append(String(format: "table @%d ↓ entry ms: first %.1f median %.1f max %.1f",
                                  table.start, entries.first ?? 0, sorted[sorted.count / 2], sorted.last ?? 0))
            // Cell ranges (doc 24 §8.4): Shift-arrows past a cell's edge make a
            // range; typing over it and Undo must leave the text above in place
            // and the source byte-identical after Undo.
            if let aboveBefore = screenY(of: aboveEnd, in: c.textView) {
                var typeOvers: [Double] = []
                for round in 0..<3 {
                    c.window.makeFirstResponder(c.textView)
                    c.textView.setSelectedRange(NSRange(location: aboveEnd, length: 0))
                    c.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    await sleep(0.03)
                    guard cellHasKeyboard(), let cell = c.window.firstResponder as? NSTextView else {
                        r.failures.append("Table @\(table.start) range round \(round): ↓ did not focus a cell")
                        continue
                    }
                    cell.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    cell.doCommand(by: #selector(NSResponder.moveToEndOfDocument(_:)))
                    cell.doCommand(by: #selector(NSResponder.moveRightAndModifySelection(_:)))
                    cell.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
                    r.gestures += 4
                    let start = CFAbsoluteTimeGetCurrent()
                    asOneEvent(c.textView.undoManager) {
                        cell.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    typeOvers.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    PerfTrace.dump("range type-over \(round)")
                    r.gestures += 1
                    await sleep(0.05)
                    if c.textView.string.utf16.elementsEqual(original.utf16) {
                        r.failures.append("Table @\(table.start) range round \(round): typing over the range changed nothing")
                    }
                    let typed = measurement(screenY(of: aboveEnd, in: c.textView).map { abs($0 - aboveBefore) },
                                            label: "range probe", result: &r)
                    c.textView.undoManager?.undo()
                    r.gestures += 1
                    await sleep(0.05)
                    let undone = measurement(screenY(of: aboveEnd, in: c.textView).map { abs($0 - aboveBefore) },
                                             label: "range undo probe", result: &r)
                    if max(typed, undone) >= 1 {
                        r.notes.append(String(format: "table @%d range round %d: line above moved %.1f / %.1f pt", table.start, round, typed, undone))
                    }
                    r.maxInteractionShift = max(r.maxInteractionShift, typed, undone)
                    if !c.textView.string.utf16.elementsEqual(original.utf16) {
                        r.failures.append("Table @\(table.start) range round \(round): Undo did not restore the source")
                    }
                }
                if let slowestTypeOver = typeOvers.max() {
                    r.notes.append(String(format: "table @%d range type-over ms: max %.1f", table.start, slowestTypeOver))
                }
            }
            c.textView.setSelectedRange(NSRange(location: table.bodyCell, length: 0))
            r.gestures += 1
            await sleep(0.05)
            if !cellHasKeyboard() { r.failures.append("Table @\(table.start): a caret in a body cell did not focus it") }
            c.window.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(NSRange(location: aboveEnd, length: 0))
            await sleep(0.05)
        }
        r.notes.append(String(format: "tables=%d slowest ↓ entry %.1fms", tables.count, slowest))
        // Control: the same keyboard hand-off between the editor and a plain text
        // view with no table code. Stalls here belong to the input method.
        let control = NSTextView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        c.window.contentView?.addSubview(control)
        var controlTimes: [Double] = []
        for _ in 0..<20 {
            for target in [control as NSView, c.textView as NSView] {
                let begin = CFAbsoluteTimeGetCurrent()
                c.window.makeFirstResponder(target)
                // Let the event loop finish the hand-off (the input method switches there).
                await sleep(0.001)
                controlTimes.append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
                await sleep(0.03)
            }
        }
        control.removeFromSuperview()
        let sortedControl = controlTimes.sorted()
        r.notes.append(String(format: "control focus hand-off ms (plain NSTextView ⇄ editor, 40×): median %.1f max %.1f over200=%d",
                              sortedControl[sortedControl.count / 2], sortedControl.last ?? 0, controlTimes.filter { $0 > 200 }.count))
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Navigating tables changed the source") }
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// the reference editor's table chrome in the app (doc 24 §8.5), through real window
    /// events: a pointer over a cell shows the grips and handle (read back
    /// through accessibility), the column grip takes its active look, a
    /// right-click on a cell's blank space opens Cell actions and Escape closes
    /// it. Nothing may edit the note or move the view. Snapshots are saved.
    private static func tableChrome(_ c: Context, _ r: inout ScenarioResult) async {
        let ns = c.textView.string as NSString
        let original = c.textView.string
        let renderedImage = NSAttributedString.Key("RenderedBlockImage")
        var start: Int?
        var cursor = 0
        var candidates: [Int] = []
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            if line.location > 0, next < ns.length, ns.substring(with: line).hasPrefix("|"),
               !(candidates.last.map { ns.lineRange(for: NSRange(location: $0, length: 0)).location == line.location } ?? false),
               ns.substring(with: ns.lineRange(for: NSRange(location: next, length: 0))).contains("---") {
                candidates.append(line.location)
            }
            cursor = next
        }
        QAPresentation.activateIfAllowed()
        QAPresentation.show(c.window)
        // A narrow table: the editor re-hovers at the REAL pointer after any
        // layout change, which a wide table's scroller triggers mid-replay
        // (WideTableHoverTests covers a wide table's hover, grip and z-order).
        let wideKey = NSAttributedString.Key("ScrollableBlockSourceID")
        for candidate in candidates.prefix(12) {
            c.textView.scrollRangeToVisible(NSRange(location: candidate, length: 0))
            for _ in 0..<30 {
                await sleep(0.1)
                if c.textView.textStorage?.attribute(renderedImage, at: candidate, effectiveRange: nil) != nil { break }
            }
            if c.textView.textStorage?.attribute(wideKey, at: candidate, effectiveRange: nil) != nil {
                r.notes.append("skipped the wide table at \(candidate)")
                continue
            }
            start = candidate
            break
        }
        guard let start else {
            r.failures.append("No narrow table to hover; use a table fixture")
            return
        }
        await sleep(0.3)
        guard let top = screenY(of: start, in: c.textView) else {
            r.failures.append("The table never laid out")
            return
        }
        // The chrome sits in a host over the text view (above page-look wide tables).
        func chrome() -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if String(describing: type(of: view)) == "TableChromeView" { return view }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(c.textView.superview ?? c.textView)
        }
        func menus() -> [NSView] { c.scrollView.subviews.filter { String(describing: type(of: $0)) == "TableMenuView" } }
        func send(_ type: NSEvent.EventType, at point: NSPoint, keyCode: UInt16 = 0) {
            let windowPoint = c.textView.convert(point, to: nil)
            let event: NSEvent?
            if type == .keyDown {
                let characters = [53: "\u{1b}", 125: "\u{F701}", 36: "\r"][Int(keyCode)] ?? ""
                event = NSEvent.keyEvent(with: .keyDown, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: c.window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            } else {
                event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1)
            }
            guard let event else { return }
            r.gestures += 1
            // A synthetic mouse-moved never reaches tracking areas; the window
            // server sends a real one to every `.mouseMoved` area under the
            // pointer, so the replay does what it would.
            if type == .mouseMoved {
                deliverToTrackingAreas(event, at: windowPoint, in: c.window)
            } else {
                c.window.sendEvent(event)
            }
        }
        func snapshot(_ name: String) {
            // The editor's own scroll view: the window's hosting view does not draw TextKit's layers.
            guard let output = ProcessInfo.processInfo.environment["PAGEFLOW_QA_OUTPUT_DIR"], let view = Optional(c.scrollView as NSView),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
        }
        let left = c.textView.textContainerOrigin.x + (c.textView.textContainer?.lineFragmentPadding ?? 0)
        // The table's top-left cell, inside its 10 pt left padding: blank space,
        // not a glyph. In the text view's own (flipped) coordinates: `top` is a window y.
        guard let tableTop = viewY(of: start, in: c.textView) else {
            r.failures.append("The table's fragment is not laid out")
            return
        }
        let blank = NSPoint(x: left + 4, y: tableTop + 12)
        let probe = screenY(of: start, in: c.textView)
        send(.mouseMoved, at: blank)
        await sleep(0.1)
        guard let view = chrome(), !view.isHidden else {
            let overlays = (c.textView.superview?.subviews ?? []).filter { String(describing: type(of: $0)) == "WideTableOverlay" }
                .map { NSStringFromRect($0.convert($0.bounds, to: c.textView)) }
            r.notes.append("no chrome: point=\(NSStringFromPoint(blank)) top=\(top) left=\(left) overlays(in text view)=\(overlays) textView.frame=\(NSStringFromRect(c.textView.frame)) visible=\(NSStringFromRect(c.textView.visibleRect)) window=\(NSStringFromPoint(c.textView.convert(blank, to: nil))) content=\(NSStringFromRect(c.window.contentLayoutRect)) chrome=\(chrome().map { "hidden=\($0.isHidden)" } ?? "none")")
            r.failures.append("A pointer over a cell showed no table chrome")
            snapshot("table-chrome-missing.png")
            return
        }
        snapshot("table-chrome-hover.png")
        let buttons = (view.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
        let labels = buttons.compactMap { $0.accessibilityLabel() }
        r.notes.append("chrome controls: \(labels)")
        r.measuredSamples += 1
        for expected in ["Column options", "Row options", "Drag to move table"] where !labels.contains(expected) {
            r.failures.append("The hover chrome has no \(expected) control")
        }
        if let grip = buttons.first(where: { $0.accessibilityLabel() == "Column options" }) {
            let frame = c.textView.convert(c.window.convertFromScreen(grip.accessibilityFrame()), from: nil)
            send(.mouseMoved, at: NSPoint(x: frame.midX, y: frame.midY))
            await sleep(0.1)
            snapshot("table-chrome-grip.png")
            if view.isHidden { r.failures.append("Moving onto the column grip hid the chrome") }
        }
        send(.rightMouseDown, at: blank)
        send(.rightMouseUp, at: blank)
        await sleep(0.15)
        guard let menu = menus().first else {
            r.failures.append("A right-click on a cell's blank space opened no Cell actions")
            snapshot("table-chrome-no-menu.png")
            return
        }
        r.measuredSamples += 1
        if menu.accessibilityLabel() != "Cell actions" { r.failures.append("The menu is \(menu.accessibilityLabel() ?? "unnamed"), not Cell actions") }
        let rows = ((menu.accessibilityChildren() as? [NSAccessibilityElement]) ?? []).compactMap { $0.accessibilityLabel() }
        r.notes.append("cell actions: \(rows)")
        r.notes.append("appearance editor=\(c.textView.effectiveAppearance.name.rawValue) menu=\(menu.effectiveAppearance.name.rawValue) "
            + "firstResponder=\(c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") key=\(c.window.isKeyWindow)")
        snapshot("table-chrome-cell-actions.png")
        if c.window.firstResponder !== menu { r.failures.append("Cell actions did not take the keyboard after a right-click") }
        // From the keyboard: ↓ ↓ Return runs Insert row below (Insert row above is disabled on the header).
        send(.keyDown, at: blank, keyCode: 125)
        send(.keyDown, at: blank, keyCode: 125)
        send(.keyDown, at: blank, keyCode: 36)
        await sleep(0.2)
        let inserted = !c.textView.string.utf16.elementsEqual(original.utf16)
        r.notes.append("keyboard Insert row below changed the note: \(inserted)")
        if !inserted { r.failures.append("↓ ↓ Return in Cell actions did not insert a row") }
        if inserted {
            c.textView.undoManager?.undo()
            await sleep(0.2)
            if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Undo did not remove the inserted row") }
        }
        // Again, and Escape closes it.
        send(.mouseMoved, at: blank)
        send(.rightMouseDown, at: blank)
        send(.rightMouseUp, at: blank)
        await sleep(0.15)
        if menus().isEmpty { r.failures.append("A second right-click opened no Cell actions") }
        let responderName = { c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil" }
        r.notes.append("before Escape: menus=\(menus().count) firstResponder=\(responderName())")
        send(.keyDown, at: blank, keyCode: 53)
        await sleep(0.1)
        r.notes.append("after Escape: menus=\(menus().count) firstResponder=\(responderName())")
        if !menus().isEmpty { r.failures.append("Escape did not close Cell actions") }
        // The press-and-drag loops read their events from the queue: post them, then press.
        func post(_ type: NSEvent.EventType, at point: NSPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: c.textView.convert(point, to: nil), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        // A column grip click selects the column and opens Column actions.
        send(.mouseMoved, at: blank)
        await sleep(0.1)
        if let grip = ((chrome()?.accessibilityChildren() as? [NSAccessibilityElement]) ?? []).first(where: { $0.accessibilityLabel() == "Column options" }) {
            let frame = c.textView.convert(c.window.convertFromScreen(grip.accessibilityFrame()), from: nil)
            let center = NSPoint(x: frame.midX, y: frame.midY)
            send(.mouseMoved, at: center)
            post(.leftMouseUp, at: center)
            send(.leftMouseDown, at: center)
            await sleep(0.15)
            let label = menus().first?.accessibilityLabel()
            r.notes.append("grip click opened: \(label ?? "nothing")")
            if label != "Column actions" { r.failures.append("A column grip click did not open Column actions") }
            send(.keyDown, at: center, keyCode: 53)
            await sleep(0.1)
        } else {
            r.failures.append("No column grip to click")
        }
        // A drag on the first column's right border sets its width, view-only.
        if let grid = c.textView.subviews.first(where: { String(describing: type(of: $0)) == "MarkdownTableGridView" }),
           let header = ((grid.accessibilityRows() as? [NSAccessibilityElement])?.first?.accessibilityChildren() as? [NSAccessibilityElement])?.first {
            let cell = c.textView.convert(c.window.convertFromScreen(header.accessibilityFrame()), from: nil)
            let border = NSPoint(x: cell.maxX, y: cell.midY)
            send(.mouseMoved, at: NSPoint(x: cell.midX, y: cell.midY))
            send(.mouseMoved, at: border)
            await sleep(0.05)
            post(.leftMouseDragged, at: NSPoint(x: border.x + 60, y: border.y))
            post(.leftMouseUp, at: NSPoint(x: border.x + 60, y: border.y))
            send(.leftMouseDown, at: border)
            await sleep(0.2)
            let widths = c.content.editorController.tableColumnWidths
            r.notes.append("widths after a 60 pt border drag: \(widths)")
            if widths.isEmpty { r.failures.append("A border drag set no column width") }
            if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("A column resize changed the file") }
            c.textView.undoManager?.undo()
            await sleep(0.2)
            if !c.content.editorController.tableColumnWidths.isEmpty { r.failures.append("Undo did not clear the column width") }
        } else {
            r.failures.append("No grid to resize (the cell session was not active)")
        }
        if let probe, let now = screenY(of: start, in: c.textView), abs(now - probe) >= 1 {
            r.failures.append(String(format: "The table moved %.1f pt while hovering and right-clicking", abs(now - probe)))
        }
        r.maxInteractionShift = max(r.maxInteractionShift, abs((screenY(of: start, in: c.textView) ?? top) - (probe ?? top)))
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Hovering or the menu changed the source") }
    }

    /// The selection bar (doc 24 §8.3): select a visible word 20 times; the
    /// bar must appear within a frame and sit above or below the selection,
    /// never over it. Then Bold from the bar must press Bold, a scroll must
    /// carry the bar with the selection, and a caret must hide it. A window
    /// snapshot is saved next to the report for review.
    private static func selectionBar(_ c: Context, _ r: inout ScenarioResult) async {
        let original = c.textView.string
        let ns = original as NSString
        let starts = visibleFragmentStarts(in: c.textView, limit: 40).filter { start in
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let text = ns.substring(with: line)
            return line.length > 30 && !text.hasPrefix("|") && !text.hasPrefix("```") && !text.hasPrefix("#") && !text.hasPrefix("$")
        }
        guard !starts.isEmpty else {
            r.failures.append("No visible prose line to select")
            return
        }
        func bar() -> NSView? {
            c.scrollView.subviews.first { String(describing: type(of: $0)).contains("SelectionBarView") }
        }
        func control(_ label: String) -> NSView? {
            bar()?.subviews.first { $0.accessibilityLabel() == label }
        }
        // The bar shows only in the key window (the reference editor hides it on blur).
        QAPresentation.activateIfAllowed()
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        guard c.window.isKeyWindow else {
            r.failures.append("The replay window never became key; the bar cannot show (another app kept focus)")
            return
        }
        var slowest = 0.0
        var unfocused = 0
        for round in 0..<20 {
            let start = starts[round % starts.count]
            let word = NSRange(location: start + 2, length: 6)
            // Another app may take focus while the replay runs: take it back,
            // and do not judge a round the window spent in the background.
            if !c.window.isKeyWindow {
                QAPresentation.activateIfAllowed()
                QAPresentation.show(c.window)
                await sleep(0.1)
            }
            guard c.window.isKeyWindow else {
                unfocused += 1
                continue
            }
            c.window.makeFirstResponder(c.textView)
            let begin = CFAbsoluteTimeGetCurrent()
            c.textView.setSelectedRange(word)
            let selectMilliseconds = (CFAbsoluteTimeGetCurrent() - begin) * 1000
            r.gestures += 1
            // A long note may still be styling in the background after open;
            // the bar's own cost is in PerfTrace (selectionBar.update / .state).
            var shown = false
            let deadline = CFAbsoluteTimeGetCurrent() + 3
            while CFAbsoluteTimeGetCurrent() < deadline {
                await sleep(0.005)
                if let bar = bar(), !bar.isHidden { shown = true; break }
                if !c.window.isKeyWindow { break }
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - begin) * 1000
            slowest = max(slowest, elapsed)
            PerfTrace.dump("bar round \(round)")
            if elapsed > 100 {
                r.notes.append(String(format: "round %d @%d: %.0f ms to the check, %.0f ms in setSelectedRange (shown=%@ key=%@)", round, word.location,
                                      elapsed, selectMilliseconds, shown ? "yes" : "no", c.window.isKeyWindow ? "yes" : "no"))
            }
            guard shown, let bar = bar() else {
                r.failures.append("Round \(round): the bar did not appear for a selection")
                if !c.window.isKeyWindow || round < 6 {
                    let responder = c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    let line = (c.textView.string as NSString).lineRange(for: word)
                    r.notes.append("diagnostic round \(round): line=\((c.textView.string as NSString).substring(with: line).prefix(60).debugDescription) "
                        + "bar=\(bar() != nil) hidden=\(bar()?.isHidden ?? true) key=\(c.window.isKeyWindow) "
                        + "responder=\(responder) selection=\(NSStringFromRange(c.textView.selectedRange())) "
                        + "scrollSubviews=\(c.scrollView.subviews.map { String(describing: type(of: $0)) })")
                }
                continue
            }
            let screen = c.textView.firstRect(forCharacterRange: word, actualRange: nil)
            let selection = c.scrollView.convert(c.window.convertFromScreen(screen), from: nil)
            r.measuredSamples += 1
            if bar.frame.intersects(selection) { r.failures.append("Round \(round): the bar covers the selection") }
        }
        r.notes.append(String(format: "bar visible within %.1f ms (slowest of %d focused rounds)", slowest, 20 - unfocused))
        if unfocused > 10 { r.failures.append("The window was in the background for \(unfocused) of 20 rounds") }
        // Bold from the bar.
        let word = NSRange(location: starts[0] + 2, length: 6)
        c.textView.setSelectedRange(word)
        await sleep(0.05)
        if let bold = control("Bold") {
            asOneEvent(c.textView.undoManager) { _ = bold.accessibilityPerformPress() }
            r.gestures += 1
            // A long note's state waits for the parse its restyle makes.
            for _ in 0..<30 where c.content.formatState.bold != true { await sleep(0.05) }
            if c.content.formatState.bold != true { r.failures.append("Bold from the bar did not press Bold") }
        } else {
            r.failures.append("No Bold control on the bar")
        }
        // Snapshot for review.
        if let output = ProcessInfo.processInfo.environment["PAGEFLOW_QA_OUTPUT_DIR"],
           let view = c.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("selection-bar.png"))
        }
        // A scroll carries the bar with the selection.
        if let before = bar()?.frame {
            ScrollTrace.stamp("qa.wheel")
            _ = wheel(c.scrollView, deltaY: -40)
            r.gestures += 1
            await sleep(0.1)
            if let after = bar()?.frame, abs((before.minY - after.minY).magnitude - 40) > 2, !(bar()?.isHidden ?? true) {
                r.notes.append(String(format: "bar moved %.1f pt for a 40 pt scroll", before.minY - after.minY))
            }
        }
        // A caret hides it.
        c.textView.setSelectedRange(NSRange(location: word.location, length: 0))
        await sleep(0.05)
        if let bar = bar(), !bar.isHidden { r.failures.append("A collapsed caret left the bar showing") }
        c.textView.undoManager?.undo()
        await sleep(0.1)
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Undo did not restore the source") }
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Images selected as a whole (doc 26 §13.2): click each visible image
    /// ×20 through the window's own event dispatch, ↓ then ↑ through the first
    /// 10 images ×20, and a Find-style selection of alt text. Each must select
    /// the image without showing its Markdown or moving the line below it, the
    /// source must not change, and no gesture may hold the main thread 100 ms.
    private static func imageSelect(_ c: Context, _ r: inout ScenarioResult) async {
        let original = c.textView.string
        let ns = original as NSString
        guard let storage = c.textView.textStorage else {
            r.failures.append("No native text storage")
            return
        }
        let renderedKey = NSAttributedString.Key("RenderedBlockImage")
        let sourceKey = NSAttributedString.Key("MarkdownBlockSourceRange")
        let kindKey = NSAttributedString.Key("MarkdownBlockKind")
        let revealedKey = NSAttributedString.Key("LatexBlockOffsetY")
        /// Rendered images anchored in `range`: the anchor and its token
        /// (the anchor-relative payload: how far the token starts before it).
        func images(in range: NSRange) -> [(anchor: Int, token: NSRange)] {
            var found: [(Int, NSRange)] = []
            let scope = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            storage.enumerateAttribute(sourceKey, in: scope) { value, run, _ in
                guard let value = value as? NSValue,
                      storage.attribute(kindKey, at: run.location, effectiveRange: nil) as? String == "image",
                      storage.attribute(renderedKey, at: run.location, effectiveRange: nil) != nil else { return }
                let relative = value.rangeValue
                found.append((run.location, NSRange(location: run.location - relative.location, length: relative.length)))
            }
            return found
        }
        func revealed(_ token: NSRange) -> Bool {
            NSMaxRange(token) <= storage.length && storage.attribute(revealedKey, at: token.location, effectiveRange: nil) != nil
        }
        func lineBelow(_ token: NSRange) -> Int? {
            let next = NSMaxRange(ns.paragraphRange(for: token))
            return next < ns.length ? next : nil
        }
        func ringShown() -> Bool {
            c.textView.subviews.contains { String(describing: type(of: $0)) == "ImageChromeView" && !$0.isHidden }
        }
        var slowest = 0.0
        func timed(_ gesture: () -> Void) {
            let start = CFAbsoluteTimeGetCurrent()
            gesture()
            slowest = max(slowest, (CFAbsoluteTimeGetCurrent() - start) * 1000)
            r.gestures += 1
        }
        /// After a gesture that should select `token`: selected, still drawn, line below in place.
        func check(_ label: String, token: NSRange, belowY: CGFloat?, below: Int?) {
            if c.textView.selectedRange() != token {
                r.failures.append("\(label): selection \(NSStringFromRange(c.textView.selectedRange())) is not the image \(NSStringFromRange(token))")
            }
            if revealed(token) { r.failures.append("\(label): the image's Markdown shows") }
            if !ringShown() { r.failures.append("\(label): no ring") }
            if let below, let belowY {
                let moved = measurement(viewY(of: below, in: c.textView).map { abs($0 - belowY) }, label: "\(label) line below", result: &r)
                if moved >= 1 { r.notes.append(String(format: "%@: the line below moved %.1f pt", label, moved)) }
                r.maxInteractionShift = max(r.maxInteractionShift, moved)
            }
        }

        QAPresentation.activateIfAllowed()
        // Tall enough for several images at once.
        if let screen = c.window.screen?.visibleFrame {
            c.window.setFrame(NSRect(x: screen.minX + 20, y: screen.minY + 20, width: min(1200, screen.width - 40),
                                     height: min(1100, screen.height - 40)), display: true)
        }
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        c.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        await sleep(0.3)
        let meter = StallMeter()
        meter.start()

        // 1. Clicks, through NSWindow.sendEvent: the press reaches the text view
        //    the way a real one does and is tracked to its queued mouse-up.
        let viewport = c.textView.textLayoutManager?.textViewportLayoutController.viewportRange.flatMap { range -> NSRange? in
            guard let tcm = c.textView.textLayoutManager?.textContentManager else { return nil }
            let start = tcm.offset(from: tcm.documentRange.location, to: range.location)
            return NSRange(location: start, length: tcm.offset(from: range.location, to: range.endLocation))
        } ?? NSRange(location: 0, length: min(ns.length, 20_000))
        let clip = c.scrollView.contentView.convert(c.scrollView.contentView.bounds, to: nil)
        // Where each image draws: the engine's ring around it, 5 pt out, once selected.
        var targets: [(anchor: Int, token: NSRange, point: NSPoint)] = []
        for image in images(in: viewport) {
            c.textView.setSelectedRange(image.token)
            guard let ring = c.textView.subviews.first(where: { String(describing: type(of: $0)) == "ImageChromeView" && !$0.isHidden })
            else {
                r.notes.append("image @\(image.anchor): no ring after selecting it")
                continue
            }
            // The visible part of the image, clear of the window's chrome.
            let rect = c.textView.convert(ring.frame.insetBy(dx: 5, dy: 5), to: nil).intersection(clip.insetBy(dx: 0, dy: 60))
            guard rect.width > 40, rect.height > 40 else {
                r.notes.append("image @\(image.anchor): too little of it is visible to click")
                continue
            }
            targets.append((image.anchor, image.token, NSPoint(x: rect.midX, y: rect.midY)))
        }
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await sleep(0.05)
        r.notes.append("click targets: \(targets.count) visible rendered images")
        if targets.isEmpty { r.failures.append("No fully visible rendered image to click; use an image fixture") }
        let belowTops = targets.map { target in lineBelow(target.token).flatMap { viewY(of: $0, in: c.textView) } }
        for round in 0..<20 {
            for (index, target) in targets.enumerated() {
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: target.point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: target.point, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: c.window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                    r.failures.append("Could not create mouse events")
                    return
                }
                NSApp.postEvent(up, atStart: false)
                timed { c.window.sendEvent(down) }
                await sleep(0.03)
                check("click round \(round) image @\(target.anchor)", token: target.token, belowY: belowTops[index], below: lineBelow(target.token))
            }
        }

        // 2. ↓ from the top of the note through the first 10 images, then ↑ back.
        var downs: [Double] = []
        for round in 0..<20 {
            c.textView.setSelectedRange(NSRange(location: 0, length: 0))
            c.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            await sleep(0.05)
            var selected = 0
            var presses = 0
            var forward = true
            while presses < 600 {
                let before = c.textView.selectedRange()
                // The line below the image the caret is heading into, in document coordinates.
                let probe = images(in: NSRange(location: before.location, length: min(4_000, ns.length - before.location)))
                    .first { $0.token.location > before.location }
                let probeLine = probe.flatMap { lineBelow($0.token) }
                let probeY = probeLine.flatMap { viewY(of: $0, in: c.textView) }
                let start = CFAbsoluteTimeGetCurrent()
                timed { c.textView.doCommand(by: forward ? #selector(NSResponder.moveDown(_:)) : #selector(NSResponder.moveUp(_:))) }
                if forward { downs.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
                presses += 1
                await sleep(0.008)
                let selection = c.textView.selectedRange()
                if selection == before { break }
                if let image = images(in: ns.paragraphRange(for: NSRange(location: min(selection.location, ns.length), length: 0)))
                    .first(where: { $0.token == selection }) {
                    if forward {
                        selected += 1
                        check("↓ round \(round) image @\(image.anchor)", token: image.token,
                              belowY: probe?.token == image.token ? probeY : nil, below: probeLine)
                        if selected == 10 { forward = false }
                    }
                } else if revealed(ns.paragraphRange(for: NSRange(location: min(selection.location, ns.length), length: 0))) {
                    r.failures.append("Arrow round \(round): a caret sits in a revealed image line")
                }
                if !forward, selection.location == 0 { break }
            }
            if selected < 10 { r.failures.append("Arrow round \(round): ↓ selected \(selected) of 10 images in \(presses) presses") }
        }
        if !downs.isEmpty {
            let sorted = downs.sorted()
            r.notes.append(String(format: "↓ ms: median %.2f, p95 %.2f, max %.2f over %d presses",
                                  sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0, sorted.count))
        }

        // 3. Find selects a match in an image's alt text: the image is selected.
        if let target = targets.first {
            let token = target.token
            let alt = NSRange(location: token.location + 2, length: min(4, max(1, token.length - 4)))
            c.textView.scrollRangeToVisible(token)
            await sleep(0.05)
            let belowY = lineBelow(token).flatMap { viewY(of: $0, in: c.textView) }
            timed { c.textView.setSelectedRange(alt) }
            await sleep(0.05)
            check("find in alt text", token: token, belowY: belowY, below: lineBelow(token))
        }

        meter.stop()
        r.notes.append(String(format: "slowest gesture %.1f ms; main thread longest stall %.1f ms, %d stalls over 16 ms", slowest,
                              meter.longest, meter.stalls))
        if slowest > 100 { r.failures.append(String(format: "A gesture held the main thread %.0f ms (bar: 100 ms)", slowest)) }
        let shown = images(in: NSRange(location: 0, length: storage.length)).filter { revealed($0.token) }
        if !shown.isEmpty { r.failures.append("\(shown.count) images show their Markdown at the end") }
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("The gestures changed the source") }
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Wrapping cells (doc 24 §8.2): in the first narrow table, type into a
    /// body cell until it wraps onto several lines. After every keystroke the
    /// grid must end above the next paragraph (no overlap, not even for a
    /// frame) and nothing may scroll unasked. Cleanup is Undo.
    private static func tableWrapType(_ c: Context, _ r: inout ScenarioResult) async {
        let ns = c.textView.string as NSString
        let original = c.textView.string
        var cursor = 0
        var target: (start: Int, end: Int, cell: Int)?
        while target == nil, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let next = NSMaxRange(line)
            guard next < ns.length else { break }
            let separator = ns.lineRange(for: NSRange(location: next, length: 0))
            let header = ns.substring(with: line)
            if line.location > 0, header.hasPrefix("|"), header.components(separatedBy: "|").count <= 6,
               ns.substring(with: separator).hasPrefix("|"), ns.substring(with: separator).contains("---") {
                var end = NSMaxRange(separator)
                while end < ns.length, ns.substring(with: ns.lineRange(for: NSRange(location: end, length: 0))).hasPrefix("|") {
                    end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0)))
                }
                if NSMaxRange(separator) < end, end < ns.length { target = (line.location, end, NSMaxRange(separator) + 2) }
                cursor = end
                continue
            }
            cursor = next
        }
        guard let target else {
            r.failures.append("No narrow table with text below it; use a table fixture")
            return
        }
        ScrollTrace.stamp("qa.centre")
        c.textView.scrollRangeToVisible(NSRange(location: target.start, length: 0))
        await sleep(0.4)
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: target.cell, length: 0))
        await sleep(0.1)
        guard let cell = c.window.firstResponder as? NSTextView, String(describing: type(of: cell)).contains("TableCellTextView") else {
            r.failures.append("A caret in the table did not focus a cell")
            return
        }
        cell.setSelectedRange(NSRange(location: (cell.string as NSString).length, length: 0))
        func gridBottom() -> CGFloat? {
            var stack: [NSView] = [c.textView]
            if let container = c.textView.superview { stack.append(container) }
            while let view = stack.popLast() {
                if String(describing: type(of: view)).contains("MarkdownTableGridView") {
                    return view.convert(view.bounds, to: c.textView).maxY
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }
        func textTop(_ location: Int) -> CGFloat? {
            guard let tlm = c.textView.textLayoutManager, let tcm = tlm.textContentManager,
                  let place = tcm.location(tcm.documentRange.location, offsetBy: location),
                  let fragment = tlm.textLayoutFragment(for: place), fragment.state == .layoutAvailable,
                  let line = fragment.textLineFragments.first else { return nil }
            return c.textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        }
        var total = 0.0
        var slowest = 0.0
        var worstOverlap: CGFloat = 0
        let words = 40
        for index in 0..<words {
            let start = CFAbsoluteTimeGetCurrent()
            cell.insertText(index % 6 == 5 ? "wrapping " : "word ", replacementRange: cell.selectedRange())
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            total += elapsed
            slowest = max(slowest, elapsed)
            r.gestures += 1
            // A table that turns wide moves its grid into an overlay on the next turn.
            var waited = 0
            while gridBottom() == nil, waited < 5 {
                await sleep(0.01)
                waited += 1
            }
            if c.window.firstResponder !== cell { r.failures.append("keystroke \(index): the cell lost the keyboard") }
            if let bottom = gridBottom(), let next = nextParagraphTop(after: target.start, in: c.textView, top: textTop) {
                r.measuredSamples += 1
                let overlap = bottom - next
                worstOverlap = max(worstOverlap, overlap)
                if overlap > 0.5 { r.failures.append(String(format: "keystroke %d: grid overlaps the text below by %.1fpt", index, overlap)) }
            } else {
                r.failures.append("keystroke \(index): no grid or no laid-out text below the table")
            }
            await sleep(0.016)
        }
        r.perKeyMilliseconds = total / Double(words)
        r.notes.append(String(format: "wrap typing: mean %.1fms slowest %.1fms worst overlap %.1fpt", total / Double(words), slowest, worstOverlap))
        // Cleanup: leave the cell, then undo the typing runs.
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await sleep(0.6)
        var undos = 0
        while !c.textView.string.utf16.elementsEqual(original.utf16), c.textView.undoManager?.canUndo == true, undos < 100 {
            c.textView.undoManager?.undo()
            undos += 1
        }
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Undo did not restore the source") }
        r.notes.append("undo steps to restore: \(undos)")
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// The top of the first non-blank line after the table that starts at `start`.
    private static func nextParagraphTop(after start: Int, in textView: NSTextView, top: (Int) -> CGFloat?) -> CGFloat? {
        let ns = textView.string as NSString
        var cursor = start
        while cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let text = ns.substring(with: line)
            if !text.hasPrefix("|"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return top(line.location) }
            cursor = NSMaxRange(line)
        }
        return nil
    }

    /// Editing math: for each of the first six `$$` blocks, scroll it to the
    /// middle of the viewport, put the caret inside (the block reveals its
    /// source), type eight characters, then leave (it renders again). A line
    /// above the block is the probe; it must not move at any step, and it must
    /// be back where it started once the caret has left.
    private static func mathEdit(_ c: Context, _ r: inout ScenarioResult) async {
        let ns = c.textView.string as NSString
        var blocks: [Int] = []
        var cursor = 0
        while blocks.count < 6 {
            let found = ns.range(of: "$$", range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { break }
            let line = ns.lineRange(for: NSRange(location: found.location, length: 0))
            let close = ns.range(of: "$$", range: NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found)))
            guard close.location != NSNotFound else { break }
            if ns.substring(with: line).trimmingCharacters(in: .whitespaces).hasPrefix("$$") { blocks.append(found.location) }
            cursor = NSMaxRange(close)
        }
        guard !blocks.isEmpty else {
            r.failures.append("No $$ block to measure; use a math fixture or choose another scenario")
            return
        }
        for start in blocks {
            // Setup is navigation, measured separately from editing. Wait for
            // two stable visible samples before taking a fixed source probe.
            let setupStart = CFAbsoluteTimeGetCurrent()
            let setupDeadline = setupStart + 2
            var setupAttempts = 0
            var stableTicks = 0
            var previousTarget: MathProbeGeometry?
            var previousClip: NSRect?
            while CFAbsoluteTimeGetCurrent() < setupDeadline {
                setupAttempts += 1
                if let geometry = mathProbeGeometry(at: start, in: c.textView) {
                    let clip = c.scrollView.contentView.bounds
                    let centreDelta = geometry.lineFrame.midY - geometry.viewport.midY
                    if geometry.isVisible && abs(centreDelta) < 24 {
                        if let previousTarget, let previousClip,
                           previousTarget.lineRange == geometry.lineRange,
                           previousTarget.source.utf16.elementsEqual(geometry.source.utf16),
                           abs(previousTarget.lineFrame.minX - geometry.lineFrame.minX) < 0.1,
                           abs(previousTarget.lineFrame.minY - geometry.lineFrame.minY) < 0.1,
                           abs(previousTarget.lineFrame.width - geometry.lineFrame.width) < 0.1,
                           abs(previousTarget.lineFrame.height - geometry.lineFrame.height) < 0.1,
                           abs(previousClip.minX - clip.minX) < 0.1,
                           abs(previousClip.minY - clip.minY) < 0.1,
                           abs(previousClip.width - clip.width) < 0.1,
                           abs(previousClip.height - clip.height) < 0.1 {
                            stableTicks += 1
                        } else {
                            stableTicks = 1
                        }
                        previousTarget = geometry
                        previousClip = clip
                    } else {
                        stableTicks = 0
                        previousTarget = nil
                        previousClip = nil
                        ScrollTrace.stamp("qa.centre")
                        c.scrollView.contentView.scroll(to: NSPoint(x: clip.origin.x, y: max(0, clip.origin.y + centreDelta)))
                        c.scrollView.reflectScrolledClipView(c.scrollView.contentView)
                    }
                } else {
                    stableTicks = 0
                    previousTarget = nil
                    previousClip = nil
                    ScrollTrace.stamp("qa.centre.missingLayout")
                    c.textView.scrollRangeToVisible(NSRange(location: start, length: 0))
                }
                r.notes.append(mathGeometryDiagnostic("block @\(start) setup attempt \(setupAttempts) stableTicks=\(stableTicks)", location: start, in: c))
                if stableTicks >= 2 { break }
                let remaining = setupDeadline - CFAbsoluteTimeGetCurrent()
                if remaining > 0 { await sleep(min(0.1, remaining)) }
            }
            let setupMilliseconds = (CFAbsoluteTimeGetCurrent() - setupStart) * 1000
            r.notes.append(String(format: "block @%d setup %.1fms attempts=%d stableTicks=%d deadline=2000ms", start, setupMilliseconds, setupAttempts, stableTicks))
            r.notes.append(mathGeometryDiagnostic("block @\(start) before target", location: start, in: c))
            guard stableTicks >= 2, let targetGeometry = mathProbeGeometry(at: start, in: c.textView), targetGeometry.isVisible else {
                r.failures.append("Block @\(start): target not visibly stable before the 2s setup deadline")
                continue
            }
            guard let probe = visibleFragmentStarts(in: c.textView, limit: 40).last(where: {
                $0 < start && mathProbeGeometry(at: $0, in: c.textView)?.isVisible == true
            }), let initialProbe = mathProbeGeometry(at: probe, in: c.textView), initialProbe.isVisible else {
                r.failures.append("Block @\(start): no visible text-line probe above it")
                continue
            }
            r.notes.append(mathGeometryDiagnostic("block @\(start) before probe", location: probe, in: c))
            let probeStart = initialProbe.screenY
            var probeLast = probeStart
            func step(_ label: String) -> CGFloat {
                r.notes.append(mathGeometryDiagnostic("block @\(start) \(label) target", location: start, in: c))
                r.notes.append(mathGeometryDiagnostic("block @\(start) \(label) probe", location: probe, in: c))
                guard let geometry = mathProbeGeometry(at: probe, in: c.textView), geometry.isVisible else {
                    r.failures.append("Block @\(start) \(label): missing, invalid or offscreen text-line probe")
                    return 0
                }
                let now = geometry.screenY
                r.measuredSamples += 1
                let delta = abs(now - probeLast)
                probeLast = now
                if delta >= 1 { r.notes.append("block @\(start) \(label): probe moved \(String(format: "%.1f", delta))pt") }
                return delta
            }
            let original = c.textView.string
            let inside = start + 2
            c.textView.setSelectedRange(NSRange(location: inside, length: 0))
            r.gestures += 1
            await sleep(0.1)
            r.maxInteractionShift = max(r.maxInteractionShift, step("enter"))
            var typeShift: CGFloat = 0
            for _ in 0..<8 {
                c.textView.insertText("x", replacementRange: c.textView.selectedRange())
                r.gestures += 1
                await sleep(0.016)
                typeShift = max(typeShift, step("type"))
            }
            r.maxInteractionShift = max(r.maxInteractionShift, typeShift)
            let expected = (original as NSString).replacingCharacters(in: NSRange(location: inside, length: 0),
                                                                      with: String(repeating: "x", count: 8))
            guard c.textView.string.utf16.elementsEqual(expected.utf16) else {
                r.failures.append("Block @\(start): typing changed unexpected source")
                return
            }
            c.textView.insertText("", replacementRange: NSRange(location: inside, length: 8))
            if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Block @\(start): source did not round-trip") }
            await sleep(0.05)
            c.textView.setSelectedRange(NSRange(location: probe, length: 0))
            r.gestures += 1
            await sleep(0.1)
            r.maxInteractionShift = max(r.maxInteractionShift, step("leave"))
            if let end = mathProbeGeometry(at: probe, in: c.textView), end.isVisible, abs(end.screenY - probeStart) >= 1 {
                r.notes.append("block @\(start) net: probe ended \(String(format: "%.1f", end.screenY - probeStart))pt from where it started")
            }
        }
        let drift = await idleDrift(c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    private struct MathProbeGeometry {
        let fragmentRange: NSRange
        let lineRange: NSRange
        let fragmentFrame: NSRect
        let lineFrame: NSRect
        let viewport: NSRect
        let screenY: CGFloat
        let source: String

        var isVisible: Bool {
            [lineFrame.minY, lineFrame.maxY, viewport.minY, viewport.maxY, screenY].allSatisfy(\.isFinite)
                && lineFrame.height > 0 && viewport.height > 0
                && lineFrame.maxY > viewport.minY && lineFrame.minY < viewport.maxY
        }
    }

    /// Uses the actual text line, including wrapped paragraphs; never forces layout.
    private static func mathProbeGeometry(at offset: Int, in textView: NSTextView) -> MathProbeGeometry? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: offset),
              let fragment = tlm.textLayoutFragment(for: location), fragment.state == .layoutAvailable,
              let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false),
              let elementRange = fragment.textElement?.elementRange,
              line.characterRange.location != NSNotFound else { return nil }
        let elementStart = tcm.offset(from: tcm.documentRange.location, to: elementRange.location)
        let fragmentStart = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        let fragmentEnd = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.endLocation)
        let lineRange = NSRange(location: elementStart + line.characterRange.location, length: line.characterRange.length)
        let ns = textView.string as NSString
        guard elementStart >= 0, fragmentStart >= 0, fragmentEnd >= fragmentStart,
              lineRange.location >= 0, NSMaxRange(lineRange) <= ns.length else { return nil }
        let origin = textView.textContainerOrigin
        let fragmentFrame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        let lineFrame = line.typographicBounds.offsetBy(dx: fragmentFrame.minX, dy: fragmentFrame.minY)
        return MathProbeGeometry(fragmentRange: NSRange(location: fragmentStart, length: fragmentEnd - fragmentStart),
            lineRange: lineRange, fragmentFrame: fragmentFrame, lineFrame: lineFrame,
            viewport: textView.visibleRect, screenY: textView.convert(lineFrame, to: nil).minY,
            source: ns.substring(with: lineRange))
    }

    private static func mathGeometryDiagnostic(_ label: String, location: Int, in c: Context) -> String {
        let prefix = "\(label) @\(location) clip=\(NSStringFromRect(c.scrollView.contentView.bounds)) selection=\(NSStringFromRange(c.textView.selectedRange()))"
        guard let sample = mathProbeGeometry(at: location, in: c.textView) else { return prefix + " geometry=missing" }
        return prefix + " visible=\(sample.isVisible) viewport=\(NSStringFromRect(sample.viewport)) fragment=\(NSStringFromRange(sample.fragmentRange)) frame=\(NSStringFromRect(sample.fragmentFrame)) line=\(NSStringFromRange(sample.lineRange)) frame=\(NSStringFromRect(sample.lineFrame)) windowY=\(sample.screenY) source=\(String(reflecting: sample.source))"
    }

    /// Six native formatting commands followed by six Undo actions. A fixed
    /// readable line must survive the exact-source round trip and idle.
    private static func formatBurst(_ c: Context, _ r: inout ScenarioResult) async {
        guard let undo = c.textView.undoManager else { r.failures.append("No formatting Undo manager"); return }
        let original = c.textView.string
        guard let probe = ReadableTextLineProbe.capture(in: c.textView) else {
            r.failures.append("No fully visible readable source line before formatting")
            return
        }
        r.notes.append("format scope: six commands plus six Undo actions, exact-source roundtrip; fixed line \(NSStringFromRange(probe.range)) windowY=\(probe.windowY)")
        r.notes.append(mathGeometryDiagnostic("format before witness", location: probe.range.location, in: c))
        var slowest = 0.0
        var presses: [String] = []
        for key in ["b", "b", "u", "u", "i", "i"] {
            c.textView.selectAll(nil)
            await sleep(0.05)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: c.window.windowNumber, context: nil, characters: key,
                                               charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else {
                r.failures.append("Could not create formatting key event")
                return
            }
            let originBefore = c.scrollView.contentView.bounds.origin.y
            ScrollTrace.reset(keepingBaselines: true)
            let start = CFAbsoluteTimeGetCurrent()
            var handled = false
            asOneEvent(c.textView.undoManager) { handled = c.textView.performKeyEquivalent(with: event) }
            if !handled { r.failures.append("Formatting command \(key) was not handled") }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            slowest = max(slowest, elapsed)
            presses.append(String(format: "⌘%@ %.0fms", key.uppercased(), elapsed))
            PerfTrace.dump(String(format: "⌘%@ %.0fms", key.uppercased(), elapsed))
            r.gestures += 1
            let originAfterPress = c.scrollView.contentView.bounds.origin.y
            await sleep(0.25)
            let originSettled = c.scrollView.contentView.bounds.origin.y
            if abs(originAfterPress - originBefore) >= 1 || abs(originSettled - originBefore) >= 1 {
                let movers = ScrollTrace.snapshot().recent.suffix(6).map { "\($0.mutator ?? "?") Δ\(String(format: "%.1f", $0.delta))" }
                r.notes.append(String(format: "⌘%@: origin %+.1f after the press, %+.1f after idle passes; movers: %@",
                                      key.uppercased(), originAfterPress - originBefore, originSettled - originBefore, movers.joined(separator: ", ")))
            }
        }
        r.perKeyMilliseconds = slowest
        r.notes.append("presses: " + presses.joined(separator: ", "))
        // Toggle pairs can fold pre-existing spans; geometry is compared only
        // after Undo restores identical source, without content-key matching.
        let lengthDelta = abs((c.textView.string as NSString).length - (original as NSString).length)
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.notes.append("document differs after on/off of each style (length delta \(lengthDelta))") }
        for _ in 0..<6 {
            guard undo.canUndo else { r.failures.append("Formatting registered insufficient Undo steps"); return }
            undo.undo()
            r.gestures += 1
        }
        await sleep(0.1)
        guard c.textView.string.utf16.elementsEqual(original.utf16) else {
            r.failures.append("Formatting Undo did not restore the exact UTF16 source")
            return
        }
        r.notes.append(mathGeometryDiagnostic("format restored witness", location: probe.range.location, in: c))
        r.maxInteractionShift = measurement(probe.resample(in: c.textView).map { abs($0.windowY - probe.windowY) },
                                           label: "format roundtrip fixed source-line probe", result: &r)
        let drift = await idleDrift(probe, in: c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Undo: ⌘A ⌘B is one undo step that restores the exact document, and redo
    /// re-applies it; a typed character undoes on its own afterwards.
    private static func undoCheck(_ c: Context, _ r: inout ScenarioResult) async {
        guard let undo = c.textView.undoManager else { r.failures.append("No Undo manager"); return }
        let original = c.textView.string
        let pristine = (try? String(contentsOfFile: ProcessInfo.processInfo.environment["PAGEFLOW_QA_DOC"] ?? "", encoding: .utf8)) ?? ""
        r.notes.append("lengths: file \((pristine as NSString).length), at start \((original as NSString).length), canUndo before \(undo.canUndo)")
        c.window.makeFirstResponder(c.textView)
        guard let probe = ReadableTextLineProbe.capture(in: c.textView) else {
            r.failures.append("No fully visible readable source line before Undo formatting")
            return
        }
        r.notes.append("Undo scope: original versus exact-source restored state; fixed line \(NSStringFromRange(probe.range)) windowY=\(probe.windowY)")
        r.notes.append(mathGeometryDiagnostic("Undo before witness", location: probe.range.location, in: c))
        c.textView.selectAll(nil)
        await sleep(0.05)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: c.window.windowNumber, context: nil, characters: "b",
                                           charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 0) else { r.failures.append("Could not create Undo formatting event"); return }
        var handled = false
        asOneEvent(undo) { handled = c.textView.performKeyEquivalent(with: event) }
        guard handled else { r.failures.append("Undo formatting command was not handled"); return }
        r.gestures += 1
        await sleep(0.3)
        r.notes.append("undo grouping level after ⌘B: \(undo.groupingLevel), canUndo \(undo.canUndo)")
        let formatted = c.textView.string
        if formatted.utf16.elementsEqual(original.utf16) { r.failures.append("⌘B changed nothing"); return }
        guard undo.canUndo else { r.failures.append("Formatting registered no Undo"); return }
        let originBefore = c.scrollView.contentView.bounds.origin.y
        ScrollTrace.reset(keepingBaselines: true)
        let start = CFAbsoluteTimeGetCurrent()
        undo.undo()
        r.perKeyMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        r.gestures += 1
        await sleep(0.3)
        let scrolled = c.scrollView.contentView.bounds.origin.y - originBefore
        // The origin may move to keep the reader's line in place (the content
        // above it changes height when markers go); the line is what is judged.
        if abs(scrolled) >= 1 {
            let movers = ScrollTrace.snapshot().recent.suffix(4).map { "\($0.mutator ?? "?") Δ\(String(format: "%.1f", $0.delta))" }
            r.notes.append(String(format: "undo moved the scroll origin %+.1fpt; movers: %@", scrolled, movers.joined(separator: ", ")))
        }
        guard c.textView.string.utf16.elementsEqual(original.utf16) else {
            r.failures.append("Undo did not restore the exact UTF16 document (after undo \((c.textView.string as NSString).length), formatted \((formatted as NSString).length), at start \((original as NSString).length))")
            return
        }
        r.notes.append(mathGeometryDiagnostic("Undo restored witness", location: probe.range.location, in: c))
        r.maxInteractionShift = measurement(probe.resample(in: c.textView).map { abs($0.windowY - probe.windowY) },
                                           label: "Undo roundtrip fixed source-line probe", result: &r)
        guard undo.canRedo else { r.failures.append("Undo registered no Redo"); return }
        undo.redo()
        r.gestures += 1
        await sleep(0.3)
        if !c.textView.string.utf16.elementsEqual(formatted.utf16) { r.failures.append("Redo did not re-apply the exact UTF16 format") }
        undo.undo()
        r.gestures += 1
        await sleep(0.3)
        guard c.textView.string.utf16.elementsEqual(original.utf16), probe.resample(in: c.textView) != nil else {
            r.failures.append("Typing control requires the exact restored source and fixed visible witness")
            return
        }
        let typingRange = NSRange(location: probe.range.location, length: 0)
        c.textView.setSelectedRange(typingRange)
        asOneEvent(undo) { c.textView.insertText("q", replacementRange: typingRange) }
        r.gestures += 1
        await sleep(0.2)
        undo.undo()
        r.gestures += 1
        await sleep(0.3)
        if !c.textView.string.utf16.elementsEqual(original.utf16) { r.failures.append("Undo after typing did not restore the exact UTF16 document") }
        let drift = await idleDrift(probe, in: c.textView)
        r.maxIdleDrift = max(r.maxIdleDrift, measurement(drift, label: "idle probe", result: &r))
    }

    /// Tab switch: leave for a fresh markdown tab and come back; the reading
    /// position must be exactly where it was.
    private static func switchRestore(_ c: Context, _ r: inout ScenarioResult) async {
        guard let originalID = c.tabManager.activeTabID, let before = anchor(in: c.textView) else {
            r.failures.append("No tab or reading anchor before switching")
            return
        }
        c.tabManager.newMarkdownDocument()
        r.gestures += 1
        await sleep(0.4)
        c.tabManager.selectTab(originalID)
        r.gestures += 1
        await sleep(0.4)
        if let after = anchor(in: c.textView) {
            r.maxInteractionShift = measurement(restoreError(before, after, in: c.textView),
                                                label: "tab restore probe", result: &r)
        } else {
            r.failures.append("No reading anchor after returning to the tab")
        }
    }

    // MARK: - Probes (public TextKit 2 API only; never forces layout)

    /// The first laid-out line inside the viewport, by text location, with its on-screen y.
    private static func anchor(in textView: NSTextView) -> (location: Int, screenY: CGFloat)? {
        guard let location = visibleFragmentStarts(in: textView, limit: 1).first,
              let y = screenY(of: location, in: textView) else { return nil }
        return (location, y)
    }

    private static func restoreError(_ before: (location: Int, screenY: CGFloat), _ after: (location: Int, screenY: CGFloat), in textView: NSTextView) -> CGFloat {
        if before.location == after.location { return abs(after.screenY - before.screenY) }
        // A different line is at the top: report the old anchor's displacement if it is still laid out, else a viewport height.
        if let y = screenY(of: before.location, in: textView) { return abs(y - before.screenY) }
        return textView.visibleRect.height
    }

    /// Text locations of the laid-out fragments intersecting the visible rect, top to bottom.
    /// Settings > Shortcuts, live: each menu item shows its row's key; a
    /// rebinding reaches the menus and the focused editor without a restart;
    /// the new key works through AppKit's own key dispatch and the old one no
    /// longer does. Needs a Markdown note with a line saying "Click a box".
    private static func shortcuts(_ c: Context, _ r: inout ScenarioResult) async {
        QAPresentation.activateIfAllowed()
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        let settings = SettingsManager.shared
        let saved = settings.customShortcuts
        defer { settings.customShortcuts = saved }
        settings.customShortcuts = [:]
        await sleep(0.5)
        func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let found = menuItem(title, in: item.submenu) { return found }
            }
            return nil
        }
        func shows(_ title: String, _ shortcut: ShortcutModel) -> Bool {
            guard let item = menuItem(title) else { return false }
            return item.keyEquivalent.lowercased() == shortcut.nsKeyEquivalent
                && item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == shortcut.nsModifierFlags
        }
        // 1. Every menu command with a row shows that row's key.
        let titles: [String: String] = [
            "format.bold": "Bold", "format.italic": "Italic", "format.underline": "Underline", "format.link": "Link",
            "format.heading": "Heading 1", "format.bulletedList": "Bulleted List", "format.quote": "Quote",
            "undo": "Undo", "redo": "Redo", "search": "Find…", "findNext": "Find Next", "save": "Save",
        ]
        for (id, title) in titles.sorted(by: { $0.key < $1.key }) {
            let shortcut = ShortcutModel.current(for: id)
            r.measuredSamples += 1
            if !shows(title, shortcut) {
                let item = menuItem(title)
                r.failures.append("\(title) shows \(item.map { "\($0.keyEquivalentModifierMask.rawValue)+\($0.keyEquivalent)" } ?? "no item"), not \(shortcut.displayString)")
            }
        }
        // 2. Rebind, live.
        settings.customShortcuts = [
            "format.bold": ShortcutModel(key: "b", control: true),
            "format.heading2": ShortcutModel(key: "2", control: true),
            "markdownComment": ShortcutModel(key: "j", option: true),
            "search": ShortcutModel(key: "f", control: true),
        ]
        let rebound = CFAbsoluteTimeGetCurrent()
        var waited = 0.0
        while !shows("Bold", ShortcutModel(key: "b", control: true)), waited < 4 {
            await sleep(0.1)
            waited = CFAbsoluteTimeGetCurrent() - rebound
        }
        r.measuredSamples += 1
        if shows("Bold", ShortcutModel(key: "b", control: true)) {
            r.notes.append(String(format: "the Format menu's Bold shows ⌃⌘B %.1f s after the rebinding, without a restart", waited))
        } else {
            r.failures.append("The Format menu did not pick up the new Bold key in 4 s")
        }
        await sleep(0.5)
        func press(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) async {
            let before = c.textView.string
            defer {
                let after = c.textView.string
                FileHandle.standardError.write(Data("QA-KEY \(flags.rawValue)+\(characters) responder=\(String(describing: c.window.firstResponder.map { type(of: $0) })) selection=\(c.textView.selectedRange()) changed=\(before != after) find=\(c.tabManager.showingSearch)\n".utf8))
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode) else { continue }
                NSApp.sendEvent(event)
            }
            r.gestures += 1
            await sleep(0.3)
        }
        func select(_ phrase: String) async -> Bool {
            let found = (c.textView.string as NSString).range(of: phrase)
            guard found.location != NSNotFound else { return false }
            c.window.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(found)
            await sleep(0.3)
            return true
        }
        guard await select("Click") else {
            r.failures.append("The note needs a line saying \"Click a box\"")
            return
        }
        // The old ⌘B does nothing now; the new ⌃⌘B bolds (the focused editor answers first).
        await press("b", 11, .command)
        r.measuredSamples += 1
        if c.textView.string.contains("**Click**") { r.failures.append("⌘B still bolds after Bold moved to ⌃⌘B") }
        await press("b", 11, [.command, .control])
        r.notes.append("⌃⌘B in the editor: \(c.textView.string.contains("**Click**") ? "bold" : "no change")")
        if !c.textView.string.contains("**Click**") { r.failures.append("⌃⌘B did not bold in the editor") }
        // The menu path: with the keyboard outside the text, the Format menu's key acts on the note.
        _ = await select("Click")
        c.window.makeFirstResponder(nil)
        await press("b", 11, [.command, .control])
        r.measuredSamples += 1
        r.notes.append("⌃⌘B through the menu: \(c.textView.string.contains("**Click**") ? "still bold" : "bold removed")")
        if c.textView.string.contains("**Click**") { r.failures.append("The Format menu's ⌃⌘B did not reach the note") }
        // Heading 2 on ⌃⌘2.
        _ = await select("Click")
        await press("2", 19, [.command, .control])
        let line = (c.textView.string as NSString).substring(with: (c.textView.string as NSString).lineRange(
            for: NSRange(location: (c.textView.string as NSString).range(of: "Click").location, length: 0)))
        r.measuredSamples += 1
        r.notes.append("⌃⌘2: \(line.debugDescription)")
        if !line.hasPrefix("## ") { r.failures.append("⌃⌘2 did not make a Heading 2") }
        // Comment on ⌥⌘J opens the composer; the old ⌥⌘M does not.
        func composerOpen() -> Bool {
            func find(_ view: NSView) -> Bool {
                String(describing: type(of: view)) == "CommentComposerView" || view.subviews.contains(where: find)
            }
            return find(c.scrollView)
        }
        // (Pressing the old ⌥⌘M would now reach the system's Minimize All.)
        let commentChords = c.content.editorController.keyBindings?[.comment] ?? []
        r.measuredSamples += 1
        r.notes.append("Comment's chords: \(commentChords.map { "\($0.option ? "⌥" : "")\($0.command ? "⌘" : "")\($0.key)" })")
        if commentChords != [MarkdownKeyChord("j", command: true, option: true)] {
            r.failures.append("The editor's Comment chords did not follow the rebinding: \(commentChords)")
        }
        _ = await select("Click")
        await sleep(0.3)   // the Heading 2 restyle settles
        await press("∆", 38, [.command, .option])
        r.notes.append("⌥⌘J: \(composerOpen() ? "composer open" : "nothing")")
        if !composerOpen() { r.failures.append("⌥⌘J did not open the comment composer") }
        await press("\u{1b}", 53, [])
        // Find on ⌃⌘F.
        c.tabManager.showingSearch = false
        c.window.makeFirstResponder(c.textView)
        await press("f", 3, [.command, .control])
        r.measuredSamples += 1
        r.notes.append("⌃⌘F: find bar \(c.tabManager.showingSearch ? "shown" : "not shown")")
        if !c.tabManager.showingSearch { r.failures.append("⌃⌘F did not open Find") }
        c.tabManager.showingSearch = false
    }

    /// Checklists, as a person reaches them: a click on a box (through the
    /// window, as AppKit dispatches it) ticks it and a second clears it; the
    /// toolbar's Checklist button (pressed through accessibility) turns the
    /// caret's line into a task; inside a table cell it must not silently do
    /// nothing. Needs a note with "- [ ] Buy milk" and a table.
    private static func checklist(_ c: Context, _ r: inout ScenarioResult) async {
        QAPresentation.activateIfAllowed()
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        let settings = SettingsManager.shared
        let pinned = (settings.isTopBarAlwaysVisible, settings.isFloatingToolbarAlwaysVisible)
        settings.isTopBarAlwaysVisible = true
        settings.isFloatingToolbarAlwaysVisible = true
        defer { (settings.isTopBarAlwaysVisible, settings.isFloatingToolbarAlwaysVisible) = pinned }
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await sleep(0.5)
        func line(containing marker: String) -> String? {
            let ns = c.textView.string as NSString
            let found = ns.range(of: marker)
            return found.location == NSNotFound ? nil : ns.substring(with: ns.lineRange(for: found))
        }
        // 1. A click on the box.
        guard let item = line(containing: "Buy milk"), item.hasPrefix("- [ ]") else {
            r.failures.append("The note needs a \"- [ ] Buy milk\" item")
            return
        }
        func boxPoint() -> NSPoint? {
            let ns = c.textView.string as NSString
            let lineStart = ns.range(of: "Buy milk").location
            let box = ns.range(of: "[", options: .backwards, range: NSRange(location: 0, length: lineStart))
            guard box.location != NSNotFound, let tlm = c.textView.textLayoutManager, let content = tlm.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: box.location),
                  let end = content.location(start, offsetBy: 3), let range = NSTextRange(location: start, end: end) else { return nil }
            var frame: NSRect?
            tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, rect, _, _ in
                frame = frame.map { $0.union(rect) } ?? rect
                return true
            }
            guard let frame else { return nil }
            let origin = c.textView.textContainerOrigin
            return c.textView.convert(NSPoint(x: frame.midX + origin.x, y: frame.midY + origin.y), to: nil)
        }
        func click(at point: NSPoint) {
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                                windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.05,
                                              windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
            else { return }
            // The up waits in the queue, so a press the text view tracks ends there instead of hanging.
            NSApp.postEvent(up, atStart: false)
            c.window.sendEvent(down)
            r.gestures += 1
        }
        guard let point = boxPoint() else {
            r.failures.append("The box has no layout")
            return
        }
        do {
            let ns = c.textView.string as NSString
            let box = ns.range(of: "[", options: .backwards, range: NSRange(location: 0, length: ns.range(of: "Buy milk").location))
            let attribute = c.textView.textStorage?.attribute(NSAttributedString.Key("TaskCheckbox"), at: box.location, effectiveRange: nil)
            let hit = c.window.contentView?.superview?.hitTest(point) ?? c.window.contentView?.hitTest(point)
            r.notes.append("before the click: box attribute \(String(describing: attribute)), point \(point), hit \(hit.map { String(describing: type(of: $0)) } ?? "nil"), selection \(c.textView.selectedRange()), first responder \(String(describing: c.window.firstResponder.map { type(of: $0) }))")
        }
        click(at: point)
        await sleep(0.4)
        let ticked = line(containing: "Buy milk") ?? ""
        r.measuredSamples += 1
        r.notes.append("checkbox click: \(item.debugDescription) → \(ticked.debugDescription)")
        if !ticked.hasPrefix("- [x]") { r.failures.append("A click on the box did not tick it: \(ticked.debugDescription)") }
        if let again = boxPoint() {
            click(at: again)
            await sleep(0.4)
            let cleared = line(containing: "Buy milk") ?? ""
            r.notes.append("second click: → \(cleared.debugDescription)")
            if !cleared.hasPrefix("- [ ]") { r.failures.append("A second click did not clear the box: \(cleared.debugDescription)") }
        }
        // 2. The toolbar's Checklist button runs `requestFormat(.checklist)`
        // (SwiftUI exposes no accessibility tree in-process to press it by).
        func checklist(atLineAfter marker: String, offset: Int) async -> String? {
            let ns = c.textView.string as NSString
            let found = ns.range(of: marker)
            guard found.location != NSNotFound else { return nil }
            c.window.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(NSRange(location: found.location + offset, length: 0))
            await sleep(0.3)
            c.content.requestFormat(.checklist)
            r.gestures += 1
            await sleep(0.3)
            let after = c.textView.string as NSString
            return after.substring(with: after.lineRange(for: NSRange(location: c.textView.selectedRange().location, length: 0)))
        }
        if let paragraph = await checklist(atLineAfter: "toolbar's Checklist", offset: 0) {
            r.measuredSamples += 1
            r.notes.append("toolbar Checklist on a paragraph: \(paragraph.debugDescription)")
            if !paragraph.hasPrefix("- [ ] ") { r.failures.append("Checklist left a paragraph as it was: \(paragraph.debugDescription)") }
        }
        if let empty = await checklist(atLineAfter: "Empty line below:\n", offset: ("Empty line below:\n" as NSString).length) {
            r.measuredSamples += 1
            r.notes.append("toolbar Checklist on an empty line: \(empty.debugDescription)")
            if empty != "- [ ] \n" { r.failures.append("Checklist on an empty line made \(empty.debugDescription)") }
        }
        // 3. In a table cell the button shows disabled.
        let cellText = (c.textView.string as NSString).range(of: "| cell |")
        if cellText.location != NSNotFound {
            c.window.makeFirstResponder(c.textView)
            c.textView.setSelectedRange(NSRange(location: cellText.location + 2, length: 0))
            await sleep(0.5)
            let enabled = c.content.isFormatEnabled(.checklist)
            r.notes.append("Checklist in a table cell: \(enabled ? "enabled" : "disabled") (context \(c.content.formatState.context))")
            if enabled { r.failures.append("Checklist shows enabled in a table cell, where it does nothing") }
        }
    }

    /// Hover reveals, as the pointer meets them: the top chrome, the bottom
    /// strip, the scroller edge, then a sweep over the text (tables, comment
    /// highlights, cards). Each zone reports the main thread's longest stall
    /// while the pointer moves at 120 Hz; PerfTrace dumps what ran.
    private static func hover(_ c: Context, _ r: inout ScenarioResult) async {
        QAPresentation.activateIfAllowed()
        if let screen = c.window.screen?.visibleFrame {
            c.window.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - 900, width: min(1320, screen.width - 40), height: 880), display: true)
        }
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        // Comments on the first prose lines, loaded (not posted, so nothing is written).
        let ns = c.textView.string as NSString
        let quotes = visibleFragmentStarts(in: c.textView, limit: 40).compactMap { start -> String? in
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let text = ns.substring(with: line)
            guard line.length > 40, !text.hasPrefix("|"), !text.hasPrefix("```"), !text.hasPrefix("#") else { return nil }
            return ns.substring(with: NSRange(location: line.location + 4, length: 24))
        }.prefix(3)
        c.content.editorController.commentThreads = quotes.map {
            MarkdownCommentThread(anchor: MarkdownCommentAnchor(prefix: "", exact: $0, suffix: ""), root: MarkdownComment(body: "Hover probe"))
        }
        await sleep(0.6)
        guard let content = c.window.contentView else {
            r.failures.append("No content view")
            return
        }
        let bounds = content.convert(content.bounds, to: nil)
        let chromeHeight: CGFloat = 70
        let settings = SettingsManager.shared
        var pointer: NSPoint?
        var handlerMilliseconds = 0.0
        func path(_ points: [NSPoint]) async -> Int {
            for point in points {
                let start = CFAbsoluteTimeGetCurrent()
                movePointer(from: pointer, to: point, in: c.window)
                handlerMilliseconds += (CFAbsoluteTimeGetCurrent() - start) * 1000
                pointer = point
                await sleep(0.008)
            }
            return points.count
        }
        func line(_ from: NSPoint, _ to: NSPoint, step: CGFloat = 12) -> [NSPoint] {
            let count = max(1, Int((hypot(to.x - from.x, to.y - from.y) / step).rounded(.up)))
            return (0...count).map { index in
                let t = CGFloat(index) / CGFloat(count)
                return NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            }
        }
        func measure(_ zone: String, _ body: () async -> Int) async {
            PerfTrace.dump("hover before \(zone)")
            handlerMilliseconds = 0
            let meter = StallMeter()
            meter.start()
            let start = CFAbsoluteTimeGetCurrent()
            let moves = await body()
            let wall = (CFAbsoluteTimeGetCurrent() - start) * 1000
            await sleep(0.4)
            meter.stop()
            r.gestures += moves
            r.measuredSamples += 1
            r.notes.append(String(format: "hover %@: %d moves in %.0f ms (%.1f ms/move, handlers %.2f ms/move), main thread busy %.0f%%, longest stall %.1f ms, %d stalls over 16 ms totalling %.0f ms",
                                  zone, moves, wall, wall / Double(max(moves, 1)), handlerMilliseconds / Double(max(moves, 1)),
                                  meter.busyFraction * 100, meter.longest, meter.stalls, meter.stalledMilliseconds))
            PerfTrace.dump("hover \(zone)")
        }
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        await measure("still") { await path(Array(repeating: mid, count: 40)) }
        let top = NSPoint(x: bounds.midX, y: bounds.maxY - 20)
        await measure("top-chrome") {
            var moves = 0
            for _ in 0..<5 { moves += await path(line(mid, top) + line(top, mid)) }
            return moves
        }
        let bottom = NSPoint(x: bounds.maxX - 120, y: bounds.minY + 14)
        await measure("bottom-strip") {
            var moves = 0
            for _ in 0..<5 { moves += await path(line(mid, bottom) + line(bottom, mid)) }
            return moves
        }
        let edge = NSPoint(x: bounds.maxX - 6, y: bounds.midY)
        await measure("scroller-edge") {
            var moves = 0
            for _ in 0..<5 { moves += await path(line(mid, edge) + line(edge, mid)) }
            return moves
        }
        let visible = c.scrollView.convert(c.scrollView.bounds, to: nil)
        await measure("text") {
            var moves = 0
            var y = visible.maxY - chromeHeight
            var leftToRight = true
            while y > visible.minY + chromeHeight {
                let left = NSPoint(x: visible.minX + 20, y: y), right = NSPoint(x: visible.maxX - 20, y: y)
                moves += await path(leftToRight ? line(left, right, step: 20) : line(right, left, step: 20))
                leftToRight.toggle()
                y -= 26
            }
            return moves
        }
        // Along the top bar, pinned open so the real pointer (outside the
        // window) can't fold it: the tabs, then the toolbar, with and
        // without the toolbar's Dock-style magnification.
        let pinned = (settings.isTopBarAlwaysVisible, settings.isFloatingToolbarAlwaysVisible, settings.isToolbarMagnificationEnabled)
        settings.isTopBarAlwaysVisible = true
        settings.isFloatingToolbarAlwaysVisible = true
        await sleep(0.6)
        func find(_ name: String, in view: NSView) -> NSView? {
            if String(describing: type(of: view)) == name { return view }
            for sub in view.subviews { if let found = find(name, in: sub) { return found } }
            return nil
        }
        let barY = (c.window.contentView.flatMap { find("TabBarMouseView", in: $0) }).map { $0.convert($0.bounds, to: nil).midY }
            ?? bounds.maxY - 40
        let tabsLeft = NSPoint(x: bounds.minX + 90, y: barY), tabsRight = NSPoint(x: bounds.maxX - 560, y: barY)
        let toolLeft = NSPoint(x: bounds.maxX - 560, y: barY), toolRight = NSPoint(x: bounds.maxX - 12, y: barY)
        for magnifies in [true, false] {
            settings.isToolbarMagnificationEnabled = magnifies
            await sleep(0.3)
            await measure("tabs") {
                var moves = 0
                for _ in 0..<3 { moves += await path(line(tabsLeft, tabsRight, step: 6) + line(tabsRight, tabsLeft, step: 6)) }
                return moves
            }
            await measure(magnifies ? "toolbar-magnified" : "toolbar-flat") {
                var moves = 0
                for _ in 0..<3 { moves += await path(line(toolLeft, toolRight, step: 6) + line(toolRight, toolLeft, step: 6)) }
                return moves
            }
        }
        (settings.isTopBarAlwaysVisible, settings.isFloatingToolbarAlwaysVisible, settings.isToolbarMagnificationEnabled) = pinned
        c.content.editorController.commentThreads = []
    }

    /// Image drops (doc 26 §9, Phase 7): five fixture PNGs imported at five
    /// visible drop slots through the import entry a real drop uses (a
    /// replay cannot start a Finder drag), bottom slot first. Text is typed at
    /// the top while the first copy runs, so that image must land at its slot
    /// mapped past the typing. The main thread must never stall 100 ms; the
    /// note is undone back to its bytes and the copies are removed.
    /// One move and one undo per kind on the supplied image fixture. The destination,
    /// rather than a potentially tall source, is scrolled into view before measuring the transaction.
    private static func blockMove(_ c: Context, _ r: inout ScenarioResult) async {
        let controller = c.content.editorController
        guard let original = controller.currentDisplayText else { r.failures.append("No active editor"); return }
        let patterns: [(String, String)] = [
            ("image", #"(?m)^[ \t]*!\[[^\n]*\]\([^\n]*\)[ \t]*$"#),
            ("equation", #"(?ms)^\$\$[^\n]*\n.*?^\$\$[ \t]*$"#),
            ("diagram", #"(?ms)^```mermaid[^\n]*\n.*?^```[ \t]*$"#),
            ("code", #"(?ms)^```(?!mermaid)[^\n]*\n.*?^```[ \t]*$"#),
            ("table", #"(?m)^\|[^\n]*\n\|[ :|\-]+\n(?:\|[^\n]*(?:\n|$))+"#),
        ]
        let text = original as NSString
        guard let proseDestinations = try? NSRegularExpression(pattern: #"(?m)^[A-Za-z][^\r\n]{120,}$"#) else {
            r.failures.append("Invalid prose destination pattern"); return
        }
        // Focus can enqueue the old caret's reveal. Finish that setup before
        // seating a drop point; a nonempty marker range may skip native reveal.
        _ = c.window.makeFirstResponder(c.textView)
        await sleep(0.1)
        for (kind, pattern) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: original, range: NSRange(location: 0, length: original.utf16.count)) else {
                r.failures.append("No \(kind) block in the fixture")
                continue
            }
            let sourceRange = match.range
            let end = NSMaxRange(sourceRange)
            // A long prose paragraph makes the drop point and readable witness the
            // same visible content. Intervening content excludes the source's own
            // adjacent separator; the engine still validates the prepared slot.
            var target: Int?
            proseDestinations.enumerateMatches(in: original, range: NSRange(location: end, length: text.length - end)) { match, _, stop in
                guard let match else { return }
                let between = NSRange(location: end, length: match.range.location - end)
                guard !text.substring(with: between).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                target = match.range.location
                stop.pointee = true
            }
            guard let target else {
                r.failures.append("No later nonadjacent prose destination after \(kind)"); continue
            }
            await sleep(0.08)
            c.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            c.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            await sleep(0.16)
            guard controller.dropSlotsNearViewport.contains(target) else {
                r.failures.append("Prepared destination @\(target) is not a viewport drop slot for \(kind); selection=\(c.textView.selectedRange()), viewport=\(String(describing: c.textView.textLayoutManager?.textViewportLayoutController.viewportRange))"); continue
            }
            guard let witness = ReadableTextLineProbe.capture(in: c.textView, minimumLocation: target) else {
                r.failures.append("No fully visible readable witness after \(kind) destination @\(target)"); continue
            }
            let targetScreen = screenY(of: target, in: c.textView)
            PerfTrace.dump("block move before \(kind)")
            let start = CFAbsoluteTimeGetCurrent()
            var moved = false
            asOneEvent(c.content.undoManager) {
                moved = controller.moveBlock(kind: kind, sourceRange: sourceRange, to: target)
            }
            guard moved else { r.failures.append("\(kind) move refused"); continue }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            PerfTrace.dump("block move \(kind)")
            r.gestures += 1
            r.notes.append(String(format: "\(kind) move apply %.1f ms", elapsed))
            if elapsed > 100 { r.failures.append("\(kind) move exceeded 100 ms") }
            await sleep(0.1)
            // The same target source follows a removal from above and an insertion immediately before it.
            let changed = controller.currentDisplayText ?? ""
            let removedDelta = changed.utf16.count - original.utf16.count
            if let after = witness.resample(in: c.textView, offsetDelta: removedDelta) {
                r.measuredSamples += 1
                r.maxInteractionShift = max(r.maxInteractionShift, abs(after.windowY - witness.windowY))
            } else { r.failures.append("The mapped readable witness is unavailable after \(kind) move") }
            let mappedTarget = target + removedDelta
            if let targetScreen, let after = screenY(of: mappedTarget, in: c.textView) {
                r.notes.append(String(format: "\(kind) destination paragraph fragment shift %.2f pt (diagnostic)", abs(after - targetScreen)))
            }
            c.content.undoManager.undo()
            r.gestures += 1
            await sleep(0.1)
            if controller.currentDisplayText?.utf16.elementsEqual(original.utf16) != true {
                r.failures.append("\(kind) undo did not restore exact source"); return
            }
        }
    }

    private static func imageDrop(_ c: Context, _ r: inout ScenarioResult) async {
        // Everything goes through the active tab's own editor: the harness's
        // text view is the first editor in the window, which can be a warm tab's.
        let controller = c.content.editorController
        let undo = c.content.undoManager
        func source() -> NSString { NSString(string: controller.currentDisplayText ?? "") }
        guard let noteFolder = c.content.documentManager.documentURL?.deletingLastPathComponent() else {
            r.failures.append("image-drop needs a saved note (PAGEFLOW_QA_DOC)")
            return
        }
        // The copies go to the note's attachments folder; a folder the app may
        // not write would open the access panel and stall the replay.
        let attachments = noteFolder.appendingPathComponent(PastedImageStore.attachmentsFolderName, isDirectory: true)
        let hadAttachments = FileManager.default.fileExists(atPath: attachments.path)
        let writable = FolderAccessStore.shared.withAccess(to: attachments) { () -> Bool in
            let probe = attachments.appendingPathComponent(".qa-probe-\(UUID().uuidString)")
            guard (try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)) != nil,
                  (try? Data().write(to: probe)) != nil else { return false }
            try? FileManager.default.removeItem(at: probe)
            return true
        }
        guard writable else {
            r.failures.append("Allow PageFlow to write \(attachments.path) first (paste an image into the note once)")
            return
        }
        let tag = "qa-drop-\(UUID().uuidString.prefix(8))"
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(tag, isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fixtures)
            let made = (try? FileManager.default.contentsOfDirectory(atPath: attachments.path)) ?? []
            for name in made where name.hasPrefix(tag) {
                try? FileManager.default.removeItem(at: attachments.appendingPathComponent(name))
            }
            if !hadAttachments, (try? FileManager.default.contentsOfDirectory(atPath: attachments.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: attachments)
            }
        }
        var files: [URL] = []
        for index in 0..<5 {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = fixtures.appendingPathComponent("\(tag)-\(index).png")
            if (try? png.write(to: url)) != nil { files.append(url) }
        }
        let slots = Array(Set(controller.dropSlotsNearViewport).filter { $0 > 0 }).sorted().suffix(5).reversed()
        guard files.count == 5, slots.count >= 2 else {
            r.failures.append("Need 5 fixtures and 2 visible drop slots; have \(files.count) and \(slots.count)")
            return
        }
        // A copy: the text view's string can be its storage's live buffer.
        let original = source() as String
        r.notes.append("image-drop: slots \(Array(slots)) in \((original as NSString).length) characters")
        let meter = StallMeter()
        meter.start()
        var shift = 0
        for (index, listed) in slots.enumerated() {
            // Every slot below the first sits after the text typed at the top.
            let slot = listed + shift
            let before = source()
            let stem = "\(tag)-\(index)"
            controller.importImages(MarkdownImageDrop(fileURLs: [files[index]]), at: slot)
            r.gestures += 1
            var typed = 0
            if index == 0 {
                // An edit above the slot while the copy runs.
                asOneEvent(undo) {
                    if controller.replaceCharacters(in: [NSRange(location: 0, length: 0)], with: "QA ",
                                                    expectedSource: source() as String, actionName: "Typing") { typed = 3 }
                }
                shift = typed
            }
            var landed: NSRange?
            for _ in 0..<60 {
                await sleep(0.05)
                let found = source().range(of: "![\(stem)](")
                if found.location != NSNotFound { landed = found; break }
            }
            guard let landed else {
                r.failures.append("Image \(index) at slot \(slot) never landed")
                continue
            }
            let after = source()
            let expectedPrefix = (typed > 0 ? "QA " : "") + before.substring(to: slot)
            let prefixKept = after.length >= slot + typed && after.substring(to: slot + typed) == expectedPrefix
            r.measuredSamples += 1
            r.notes.append("image \(index): slot \(slot)\(typed > 0 ? " (+\(typed) typed above)" : ""), link at \(landed.location)")
            if !prefixKept {
                let got = after.substring(to: min(after.length, slot + typed)) as NSString
                let want = expectedPrefix as NSString
                var first = 0
                while first < min(got.length, want.length), got.character(at: first) == want.character(at: first) { first += 1 }
                r.notes.append("image \(index): text before the slot differs at \(first) of \(want.length): got \(got.substring(from: first).prefix(40).debugDescription), want \(want.substring(from: first).prefix(40).debugDescription)")
            }
            if !prefixKept || landed.location < slot + typed {
                r.failures.append("Image \(index) did not land at its mapped slot \(slot + typed) (link at \(landed.location))")
            }
        }
        meter.stop()
        r.notes.append(String(format: "image-drop: longest main-thread stall %.1f ms, %d stalls over 16 ms", meter.longest, meter.stalls))
        if meter.longest >= 100 { r.failures.append(String(format: "Main thread stalled %.0f ms during the drops", meter.longest)) }
        var undos = 0
        while !(source() as String).utf16.elementsEqual(original.utf16), undo.canUndo, undos < 40 {
            undo.undo()
            undos += 1
        }
        if !(source() as String).utf16.elementsEqual(original.utf16) {
            r.failures.append("Undo did not restore the note's bytes after \(undos) steps")
        }
    }

    /// The main run loop's longest gap between 1 ms ticks: how long the
    /// pointer would have waited for the app.
    @MainActor
    private final class StallMeter {
        private var timer: Timer?
        private var last = CFAbsoluteTimeGetCurrent()
        private(set) var longest = 0.0
        private(set) var stalls = 0
        private(set) var stalledMilliseconds = 0.0
        private var began = CFAbsoluteTimeGetCurrent()
        private var busy = 0.0
        /// The share of the time the run loop could not serve a 1 ms timer.
        var busyFraction: Double { busy / max((last - began) * 1000, 1) }

        func start() {
            last = CFAbsoluteTimeGetCurrent()
            began = last
            let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            tick()
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            let now = CFAbsoluteTimeGetCurrent()
            let gap = (now - last) * 1000
            last = now
            longest = max(longest, gap)
            busy += max(0, gap - 1.5)
            if gap > 16 {
                stalls += 1
                stalledMilliseconds += gap
            }
        }
    }

    /// What the window server does as the pointer moves from `previous` to
    /// `point` (window coordinates): exits, then entries, then moves, to the
    /// owners of the tracking areas the move crosses or lands in.
    private static func movePointer(from previous: NSPoint?, to point: NSPoint, in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var exits: [AnyObject] = [], entries: [AnyObject] = []
        var moved: [ObjectIdentifier: NSResponder] = [:]
        var order: [ObjectIdentifier] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let now = view.convert(point, from: nil)
            let before = previous.map { view.convert($0, from: nil) }
            for area in view.trackingAreas {
                guard let owner = area.owner else { continue }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let inside = rect.contains(now), wasInside = before.map(rect.contains) ?? false
                if area.options.contains(.mouseEnteredAndExited) {
                    if wasInside, !inside { exits.append(owner as AnyObject) }
                    if inside, !wasInside { entries.append(owner as AnyObject) }
                }
                if inside, area.options.contains(.mouseMoved), let responder = owner as? NSResponder {
                    let key = ObjectIdentifier(responder)
                    if moved[key] == nil { moved[key] = responder; order.append(key) }
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        let time = ProcessInfo.processInfo.systemUptime
        func send(_ type: NSEvent.EventType, to owner: AnyObject) {
            guard let event = NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: time,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     trackingNumber: 0, userData: nil) else { return }
            let selector = type == .mouseEntered ? #selector(NSResponder.mouseEntered(with:)) : #selector(NSResponder.mouseExited(with:))
            if owner.responds(to: selector) { _ = owner.perform(selector, with: event) }
        }
        exits.forEach { send(.mouseExited, to: $0) }
        entries.forEach { send(.mouseEntered, to: $0) }
        guard !order.isEmpty, let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: time,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                             clickCount: 0, pressure: 0) else { return }
        for key in order { moved[key]?.mouseMoved(with: event) }
    }

    /// the reference editor's commenting (doc 25), driven by real events: select a
    /// phrase, click Comment in the bar, type, Enter; open the card, reply;
    /// hover the highlight. The commented line must not move while the rail
    /// seats. Window snapshots go to the output folder.
    private static func comments(_ c: Context, _ r: inout ScenarioResult) async {
        let ns = c.textView.string as NSString
        let starts = visibleFragmentStarts(in: c.textView, limit: 40).filter { start in
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let text = ns.substring(with: line)
            return line.length > 40 && !text.hasPrefix("|") && !text.hasPrefix("```") && !text.hasPrefix("#") && !text.hasPrefix("$")
        }
        guard let start = starts.first else {
            r.failures.append("No visible prose line to comment on")
            return
        }
        QAPresentation.activateIfAllowed()
        // Wide enough for the rail beside the reading column.
        if let screen = c.window.screen?.visibleFrame {
            c.window.setFrame(NSRect(x: screen.minX + 20, y: screen.maxY - 900, width: min(1320, screen.width - 40), height: 880), display: true)
        }
        QAPresentation.show(c.window)
        for _ in 0..<40 where !c.window.isKeyWindow { await sleep(0.05) }
        await sleep(0.3)
        let output = ProcessInfo.processInfo.environment["PAGEFLOW_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
        func snapshot(_ name: String) {
            guard let output else { return }
            compositeSnapshot(of: c.scrollView, overlays: ["CommentHighlightView", "CommentRailView", "CommentComposerView",
                                                           "MarkdownSelectionBarView", "CommentEmojiPicker", "TableMenuView"])
                .flatMap { $0.representation(using: .png, properties: [:]) }
                .map { try? $0.write(to: output.appendingPathComponent(name)) }
        }
        func send(_ type: NSEvent.EventType, inWindow point: NSPoint, characters: String = "", keyCode: UInt16 = 0) {
            let event: NSEvent?
            if type == .keyDown || type == .keyUp {
                event = NSEvent.keyEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: c.window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            } else {
                event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: c.window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .mouseMoved ? 0 : 1)
            }
            if let event { c.window.sendEvent(event); r.gestures += 1 }
        }
        func click(_ view: NSView) async {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            send(.mouseMoved, inWindow: point)
            send(.leftMouseDown, inWindow: point)
            send(.leftMouseUp, inWindow: point)
            await sleep(0.15)
        }
        func type(_ text: String) async {
            for character in text {
                send(.keyDown, inWindow: .zero, characters: String(character))
                send(.keyUp, inWindow: .zero, characters: String(character))
            }
            await sleep(0.1)
        }
        func press(_ keyCode: UInt16, _ characters: String) async {
            send(.keyDown, inWindow: .zero, characters: characters, keyCode: keyCode)
            send(.keyUp, inWindow: .zero, characters: characters, keyCode: keyCode)
            await sleep(0.2)
        }
        func find(_ name: String, in root: NSView) -> NSView? {
            if String(describing: Swift.type(of: root)) == name, !root.isHidden { return root }
            for sub in root.subviews { if let found = find(name, in: sub) { return found } }
            return nil
        }
        let threads = { c.content.editorController.commentThreads }
        let before = threads().count
        let word = NSRange(location: start + 2, length: min(14, ns.lineRange(for: NSRange(location: start, length: 0)).length - 4))
        c.window.makeFirstResponder(c.textView)
        c.textView.setSelectedRange(word)
        r.gestures += 1
        var bar: NSView?
        for _ in 0..<60 {
            await sleep(0.05)
            bar = find("MarkdownSelectionBarView", in: c.scrollView)
            if bar != nil { break }
        }
        guard let bar, let comment = bar.subviews.first(where: { $0.accessibilityLabel() == "Comment" }) else {
            r.failures.append("The selection bar showed no Comment button")
            snapshot("comments-no-bar.png")
            return
        }
        snapshot("comments-1-bar.png")
        let lineBefore = screenY(of: word.location, in: c.textView)
        await click(comment)
        await sleep(0.3)
        guard find("CommentComposerView", in: c.scrollView) != nil else {
            r.failures.append("Comment opened no composer")
            snapshot("comments-no-composer.png")
            return
        }
        snapshot("comments-2-composer.png")
        await type("Is this the right wording?")
        snapshot("comments-3-typed.png")
        await press(36, "\r")
        await sleep(0.5)
        guard threads().count == before + 1, let thread = threads().last else {
            r.failures.append("Enter posted no comment (\(threads().count) threads)")
            snapshot("comments-not-posted.png")
            return
        }
        let lineAfter = screenY(of: word.location, in: c.textView)
        if let lineBefore, let lineAfter {
            r.maxInteractionShift = max(r.maxInteractionShift, abs(lineAfter - lineBefore))
            r.measuredSamples += 1
        }
        snapshot("comments-4-posted.png")
        guard let card = find("CommentCardView", in: c.scrollView) else {
            r.failures.append("The posted comment has no card in the rail (narrow editor or full-width mode?)")
            return
        }
        r.notes.append(String(format: "card at x=%.0f w=%.0f; text view x=%.0f w=%.0f; clip w=%.0f", card.convert(card.bounds, to: c.scrollView).minX,
                              card.frame.width, c.textView.frame.minX, c.textView.frame.width, c.scrollView.contentView.bounds.width))
        await click(card)
        await sleep(0.3)
        snapshot("comments-5-open.png")
        guard let reply = find("CommentFieldView", in: card) else {
            r.failures.append("The open card shows no Reply box")
            return
        }
        // Focus the box directly: a synthetic click would start NSTextView's
        // tracking loop, which waits for a mouse-up the replay sends after it.
        if let field = reply.subviews.first?.subviews.first as? NSTextView ?? (reply.subviews.first as? NSScrollView)?.documentView as? NSTextView {
            c.window.makeFirstResponder(field)
        }
        await type("Yes, keep it.")
        await press(36, "\r")
        await sleep(0.4)
        if threads().last?.replies.count != 1 { r.failures.append("Enter in the Reply box posted no reply") }
        snapshot("comments-6-replied.png")
        await press(53, "\u{1b}")
        c.window.makeFirstResponder(c.textView)
        await press(53, "\u{1b}")
        await sleep(0.3)
        snapshot("comments-7-collapsed.png")
        // Hover the highlight: it lights.
        if let rect = c.textView.firstRect(forCharacterRange: NSRange(location: word.location + 2, length: 1), actualRange: nil) as NSRect?,
           !rect.isNull {
            let point = c.window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY))
            send(.mouseMoved, inWindow: point)
            await sleep(0.4)
            snapshot("comments-8-hover.png")
        }
        r.notes.append("thread \(thread.id): \(thread.anchor.exact.debugDescription), replies \(threads().last?.replies.count ?? 0)")
    }

    /// The scroll view as drawn (TextKit's text), with each named layer-drawn
    /// view rendered over it from its layer tree: highlights multiplied in
    /// under the ink, cards, the composer, the bar and menus on top.
    private static func compositeSnapshot(of scrollView: NSScrollView, overlays: [String]) -> NSBitmapImageRep? {
        guard let drawn = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds),
              let base = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else { return nil }
        scrollView.cacheDisplay(in: scrollView.bounds, to: drawn)
        guard let context = NSGraphicsContext(bitmapImageRep: base), let text = drawn.cgImage else { return drawn }
        let scale = CGFloat(base.pixelsWide) / max(1, scrollView.bounds.width)
        // The page behind the text, in the window's appearance (the editor draws none).
        var page = CGColor(gray: 1, alpha: 1)
        scrollView.effectiveAppearance.performAsCurrentDrawingAppearance { page = NSColor.textBackgroundColor.cgColor }
        context.cgContext.setFillColor(page)
        context.cgContext.fill(CGRect(origin: .zero, size: scrollView.bounds.size))
        func views(named name: String, in root: NSView) -> [NSView] {
            (String(describing: type(of: root)) == name && !root.isHidden ? [root] : []) + root.subviews.flatMap { views(named: name, in: $0) }
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        var overlaysOnTop: [(CGImage, CGRect)] = []
        for name in overlays {
            for view in views(named: name, in: scrollView) {
                guard let layer = view.layer else { continue }
                let region = view.visibleRect
                guard region.width >= 1, region.height >= 1,
                      let bitmap = CGContext(data: nil, width: Int(region.width * scale), height: Int(region.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                bitmap.scaleBy(x: scale, y: scale)
                if view.isFlipped {
                    bitmap.translateBy(x: 0, y: region.height)
                    bitmap.scaleBy(x: 1, y: -1)
                }
                bitmap.translateBy(x: -region.minX, y: -region.minY)
                layer.render(in: bitmap)
                guard let image = bitmap.makeImage() else { continue }
                var target = view.convert(region, to: scrollView)
                if scrollView.isFlipped { target.origin.y = scrollView.bounds.height - target.maxY }
                if name == "CommentHighlightView" {
                    context.cgContext.draw(image, in: target)
                } else {
                    overlaysOnTop.append((image, target))
                }
            }
        }
        // The ink goes over the highlights, as in the editor; chrome over both.
        context.cgContext.draw(text, in: CGRect(origin: .zero, size: scrollView.bounds.size))
        for (image, target) in overlaysOnTop { context.cgContext.draw(image, in: target) }
        NSGraphicsContext.restoreGraphicsState()
        return base
    }

    private static func visibleFragmentStarts(in textView: NSTextView, limit: Int) -> [Int] {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let start = tlm.textViewportLayoutController.viewportRange?.location else { return [] }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        var result: [Int] = []
        tlm.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.maxY <= visible.minY { return true }
            if frame.minY >= visible.maxY { return false }
            result.append(tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location))
            return result.count < limit
        }
        return result
    }

    /// The starts of up to `count` paragraphs from `location`'s paragraph on.
    private static func paragraphStarts(from location: Int, count: Int, in textView: NSTextView) -> [Int] {
        let ns = textView.string as NSString
        var starts: [Int] = []
        var cursor = ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0)).location
        while starts.count < count, cursor < ns.length {
            starts.append(cursor)
            cursor = NSMaxRange(ns.paragraphRange(for: NSRange(location: cursor, length: 0)))
        }
        return starts
    }

    /// The `starts` that begin a plain prose line: not an image, table, code,
    /// `$$` math or diagram line, and not inside a fenced or `$$` block.
    private static func proseLineStarts(_ starts: [Int], in textView: NSTextView) -> [Int] {
        let ns = textView.string as NSString
        guard let storage = textView.textStorage, let last = starts.max(), last < ns.length else { return [] }
        let blockKind = NSAttributedString.Key("MarkdownBlockKind")
        let tableSource = NSAttributedString.Key("MarkdownTableSourceRange")
        let wanted = Set(starts)
        var insideBlock = Set<Int>()
        var fence: String?
        var cursor = 0
        while cursor <= last, cursor < ns.length {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            let opener = ["```", "~~~", "$$"].first { text.hasPrefix($0) }
            if wanted.contains(line.location), fence != nil || opener != nil { insideBlock.insert(line.location) }
            if let open = fence {
                if open == "$$" ? text.contains("$$") : text.hasPrefix(open) { fence = nil }
            } else if let opener, !(opener == "$$" && text.count > 2 && text.hasSuffix("$$")) {
                fence = opener
            }
            cursor = NSMaxRange(line)
        }
        return starts.filter { start in
            guard !insideBlock.contains(start) else { return false }
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 20, !["|", "!", "<", "#"].contains(where: text.hasPrefix) else { return false }
            var object = false
            storage.enumerateAttributes(in: line) { attributes, _, stop in
                if attributes[blockKind] != nil || attributes[tableSource] != nil {
                    object = true
                    stop.pointee = true
                }
            }
            return !object
        }
    }

    /// A paragraph's identity across a format toggle: its text with the inline
    /// markers a toggle adds or removes stripped, so the same line is found
    /// again after every character offset around it has moved.
    private static func lineKey(at location: Int, in textView: NSTextView) -> String? {
        let ns = textView.string as NSString
        guard location >= 0, location < ns.length else { return nil }
        let line = ns.substring(with: ns.paragraphRange(for: NSRange(location: location, length: 0)))
        let stripped = line.replacingOccurrences(of: "<u>", with: "").replacingOccurrences(of: "</u>", with: "")
            .filter { $0 != "*" && $0 != "_" }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The start of the first visible line whose identity is `key`, if it is laid out.
    /// The reader's top line as a (key, location): the first visible fragment
    /// whose marker-stripped text is non-empty and unique among the next 60 —
    /// an empty line or a rule at the top would resolve to a different
    /// paragraph after a whole-note toggle and read as a jump that never
    /// happened.
    private static func topLine(in textView: NSTextView) -> (key: String, location: Int)? {
        let starts = visibleFragmentStarts(in: textView, limit: 60)
        let keys = starts.map { lineKey(at: $0, in: textView) ?? "" }
        var counts: [String: Int] = [:]
        for key in keys { counts[key, default: 0] += 1 }
        for (start, key) in zip(starts, keys) where key.count >= 6 && counts[key] == 1 {
            return (key, start)
        }
        guard let firstStart = starts.first, let firstKey = keys.first else { return nil }
        return (firstKey, firstStart)
    }

    private static func visibleLine(withKey key: String, near location: Int? = nil, in textView: NSTextView) -> Int? {
        let matches = visibleFragmentStarts(in: textView, limit: 60).filter { lineKey(at: $0, in: textView) == key }
        guard let location else { return matches.first }
        return matches.min { abs($0 - location) < abs($1 - location) }
    }

    /// On-screen y of the line identified by `key`, wherever its offset moved to.
    private static func screenY(ofLineKey key: String, near location: Int? = nil, in textView: NSTextView) -> CGFloat? {
        visibleLine(withKey: key, near: location, in: textView).flatMap { screenY(of: $0, in: textView) }
    }

    /// What the window server does with a pointer move: `mouseMoved(with:)`
    /// to the owner of every `.mouseMoved` tracking area that holds `point`
    /// (its visible rect for `.inVisibleRect` areas), once per owner.
    private static func deliverToTrackingAreas(_ event: NSEvent, at point: NSPoint, in window: NSWindow) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        var owners: [ObjectIdentifier: NSResponder] = [:]
        var order: [ObjectIdentifier] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let local = view.convert(point, from: nil)
            for area in view.trackingAreas where area.options.contains(.mouseMoved) {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(local), let owner = area.owner as? NSResponder else { continue }
                let key = ObjectIdentifier(owner)
                if owners[key] == nil { owners[key] = owner; order.append(key) }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        for key in order { owners[key]?.mouseMoved(with: event) }
    }

    /// The top of the fragment containing `location` in the text view's own coordinates.    /// The top of the fragment containing `location` in the text view's own coordinates.
    private static func viewY(of location: Int, in textView: NSTextView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let textLocation = tcm.location(tcm.documentRange.location, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: textLocation),
              fragment.state == .layoutAvailable else { return nil }
        return fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    }

    /// On-screen (window) y of the fragment containing `location`, or nil if it is not laid out.
    private static func screenY(of location: Int, in textView: NSTextView) -> CGFloat? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let textLocation = tcm.location(tcm.documentRange.location, offsetBy: location),
              let fragment = tlm.textLayoutFragment(for: textLocation),
              fragment.state == .layoutAvailable else { return nil }
        let origin = textView.textContainerOrigin
        let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
        return textView.convert(frame, to: nil).origin.y
    }

    /// Movement of the top visible line over 250 ms of doing nothing.
    private static func idleDrift(_ textView: NSTextView) async -> CGFloat? {
        guard let before = anchor(in: textView) else { return nil }
        await sleep(0.25)
        guard let after = screenY(of: before.location, in: textView) else { return nil }
        return abs(after - before.screenY)
    }

    /// No new selection or probe search between the fixed-line idle samples.
    private static func idleDrift(_ probe: ReadableTextLineProbe, in textView: NSTextView) async -> CGFloat? {
        guard let before = probe.resample(in: textView) else { return nil }
        let source = textView.string
        await sleep(0.25)
        guard textView.string.utf16.elementsEqual(source.utf16),
              let after = probe.resample(in: textView) else { return nil }
        return abs(after.windowY - before.windowY)
    }

    private static func measurement(_ value: CGFloat?, label: String, result: inout ScenarioResult) -> CGFloat {
        guard let value, value.isFinite, value >= 0 else {
            result.failures.append("Missing or invalid \(label)")
            return 0
        }
        result.measuredSamples += 1
        return value
    }

    // MARK: - Gestures

    /// A pixel-precise wheel event delivered through the scroll view's own
    /// `scrollWheel(with:)`, so the engine's Ctrl-zoom and user-gesture stamps
    /// see exactly what a trackpad sends (minus gesture phases).
    private static func wheel(_ scrollView: NSScrollView, deltaY: Int32, control: Bool = false) -> Bool {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return false }
        if control { cgEvent.flags = .maskControl }
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        scrollView.scrollWheel(with: event)
        return true
    }

    // MARK: - Lifecycle helpers

    private static func waitForTabManager() async -> TabManager? {
        for _ in 0..<150 {
            await sleep(0.2)
            if let tabManager = WindowRegistry.shared.frontmostTabManager() ?? WindowRegistry.shared.anyTabManager() {
                return tabManager
            }
        }
        return nil
    }

    /// Opens `url` and waits for its editor to reach its first laid-out viewport.
    private static func open(_ url: URL, in tabManager: TabManager) async -> (milliseconds: Double, footprintMB: Double)? {
        // A fresh window presents the file picker; it would sit in front of
        // the editor and swallow the open.
        tabManager.closeFilePicker()
        let start = CFAbsoluteTimeGetCurrent()
        PerfTrace.stamp("open.start")
        tabManager.openDocument(url: url, isSecurityScoped: false)
        PerfTrace.stamp("openDocument.returned")
        for _ in 0..<4000 {
            await sleep(0.005)
            guard tabManager.activeMarkdownContent?.documentManager.documentURL?.standardizedFileURL == url.standardizedFileURL,
                  let textView = liveEditor(in: tabManager),
                  textView.textLayoutManager?.textViewportLayoutController.viewportRange != nil,
                  (textView.textStorage?.length ?? 0) > 0 else { continue }
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            PerfTrace.stamp("viewport.ready")
            PerfTrace.dump(String(format: "open %.0fms", elapsed))
            return (elapsed, physicalFootprintMB())
        }
        return nil
    }

    private static func liveEditor(in tabManager: TabManager) -> NSTextView? {
        guard let window = WindowRegistry.shared.window(for: tabManager), window.isVisible,
              let contentView = window.contentView else { return nil }
        guard let source = tabManager.activeMarkdownContent?.editorController.currentDisplayText else { return nil }
        return findEditor(in: contentView, matching: source)
    }

    private static func findEditor(in view: NSView, matching source: String) -> NSTextView? {
        guard !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let textView = view as? NSTextView, String(describing: type(of: textView)).contains("NativeTextView"),
           (textView.string as NSString).isEqual(to: source) { return textView }
        for subview in view.subviews {
            if let found = findEditor(in: subview, matching: source) { return found }
        }
        return nil
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Runs `gesture` as its own undo group, the way a real key press is one
    /// event: NSUndoManager's automatic per-event group never closes inside the
    /// replay task, so without this every gesture of a scenario lands in ONE
    /// group and a single ⌘Z reverts them all.
    private static func asOneEvent(_ undo: UndoManager?, _ gesture: () -> Void) {
        guard let undo else { gesture(); return }
        let automatic = undo.groupsByEvent
        PerfTrace.time("event.prepare") {
            undo.groupsByEvent = false
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            undo.beginUndoGrouping()
        }
        PerfTrace.time("event.gesture", gesture)
        PerfTrace.time("event.close") {
            undo.endUndoGrouping()
            undo.groupsByEvent = automatic
        }
    }

    private static func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    static let supportedScenarios = ["scroll-read", "click-sweep", "zoom-steps", "type-burst",
                                     "math-edit", "format-burst", "undo-check", "switch-restore", "table-nav",
                                     "table-wrap-type", "selection-bar", "table-chrome", "comments", "hover", "checklist", "shortcuts",
                                     "image-select", "image-drop", "block-move", "image-controls"]

    private struct RunReport: Codable {
        let runID: String
        let scenarios: [String]
        let results: [ScenarioResult]
        let failures: [String]
        let passed: Bool
    }

    private static func finish(scenarios: [String], results: [ScenarioResult], failures: [String] = []) {
        let env = ProcessInfo.processInfo.environment
        let runID = env["PAGEFLOW_QA_RUN_ID"] ?? UUID().uuidString
        let directory = env["PAGEFLOW_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pageflow-qa/\(runID)", isDirectory: true)
        var failures = failures
        let passed = failures.isEmpty && !results.isEmpty && results.count == scenarios.count && results.allSatisfy(\.passed)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for result in results {
                try encoder.encode(result).write(to: directory.appendingPathComponent("\(result.scenario).json"), options: .atomic)
                print(result.summary)
                result.failures.forEach { print("QA FAIL \(result.scenario): \($0)") }
            }
            let report = RunReport(runID: runID, scenarios: scenarios, results: results, failures: failures, passed: passed)
            try encoder.encode(report).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
            try results.map(\.summary).joined(separator: "\n").write(
                to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        } catch {
            failures.append("Could not write QA reports: \(error.localizedDescription)")
        }
        failures.forEach { print("QA FAIL: \($0)") }
        print("QA REPLAY \(passed && failures.isEmpty ? "PASS" : "FAIL"): \(directory.path)")
        fflush(stdout)
        if env["PAGEFLOW_QA_EXIT"] == "1" { exit(passed && failures.isEmpty ? 0 : 1) }
    }
}
#endif
