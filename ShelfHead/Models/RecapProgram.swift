import Foundation

/// Batch 433: the shared shapes behind the narrator "Previously On…" montage (a few key
/// moments from the heard book, played in the narrator's own voice, optionally linked by
/// short spoken lines) and its playback through the app's Now Playing surfaces.
///
/// Frozen for the batch: `RecapProgramPlanner` (pure planning), `BookIntelligence`
/// (writes the script with the on-device model), `RecapAudioRenderer` (turns a program into
/// one audio file) and `RecapPlaybackController` (plays it) all build against these.

/// One step of a montage, in play order.
nonisolated enum RecapProgramItem: Codable, Equatable, Sendable {
    /// A spoken link line (the app's speech voice), e.g. "Earlier, Holden found the letter."
    case speech(String)
    /// The narrator's own audio for `start..<end` (book seconds, sentence-snapped), with the
    /// transcript text of that range for display and VoiceOver.
    case clip(start: Double, end: Double, text: String)
}

/// A montage ready to render: what to play, plus what it was made from so a stale one is
/// remade once the listener has heard more.
nonisolated struct RecapProgram: Codable, Equatable, Sendable {
    /// Bump when the planning rules change in a way an old cached program shouldn't survive.
    /// 2 (Batch 435): spoken links are now written to be heard.
    nonisolated static let currentVersion = 2

    var version: Int
    var itemId: String
    /// The written recap (the same text the sheet shows), used as the speech-only fallback
    /// when no narrator audio can be cut.
    var summary: String
    var items: [RecapProgramItem]
    /// End (book seconds) of the last heard chunk the program was made from. A frontier past
    /// the next chunk's end means the listener has heard more; see `RecapProgramPlanner`.
    var madeThrough: Double
    /// `NotesCache.hash` over everything that shaped the program (chunk hashes, the
    /// spoken-links choice). Equal hash = reuse.
    var inputHash: String
    /// Whether spoken link lines are included (Settings › Transcripts, default off: narrator only).
    var spokenLinks: Bool
}

/// What a rendered montage file holds, cached beside it as `recap-audio.json` so playback can
/// show which moment is playing and skip between them.
nonisolated struct RecapAudioManifest: Codable, Equatable, Sendable {
    /// 2 (Batch 435): speech is paced SSML (`SpeechScript`), so older renders are remade.
    nonisolated static let currentVersion = 2

    struct Mark: Codable, Equatable, Sendable {
        /// Seconds into the rendered file where this item starts.
        var offset: Double
        var duration: Double
        var item: RecapProgramItem
    }

    var version: Int
    var itemId: String
    /// `RecapProgram.inputHash` it was rendered from, plus the voice identifier.
    var programHash: String
    var voiceIdentifier: String?
    var fileName: String
    var duration: Double
    var marks: [Mark]
    /// False when narrator audio couldn't be cut (offline and not downloaded, or export failed)
    /// and the file is the spoken summary only.
    var hasNarratorAudio: Bool
}

/// Something that briefly takes over the transport controls (Lock Screen, Control Center,
/// CarPlay, headphones, the session backend) from the book, then hands them back. Set on
/// `AudioPlayerService.transientOverride` while active; the service routes remote
/// play/pause/toggle/skip to it and publishes `nowPlaying` instead of the book.
@MainActor
protocol TransientPlaybackOverride: AnyObject {
    var overrideTitle: String { get }
    var overrideSubtitle: String { get }
    var overrideElapsed: Double { get }
    var overrideDuration: Double { get }
    var overrideIsPlaying: Bool { get }
    func overridePlay()
    func overridePause()
    func overrideTogglePlayPause()
    /// Skip forward/back: next/previous moment.
    func overrideSkip(forward: Bool)
    /// The book itself was asked to play (in-app play button, widget, Siri): stop the override
    /// without resuming the book (the caller is about to).
    func overrideYieldToBook()
}
