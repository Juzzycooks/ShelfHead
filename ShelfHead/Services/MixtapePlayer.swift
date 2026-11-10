import Foundation

/// Batch 458: pure sequencing for a mixtape, separate from the player so it is unit-tested.
nonisolated enum MixtapeSequencerAction: Equatable, Sendable {
    /// Keep playing the current clip.
    case continuePlaying
    /// The current clip is over; play clip `index` next.
    case advance(to: Int)
    /// The last clip is over.
    case finish
    /// The listener switched to something else; stop sequencing without touching playback.
    case abandon
}

nonisolated enum MixtapeSequencer {
    /// Slack so the end is not missed between polls.
    static let endTolerance = 0.05

    static func action(clips: [MixtapeClip], index: Int, playingItemId: String?, position: Double,
                       duration: Double? = nil) -> MixtapeSequencerAction {
        guard clips.indices.contains(index) else { return .finish }
        let clip = clips[index]
        guard playingItemId == clip.itemId else { return .abandon }
        // Review 5 Medium 3: a clip ending at the book's end pauses there; clamp so it still finishes.
        let end = duration.map { $0 > 0 ? min(clip.end, $0) : clip.end } ?? clip.end
        guard position >= end - endTolerance else { return .continuePlaying }
        return index + 1 < clips.count ? .advance(to: index + 1) : .finish
    }
}

/// Review 4 High 1: why a mixtape stopped sequencing, for the post-mixtape suppression decision.
nonisolated enum MixtapeEndReason: Equatable, Sendable {
    /// Stopped by the listener, or the last clip finished: the player still holds a clip position.
    case stoppedOrFinished
    /// The listener started something else (or the same book on their own): it isn't a clip.
    case abandoned
}

nonisolated enum MixtapeSuppression {
    /// Whether `suppressProgressSync` stays on once sequencing ends. Pure, for tests.
    static func suppressionAfterEnd(reason: MixtapeEndReason) -> Bool { reason == .stoppedOrFinished }
}

/// Batch 458: plays a mixtape's clips in order through the app's player. Started only by a Play tap.
/// Each clip: make sure its book is the loaded one (`startPlayback`), seek to the clip start, play;
/// a 0.1 s poll on `currentTime` hands the position to `MixtapeSequencer`. After the last clip the
/// player is paused. `stop()` ends sequencing and pauses; normal playback carries on from there.
///
/// Progress: while a mixtape is active, `AudioPlayerService.suppressProgressSync` is on, so clip
/// positions never become a book's saved progress. It's switched back off when the mixtape stops
/// or finishes (the player is paused then; the next sync is whatever the listener plays next).
@MainActor
@Observable
final class MixtapePlayer {
    static let shared = MixtapePlayer()

    enum Phase: Equatable { case idle, loading, playing, finished }

    private(set) var mixtape: Mixtape?
    private(set) var index = 0
    private(set) var phase: Phase = .idle {
        // Review 3 High 3: suppression turns on with the mixtape but is NOT turned off when it
        // ends; the player still holds the last clip's book at the clip position, so the next
        // flush must not write it. AudioPlayerService clears it on the listener's next play/load.
        didSet {
            AudioPlayerService.shared.mixtapeDriving = isActive
            if isActive { AudioPlayerService.shared.clearResumedFromMixtapeClip() }   // Review 5 Low (resumedFromMixtapeClip): a new mixtape
            if isActive { AudioPlayerService.shared.suppressProgressSync = true }
        }
    }
    private(set) var message: String?

    var isActive: Bool { phase == .loading || phase == .playing }
    var clipCount: Int { mixtape?.clips.count ?? 0 }
    /// "Clip 2 of 5" for the banner.
    var bannerText: String? {
        guard isActive, mixtape != nil else { return nil }
        return String(localized: "Clip \(index + 1) of \(clipCount)", comment: "Mixtape banner: position in the mixtape, e.g. Clip 2 of 5")
    }

    /// True after the loaded book's session was closed up front: the first clip must start a
    /// new session even when its book is already loaded.
    @ObservationIgnored private var needsFreshSession = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var player: PlayerViewModel?

    private init() {}

    /// Start (or restart) a mixtape at `clip`. Call from a button the listener tapped.
    func play(_ mixtape: Mixtape, from clip: Int = 0, using player: PlayerViewModel) {
        guard mixtape.clips.indices.contains(clip) else { return }
        let previous = task
        previous?.cancel()
        // Review 2 High 2 (30 October 2026): before suppression turns on (the `phase` didSet
        // below), save the loaded book's real position and close its session. Only on a
        // fresh start; a skip or restart is already suppressed and already flushed.
        if !isActive {
            AudioPlayerService.shared.flushAndCloseForMixtape()
            needsFreshSession = true
        }
        self.mixtape = mixtape
        self.player = player
        index = clip
        message = nil
        phase = .loading
        // Review 6 Medium 11: wait for the cancelled run to unwind so its in-flight load can't make
        // this run's startPlayback get refused ("another load in flight") and skip a clip.
        task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.run(startingAt: clip)
        }
    }

    /// Skip to the next clip (the banner's button).
    func skipToNext() {
        guard isActive, let mixtape, index + 1 < mixtape.clips.count, let player else { return }
        play(mixtape, from: index + 1, using: player)
    }

    func stop() {
        task?.cancel()   // kept (not nil'd) so a play() right after can wait for it to unwind (Review 6 Medium 11)
        if isActive, let player, player.isPlaying { player.togglePlayPause() }
        // Review 3 Low (early stop): the loaded book's session was closed up front; if no clip
        // loaded a new one yet, make sure the next mixtape start opens a fresh session.
        if isActive { needsFreshSession = true }
        phase = .idle
        message = nil
        AudioPlayerService.shared.clearResumedFromMixtapeClip()   // Review 5 Low (resumedFromMixtapeClip)
    }

    private func run(startingAt first: Int) async {
        guard let mixtape, let player else { return }
        var i = first
        while !Task.isCancelled, mixtape.clips.indices.contains(i) {
            index = i
            phase = .loading
            guard await load(mixtape.clips[i], player: player) else {
                guard !Task.isCancelled else { return }   // Review 5 Low (skip during load): a cancelled run says nothing
                // Skip a clip whose book can't be loaded; say so.
                message = String(localized: "Skipped a clip that couldn't be loaded.", comment: "Mixtape: a clip's book isn't on this server or failed to start")
                i += 1
                continue
            }
            phase = .playing
            switch await follow(from: i, player: player, clips: mixtape.clips) {
            case .advance(let next): i = next
            case .finish:
                if player.isPlaying { player.togglePlayPause() }
                phase = .finished
                return
            case .abandon, .continuePlaying:
                // A cancelled run (stop or a restart) is handled by whoever cancelled it.
                guard !Task.isCancelled else { return }
                phase = .idle
                // Review 4 High 1: the listener started a book while the clips played; what's
                // playing now is real listening, so its progress must sync again.
                AudioPlayerService.shared.suppressProgressSync =
                    MixtapeSuppression.suppressionAfterEnd(reason: .abandoned)
                return
            }
        }
        if !Task.isCancelled { phase = .finished }
    }

    private func load(_ clip: MixtapeClip, player: PlayerViewModel) async -> Bool {
        if player.currentBook?.id != clip.itemId || needsFreshSession {
            guard let item = try? await AudiobookshelfAPI.shared.getItem(itemId: clip.itemId), !Task.isCancelled else { return false }
            await player.startPlayback(for: item, openPlayer: false)
            // Review 5 High 1: Stop (or a restart) arrived during the load. The load may have
            // autoplayed and cleared suppression (not driving any more); undo both, don't seek/play.
            if Task.isCancelled {
                AudioPlayerService.shared.suppressProgressSync = true
                // Review 6 Low (cancel check): pause unconditionally so a pending autoplay can't start later.
                AudioPlayerService.shared.pause()
                return false
            }
            guard player.currentBook?.id == clip.itemId else { return false }
            needsFreshSession = false   // Review 3 Low (fresh session): only once the load succeeded
        }
        player.seek(to: clip.start, reason: .clip)
        if !player.isPlaying { player.togglePlayPause() }
        // Let the seek land so the first poll doesn't read the old position.
        try? await Task.sleep(for: .milliseconds(400))
        return !Task.isCancelled
    }

    private func follow(from i: Int, player: PlayerViewModel, clips: [MixtapeClip]) async -> MixtapeSequencerAction {
        while !Task.isCancelled {
            let action = MixtapeSequencer.action(clips: clips, index: i, playingItemId: player.currentBook?.id,
                                                 position: player.currentTime, duration: player.duration)
            if action != .continuePlaying { return action }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .abandon
    }
}
