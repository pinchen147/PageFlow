//
//  EPUBReadAloud.swift
//  PageFlow
//
//  Read Aloud: the book's own recording (EPUBNarration) where a chapter has
//  one, else the Mac's own voice a sentence at a time, from the selection or
//  the top of the page, offline, while the pages paint the sentence and the
//  word being spoken and turn (or scroll) to keep them in view. Only the
//  recording's speed is saved.
//

import AppKit
import AVFoundation
import NaturalLanguage

/// What a speech engine reports about the text it was given, in that text's
/// own UTF-16 offsets.
enum EPUBSpeechEvent: Equatable {
    case willSpeak(NSRange)
    case finished
    /// What it was given can't be sounded.
    case failed
}

/// What Read Aloud needs of whatever is sounding, voice or recording.
@MainActor
protocol EPUBSpeechEngine: AnyObject {
    /// Events for what the engine was last given, on the main actor.
    var onEvent: ((EPUBSpeechEvent) -> Void)? { get set }
    func pause()
    func resume()
    func stop()
}

/// A speech engine: the system's, or a fake in tests.
@MainActor
protocol EPUBSpeechSynthesizing: EPUBSpeechEngine {
    func speak(_ text: String, language: String?)
}

/// The words Read Aloud is on, in chapter offsets: the sentence, and the
/// word in it once the voice reaches one.
struct EPUBSpokenRange: Equatable {
    var chapter: Int
    var sentence: NSRange
    var word: NSRange?

    /// Where the voice is now: the word, else the sentence's start.
    var location: Int { (word ?? sentence).location }
}

@Observable
@MainActor
final class EPUBReadAloud {
    enum State: Equatable { case idle, speaking, paused }

    private(set) var state = State.idle
    var isActive: Bool { state != .idle }
    /// What pages paint. Not observed: pages repaint on
    /// `epubPageMarksDidChange`, so speech never re-renders the tab.
    @ObservationIgnored private(set) var spoken: EPUBSpokenRange?
    /// Bumps with every start and stop; a surface's own following resets with it.
    @ObservationIgnored private(set) var session = 0
    /// Bumps when the book is laid out anew, which moves the view by itself.
    @ObservationIgnored private(set) var layoutMoves = 0

    /// Made at the first start, so a book never read aloud has no engine.
    @ObservationIgnored var makeSynthesizer: () -> any EPUBSpeechSynthesizing = { EPUBSystemSpeech() }
    /// Made at the first recorded clip, so only a narrated book has one.
    @ObservationIgnored var makeNarrator: () -> any EPUBNarrationPlaying = {
        EPUBNarrationPlayer { _, _ in throw CocoaError(.fileNoSuchFile) }
    }
    /// A chapter's recording placed on its text; empty when it has none.
    @ObservationIgnored var chapterClips: (Int) async -> [EPUBNarrationClip] = { _ in [] }
    /// A chapter's text, styled on demand; nil past the book's end.
    @ObservationIgnored var chapterText: (Int) async -> String? = { _ in nil }
    @ObservationIgnored var chapterCount: () -> Int = { 0 }
    /// A chapter the voice passes over: a supplement, outside the reading flow.
    @ObservationIgnored var skipsChapter: (Int) -> Bool = { _ in false }
    /// Where Start Speaking begins: the selection, else the page's top.
    @ObservationIgnored var startPosition: () -> EPUBTextPosition? = { nil }
    /// Where Start Speaking stops: the selection's end, else the book's.
    @ObservationIgnored var stopPosition: () -> EPUBTextPosition? = { nil }
    /// Called as the voice moves, to keep its words on screen.
    @ObservationIgnored var onSpokenMove: (EPUBSpokenRange) -> Void = { _ in }
    /// Whether the book's pages keep the voice in view (the book's, not a surface's).
    @ObservationIgnored var pageFollow = EPUBReadAloudFollow()

    /// The book carries its own narration, so the controls say so.
    /// The chapters with a recording of their own.
    var narratedChapters: Set<Int> = []
    var hasNarration: Bool { !narratedChapters.isEmpty }
    /// How long the narration runs, when the package says.
    var narrationDuration: TimeInterval?
    /// How fast recordings play.
    var narrationRate: Float = 1 {
        didSet { narrator?.rate = narrationRate }
    }

    /// The controls follow changes of playback engine, independently of per-word updates.
    private var activeNarration = false

    /// What the controls call reading aloud in this book.
    var startTitle: String { usesNarration ? "Play Narration" : "Start Speaking" }
    var stopTitle: String { usesNarration ? "Stop Narration" : "Stop Speaking" }
    var pauseTitle: String { usesNarration ? "Pause Narration" : "Pause Speaking" }
    var resumeTitle: String { usesNarration ? "Resume Narration" : "Resume Speaking" }
    /// Whether the recording is what plays, or would play from here: a book
    /// can be narrated only in part, and the voice reads the rest.
    var usesNarration: Bool {
        if isActive { return activeNarration }
        guard let start = startPosition() else { return hasNarration }
        return narratedChapters.contains(start.chapter)
    }
    /// What the book's narration is, for help tags: its length when known.
    var startHelp: String {
        guard usesNarration else { return "Read aloud from the selection or the top of the page" }
        let length = narrationDuration.flatMap { Self.durationFormatter.string(from: $0) }.map { " (\($0))" } ?? ""
        return "Play the book's own narration from the selection or the top of the page\(length)"
    }
    /// What Stop, Pause and Resume act on, for help tags.
    var helpNoun: String { usesNarration ? "the narration" : "reading aloud" }

    static let narrationRates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter
    }()

    @ObservationIgnored private var synthesizer: (any EPUBSpeechSynthesizing)?
    @ObservationIgnored private var narrator: (any EPUBNarrationPlaying)?
    /// Whichever of the two sounded last.
    @ObservationIgnored private var sounding: (any EPUBSpeechEngine)?
    @ObservationIgnored private var loaded: SpokenChapter?
    @ObservationIgnored private var limit: EPUBTextPosition?
    /// The next sentence, reached while paused: spoken on Resume.
    @ObservationIgnored private var held: EPUBTextPosition?
    /// The next recorded clip, reached while paused: played on Resume.
    @ObservationIgnored private var heldClip: (index: Int, offset: Int)?
    /// The clip being played and where speech should take over if it fails.
    @ObservationIgnored private var playing: (index: Int, offset: Int)?
    /// Audio files this reading found it can't play.
    @ObservationIgnored private var unplayable: Set<String> = []

    /// Starts where Start Speaking begins.
    func start() {
        guard let position = startPosition() else { return }
        start(at: position, until: stopPosition())
    }

    func start(at position: EPUBTextPosition, until limit: EPUBTextPosition? = nil) {
        stop()
        self.limit = limit
        activeNarration = narratedChapters.contains(position.chapter)
        state = .speaking
        pageFollow = EPUBReadAloudFollow()
        let session = session
        Task { await speakSentence(from: position, session: session) }
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    func togglePause() {
        switch state {
        case .speaking:
            state = .paused
            sounding?.pause()
        case .paused:
            state = .speaking
            if let heldClip {
                self.heldClip = nil
                playClip(heldClip.index, from: heldClip.offset)
            } else if let held {
                self.held = nil
                let session = session
                Task { await speakSentence(from: held, session: session) }
            } else {
                sounding?.resume()
            }
        case .idle:
            break
        }
    }

    func stop() {
        session &+= 1
        synthesizer?.stop()
        narrator?.stop()
        loaded = nil
        limit = nil
        held = nil
        heldClip = nil
        playing = nil
        unplayable = []
        guard state != .idle || spoken != nil else { return }
        state = .idle
        setSpoken(nil)
    }

    // MARK: - Speaking

    /// Speaks the next sentence at or after `position`, moving on to the
    /// next chapter at a chapter's end and stopping at the book's or the limit.
    /// While paused it only marks the sentence, for Resume to speak.
    private func speakSentence(from position: EPUBTextPosition, session: Int) async {
        var position = position
        while session == self.session {
            guard position.chapter < chapterCount() else { break }
            if skipsChapter(position.chapter) {
                position = EPUBTextPosition(chapter: position.chapter + 1, offset: 0)
                continue
            }
            guard let chapter = await load(position.chapter, session: session), session == self.session else { break }
            // A recording that can't play at all leaves its chapter to the voice.
            let isNarrated = chapter.clips.contains { !unplayable.contains($0.audio) }
            if isNarrated, let clip = chapter.clips.firstIndex(where: {
                NSMaxRange($0.range) > position.offset && !unplayable.contains($0.audio)
            }) {
                playClip(clip, from: position.offset)
                return
            }
            if !isNarrated, var sentence = Self.sentence(in: chapter.text, from: position.offset) {
                activeNarration = false
                if let limit, limit.chapter == position.chapter {
                    guard sentence.location < limit.offset else { break }
                    sentence.length = min(sentence.length, limit.offset - sentence.location)
                }
                if state == .paused {
                    held = EPUBTextPosition(chapter: position.chapter, offset: sentence.location)
                    setSpoken(EPUBSpokenRange(chapter: position.chapter, sentence: sentence))
                    return
                }
                let synthesizer = synthesizer ?? makeSynthesizer()
                if self.synthesizer == nil {
                    self.synthesizer = synthesizer
                    synthesizer.onEvent = { [weak self] in self?.handle($0) }
                }
                setSpoken(EPUBSpokenRange(chapter: position.chapter, sentence: sentence))
                playing = nil
                sounding = synthesizer
                synthesizer.speak(Self.speech(chapter.text.substring(with: sentence)), language: chapter.language)
                return
            }
            position = EPUBTextPosition(chapter: position.chapter + 1, offset: 0)
            if let limit, position.chapter > limit.chapter { break }
        }
        if session == self.session { stop() }
    }

    /// Plays the first playable clip from `index` of the loaded chapter, or
    /// moves on to the next chapter. `offset` is where the text starts being
    /// read: a clip begun midway plays from about there, in proportion, and
    /// paints from there. One with no known end plays and paints from its start.
    /// A clip's sound is never cut, even past a selection's end.
    private func playClip(_ index: Int, from offset: Int = 0) {
        guard let chapter = loaded, index <= chapter.clips.count else { return stop() }
        guard let next = chapter.clips[index...].firstIndex(where: { !unplayable.contains($0.audio) }) else {
            let following = EPUBTextPosition(chapter: chapter.chapter + 1, offset: 0)
            if let limit, following.chapter > limit.chapter { return stop() }
            let session = session
            Task { await speakSentence(from: following, session: session) }
            return
        }
        var clip = chapter.clips[next]
        let requestedStart = max(clip.range.location, offset)
        let start = clip.end == nil ? clip.range.location : requestedStart
        if start > clip.range.location, let end = clip.end {
            clip.begin += (end - clip.begin) * Double(start - clip.range.location) / Double(clip.range.length)
        }
        var range = NSRange(location: start, length: NSMaxRange(clip.range) - start)
        if let limit, limit.chapter == chapter.chapter {
            guard range.location < limit.offset else { return stop() }
            range.length = min(range.length, limit.offset - range.location)
        }
        activeNarration = true
        setSpoken(EPUBSpokenRange(chapter: chapter.chapter, sentence: range))
        guard state != .paused else {
            heldClip = (next, requestedStart)
            return
        }
        let narrator = narrator ?? makeNarrator()
        if self.narrator == nil {
            self.narrator = narrator
            narrator.rate = narrationRate
            narrator.onEvent = { [weak self] in self?.handle($0) }
        }
        playing = (next, requestedStart)
        sounding = narrator
        narrator.play(clip)
    }

    /// A clip's audio file can't play: on to the next clip that can, or back
    /// to the voice when none of this chapter's can.
    private func clipFailed(_ index: Int, from offset: Int) {
        guard let chapter = loaded, chapter.clips.indices.contains(index) else { return stop() }
        let clip = chapter.clips[index]
        unplayable.insert(clip.audio)
        playing = nil
        if chapter.clips.contains(where: { !unplayable.contains($0.audio) }) {
            playClip(index + 1)
        } else {
            let position = EPUBTextPosition(chapter: chapter.chapter, offset: offset)
            let session = session
            Task { await speakSentence(from: position, session: session) }
        }
    }

    private struct SpokenChapter {
        let chapter: Int
        let text: NSString
        let language: String?
        let clips: [EPUBNarrationClip]
    }

    private func load(_ chapter: Int, session: Int) async -> SpokenChapter? {
        if let loaded, loaded.chapter == chapter { return loaded }
        guard let string = await chapterText(chapter) else { return nil }
        let clips = await chapterClips(chapter)
        let text = string as NSString
        // A stopped session's late load must not replace the current chapter.
        guard session == self.session else { return nil }
        let loaded = SpokenChapter(chapter: chapter, text: text, language: Self.language(of: text), clips: clips)
        self.loaded = loaded
        return loaded
    }

    private func handle(_ event: EPUBSpeechEvent) {
        guard isActive, var spoken else { return }
        switch event {
        case .willSpeak(let local):
            guard local.location != NSNotFound, NSMaxRange(local) <= spoken.sentence.length else { return }
            spoken.word = NSRange(location: spoken.sentence.location + local.location, length: local.length)
            setSpoken(spoken)
        case .failed:
            if let playing { clipFailed(playing.index, from: playing.offset) }
        case .finished:
            // In step, so the next clip of a file runs on without a gap.
            if let playing { return playClip(playing.index + 1) }
            let next = EPUBTextPosition(chapter: spoken.chapter, offset: NSMaxRange(spoken.sentence))
            let session = session
            Task { await speakSentence(from: next, session: session) }
        }
    }

    private func setSpoken(_ new: EPUBSpokenRange?) {
        spoken = new
        NotificationCenter.default.post(name: .epubPageMarksDidChange, object: self)
        if let new { onSpokenMove(new) }
    }

    // MARK: - Text

    /// A sentence at most this long; longer runs (a table, a list without
    /// stops) are read in pieces.
    static let maxSentenceLength = 600

    /// The next sentence from `offset`: past blanks, line breaks and images,
    /// ending at its paragraph's end at the latest, without the blanks at
    /// its end. Nil past the text's last words.
    static func sentence(in text: NSString, from offset: Int) -> NSRange? {
        func isBlank(_ index: Int) -> Bool {
            let character = text.character(at: index)
            return character == 0xFFFC || (Unicode.Scalar(character).map(CharacterSet.whitespacesAndNewlines.contains) ?? false)
        }
        var start = max(0, offset)
        while start < text.length, isBlank(start) { start += 1 }
        guard start < text.length else { return nil }
        let paragraph = text.paragraphRange(for: NSRange(location: start, length: 0))
        let rest = NSRange(location: start, length: NSMaxRange(paragraph) - start)
        var sentence = rest
        text.enumerateSubstrings(in: rest, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            sentence = range
            stop.pointee = true
        }
        sentence = NSRange(location: start, length: NSMaxRange(sentence) - start)
        if sentence.length > maxSentenceLength {
            // At the last space inside the limit, else at the limit.
            let window = NSRange(location: start, length: maxSentenceLength)
            let space = text.rangeOfCharacter(from: .whitespaces, options: .backwards, range: window)
            let end = space.location != NSNotFound && space.location > start ? space.location : NSMaxRange(window)
            sentence.length = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start)).length
        }
        while sentence.length > 0, isBlank(NSMaxRange(sentence) - 1) { sentence.length -= 1 }
        return sentence.length > 0 ? sentence : nil
    }

    /// The words the voice gets: images become spaces, so its word offsets
    /// stay the chapter's.
    static func speech(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: " ")
    }

    /// The chapter's main language, from its opening.
    static func language(of text: NSString) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text.substring(with: NSRange(location: 0, length: min(text.length, 2_000))))
        return recognizer.dominantLanguage?.rawValue
    }

    // MARK: - Following

    /// The book was laid out anew: where the view lands isn't the reader's move.
    func viewRelaidOut() { layoutMoves &+= 1 }

    /// The pages that count as showing the voice: the ones on screen; in the
    /// continuous layouts, the rows around them, where the stack scrolls the
    /// line into view itself.
    static func pagesInView(currentPage: Int, pagesPerRow: Int, isContinuous: Bool) -> Range<Int> {
        isContinuous
            ? max(0, currentPage - pagesPerRow)..<(currentPage + pagesPerRow * 2)
            : currentPage..<(currentPage + pagesPerRow)
    }

    /// Where a continuous stack scrolls (its new top) to keep the spoken line
    /// in view: nil while the line is inside the window below the chrome,
    /// else the line placed a third of the way down.
    static func scrollTop(keeping line: CGRect, visible: CGRect, topInset: CGFloat) -> CGFloat? {
        let top = visible.minY + topInset
        let margin = min(line.height * 2, (visible.height - topInset) / 4)
        guard line.minY < top || line.maxY > visible.maxY - margin else { return nil }
        return line.minY - topInset - (visible.height - topInset) / 3
    }

    /// Where a stack scrolls sideways to keep the spoken words in view when
    /// zoomed: a vertical page's columns leave to the side. Nil while they're
    /// in view, or for a line wider than the window, which can't be.
    static func scrollLeft(keeping line: CGRect, visible: CGRect) -> CGFloat? {
        guard line.width < visible.width, line.minX < visible.minX || line.maxX > visible.maxX else { return nil }
        return line.midX - visible.width / 2
    }
}

/// Whether Read Aloud keeps its words on screen. It does from the start
/// and whenever they are in view; once the reader moves the view away from
/// them (a turn, a scroll, a jump), it leaves the reader there until the
/// words are back in view.
struct EPUBReadAloudFollow {
    private var following = true
    private var lastPlace: Int?

    /// Returns whether to bring the words into view. `place` is what the
    /// view shows (its page, its scroll offset); `inView` whether the
    /// words are in it.
    mutating func shouldFollow(inView: Bool, at place: Int) -> Bool {
        defer { lastPlace = place }
        if inView {
            following = true
            return false
        }
        if let lastPlace, lastPlace != place { following = false }
        return following
    }

    /// The view moved to `place` to follow the words.
    mutating func followed(to place: Int) {
        lastPlace = place
    }
}

/// The system voice. The reader's Spoken Content voice and rate are used,
/// unless the book is in a language that voice doesn't speak; then the best
/// installed voice for the book's language reads at the default rate.
final class EPUBSystemSpeech: NSObject, EPUBSpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onEvent: ((EPUBSpeechEvent) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    /// Held so a finished utterance's address is never reused by the next.
    private var current: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, language: String?) {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = Self.voice(for: language, readerLanguage: Self.readerVoiceLanguage) {
            utterance.voice = voice
        } else {
            utterance.prefersAssistiveTechnologySettings = true
        }
        current = utterance
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The language of the reader's Spoken Content voice. Only the older
    /// synthesizer reports that voice; AVFoundation has no call for it.
    static var readerVoiceLanguage: String? {
        NSSpeechSynthesizer.attributes(forVoice: NSSpeechSynthesizer.defaultVoice)[.localeIdentifier] as? String
    }

    /// A voice for the book's language, or nil for the reader's own voice.
    static func voice(for language: String?, readerLanguage: String?) -> AVSpeechSynthesisVoice? {
        func base(_ code: String) -> Substring { code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "" }
        guard let language, base(language) != base(readerLanguage ?? "") else { return nil }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { base($0.language) == base(language) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(.willSpeak(range), for: id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.deliver(.finished, for: id) } }
    }

    /// Only the utterance being read reports; one stopped reports nothing.
    private func deliver(_ event: EPUBSpeechEvent, for utterance: ObjectIdentifier) {
        guard let current, utterance == ObjectIdentifier(current) else { return }
        onEvent?(event)
    }
}
