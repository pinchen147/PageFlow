//
//  EPUBNarration.swift
//  PageFlow
//
//  A book's own recording, for Read Aloud (EPUB 3 media overlays): its clips
//  in chapter offsets, and the player that sounds them from a temporary copy
//  of the audio file. The copy is gone once the player stops or goes away.
//

import AVFoundation
import EPUBKit
import Foundation

/// A stretch of recording and the text it reads, in chapter offsets.
struct EPUBNarrationClip: Equatable {
    var audio: String
    var begin: TimeInterval
    var end: TimeInterval?
    var range: NSRange

    /// The chapter's overlay placed on its text. A clip's text runs to the
    /// next clip's start (the last to its paragraph's end, or the chapter's
    /// when it reads the whole chapter). A clip whose element isn't in the
    /// text, or holds nothing, is left out: there is nothing to follow.
    static func clips(of overlay: EPUBMediaOverlay, text: NSString, anchors: [String: Int],
                      hidden: Set<String> = []) -> [EPUBNarrationClip] {
        func start(of clip: EPUBMediaOverlayClip) -> Int? {
            guard let fragment = clip.fragment else { return 0 }
            guard !hidden.contains(fragment), let anchor = anchors[fragment], anchor < text.length else { return nil }
            return anchor
        }
        let starts = Array(Set(overlay.clips.compactMap(start))).sorted()
        var nextStart: [Int: Int] = [:]
        for (start, next) in zip(starts, starts.dropFirst()) { nextStart[start] = next }

        return overlay.clips.compactMap { clip in
            guard let start = start(of: clip) else { return nil }
            let end = nextStart[start] ?? (clip.fragment == nil
                ? text.length : NSMaxRange(text.paragraphRange(for: NSRange(location: start, length: 0))))
            guard let range = trimmed(NSRange(location: start, length: end - start), in: text) else { return nil }
            return EPUBNarrationClip(audio: clip.audioPath, begin: clip.begin, end: clip.end, range: range)
        }
    }

    /// `range` without blanks at its ends; an image stays, it may be what's read.
    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange? {
        func isBlank(_ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        var range = range
        while range.length > 0, isBlank(range.location) {
            range.location += 1
            range.length -= 1
        }
        while range.length > 0, isBlank(NSMaxRange(range) - 1) { range.length -= 1 }
        return range.length > 0 ? range : nil
    }
}

/// Sounds a book's recording, or a fake in tests. Reports `.finished` when a
/// clip ends and `.failed` when its audio file can't be played; both arrive
/// after `play` returns.
@MainActor
protocol EPUBNarrationPlaying: EPUBSpeechEngine {
    var rate: Float { get set }
    /// Moves to `clip`. The next clip of a file follows without a gap when
    /// asked for from its predecessor's `.finished`.
    func play(_ clip: EPUBNarrationClip)
}

/// A temporary copy of a book's audio file, removed with the last reference,
/// so a copy still being written outlives a Stop safely.
nonisolated final class EPUBExtractedAudio: Sendable {
    /// One file at a time, so a whole audiobook never sits on disk.
    static let sizeLimit = 1024 * 1024 * 1024
    private static let prefix = "PageFlow-EPUBAudio-"
    /// A quit or crash leaves its copy behind; the next run clears it.
    static let staleCopiesCleared: Void = {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }()

    private let directory: URL
    let file: URL

    /// A place for the copy of `path`, keeping its extension: players use it
    /// to tell formats apart.
    init(path: String) throws {
        _ = Self.staleCopiesCleared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = (path as NSString).pathExtension.filter { $0.isLetter || $0.isNumber }
        file = directory.appendingPathComponent("audio").appendingPathExtension(fileExtension.isEmpty ? "audio" : fileExtension)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// Plays clips with `AVAudioPlayer`. A one-shot timer ends each clip: it runs
/// only while sound plays, and goes on the file's clock, not the wall's.
final class EPUBNarrationPlayer: NSObject, EPUBNarrationPlaying, AVAudioPlayerDelegate {
    typealias Extract = @Sendable (_ path: String, _ file: URL) throws -> Void

    var onEvent: ((EPUBSpeechEvent) -> Void)?
    var rate: Float = 1 {
        didSet {
            player?.rate = rate
            armClipEnd()
        }
    }
    /// Where playback is in the current file.
    var currentTime: TimeInterval { player?.currentTime ?? 0 }

    private let extract: Extract
    private var player: AVAudioPlayer?
    private var audio: EPUBExtractedAudio?
    private var audioPath: String?
    private var clip: EPUBNarrationClip?
    private var isPaused = false
    /// The file ran out just as Pause came: Resume moves on, not back to its start.
    private var endedWhilePaused = false
    private var loading: Task<LoadedAudio?, Never>?
    private var clipEnd: Timer?
    /// The file's clock when it last moved, to notice it has stopped.
    private var lastMove = (time: TimeInterval(-1), at: ContinuousClock.now)
    /// Bumps with every play and stop, so nothing older reports.
    private var generation = 0

    init(extract: @escaping Extract) {
        self.extract = extract
    }

    func play(_ clip: EPUBNarrationClip) {
        generation &+= 1
        endedWhilePaused = false
        self.clip = clip
        isPaused = false
        if let player, audioPath == clip.audio {
            begin(clip, on: player)
        } else {
            load(clip.audio)
        }
    }

    func pause() {
        isPaused = true
        clipEnd?.invalidate()
        player?.pause()
    }

    func resume() {
        isPaused = false
        if endedWhilePaused {
            endedWhilePaused = false
            return clipEnded()
        }
        if let player, let clip { start(clip, on: player) }
    }

    func stop() {
        generation &+= 1
        endedWhilePaused = false
        unload()
        clip = nil
        isPaused = false
    }

    // MARK: - Loading

    private nonisolated struct LoadedAudio: @unchecked Sendable {
        let audio: EPUBExtractedAudio
        let player: AVAudioPlayer
    }

    /// Copies the file out and opens it, off the main actor: a large file
    /// takes a moment.
    private func load(_ path: String) {
        unload()
        audioPath = path
        let (extract, rate, generation) = (extract, rate, generation)
        let task = Task.detached(priority: .userInitiated) { () -> LoadedAudio? in
            do {
                let audio = try EPUBExtractedAudio(path: path)
                try extract(path, audio.file)
                try Task.checkCancellation()
                let player = try AVAudioPlayer(contentsOf: audio.file)
                player.enableRate = true
                player.rate = rate
                player.prepareToPlay()
                return LoadedAudio(audio: audio, player: player)
            } catch {
                return nil
            }
        }
        loading = task
        Task { [weak self] in
            let loaded = await task.value
            guard let self, generation == self.generation, let clip = self.clip else { return }
            guard let loaded else { return self.fail() }
            self.audio = loaded.audio
            self.player = loaded.player
            // The speed may have changed while the file was copied out.
            loaded.player.rate = self.rate
            loaded.player.delegate = self
            self.begin(clip, on: loaded.player)
        }
    }

    private func unload() {
        loading?.cancel()
        loading = nil
        clipEnd?.invalidate()
        player?.stop()
        player = nil
        audio = nil
        audioPath = nil
    }

    // MARK: - Playing

    /// Places the file at the clip and plays, unless it already follows on.
    private func begin(_ clip: EPUBNarrationClip, on player: AVAudioPlayer) {
        clipEnd?.invalidate()
        lastMove = (-1, .now)
        // A file that opens but holds no sound is as good as undecodable.
        guard player.duration > 0 else { return fail() }
        guard clip.begin < player.duration else {
            // Past the recording's end: nothing to hear in this one.
            player.pause()
            return report(.finished)
        }
        let ahead = player.currentTime - clip.begin
        if ahead < -0.02 || ahead > 0.1 { player.currentTime = clip.begin }
        if !isPaused { start(clip, on: player) }
    }

    private func start(_ clip: EPUBNarrationClip, on player: AVAudioPlayer) {
        guard player.isPlaying || player.play() else { return fail() }
        armClipEnd()
    }

    private func report(_ event: EPUBSpeechEvent) {
        let generation = generation
        Task { [weak self] in
            guard let self, generation == self.generation else { return }
            self.clip = nil
            self.onEvent?(event)
        }
    }

    /// The file can't be played: its copy goes, and the reader moves on.
    private func fail() {
        unload()
        report(.failed)
    }

    private func armClipEnd() {
        clipEnd?.invalidate()
        guard let player, let clip, player.isPlaying else { return }
        let remaining = min(clip.end ?? player.duration, player.duration) - player.currentTime
        let wait = min(Self.longestWait, max(0.02, remaining / Double(max(rate, 0.1))))
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipEnd() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipEnd = timer
    }

    /// Checks at least this often, so a stopped clock is noticed.
    private static let longestWait: TimeInterval = 2

    /// The file's clock decides. A player that stopped by itself has nothing
    /// more of this clip; one whose clock stands still never will.
    private func checkClipEnd() {
        guard let player, let clip, !isPaused else { return }
        let time = player.currentTime
        if !player.isPlaying || time >= min(clip.end ?? player.duration, player.duration) - 0.015 {
            return clipEnded()
        }
        if time > lastMove.time {
            lastMove = (time, .now)
        } else if ContinuousClock.now - lastMove.at > .seconds(Self.longestWait) {
            return fail()
        }
        armClipEnd()
    }

    /// The reader's next clip arrives during `.finished`, so sound runs on
    /// into it; with none, sound stops where this clip ended.
    private func clipEnded() {
        clipEnd?.invalidate()
        clip = nil
        onEvent?(.finished)
        if clip == nil { player?.pause() }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.playerEnded(id, failed: !flag) } }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.playerEnded(id, failed: true) } }
    }

    /// Only the current player reports, and only if it hasn't gone on to the
    /// next clip since.
    private func playerEnded(_ id: ObjectIdentifier, failed: Bool) {
        guard let player, id == ObjectIdentifier(player), clip != nil, !player.isPlaying else { return }
        if isPaused, !failed {
            endedWhilePaused = true
            return
        }
        guard !isPaused else { return }
        if failed { fail() } else { clipEnded() }
    }
}
