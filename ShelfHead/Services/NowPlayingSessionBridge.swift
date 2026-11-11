import Foundation
import CoreGraphics

#if canImport(NowPlaying)
import NowPlaying
#endif

// MARK: - Pure rules

/// Batch 327: the decision layer behind ShelfHead's adoption of iOS 27's `NowPlaying`
/// framework (`MediaSession`), which Apple presents as the replacement for
/// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.
///
/// Deliberately **not** availability-gated and **not** actor-isolated: every function
/// here is a pure function over its arguments, so it compiles and unit-tests on any OS
/// (see `NowPlayingSessionRulesTests`) while the framework-touching types below are
/// `@available(iOS 27, *)` inside `#if canImport(NowPlaying)`. Same precedent as
/// `CarPlayCoordinator.nextPlaybackRate(after:)` — the rule is testable, the surface it
/// drives is not.
///
/// **Why either/or, not both.** There is no published guidance on whether a
/// `MediaSession` and the two Media Player classes may be active simultaneously, and the
/// failure mode if they can't is bad in a specific way: both paths register a skip
/// handler, so one lock-screen tap would skip twice. So the design is strictly one
/// backend per launch — when `resolveBackend` says `.session`, `AudioPlayerService` must
/// not write `MPNowPlayingInfoCenter.nowPlayingInfo` and must not register any
/// `MPRemoteCommandCenter` targets, and vice versa.
enum NowPlayingSessionRules {

    /// Which now-playing implementation a launch uses.
    /// `Sendable` so `NowPlayingSessionBridge.backend` can be the `nonisolated static
    /// let` it needs to be (read from `AudioPlayerService`, whose `init()` is itself
    /// `nonisolated`) without tripping strict-concurrency checking.
    enum Backend: Equatable, Sendable {
        /// iOS 27's `NowPlaying.MediaSession` — the model-observing path.
        case session
        /// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` — everything up to iOS 26,
        /// and the user-selectable fallback on iOS 27 (`SettingsStore.classicNowPlaying`).
        case classic
    }

    /// **The one constant to flip when deciding what ships.**
    ///
    /// `false` means iOS 27 devices default to the new `MediaSession` backend and the
    /// classic path is opt-in; `true` inverts that (classic by default, `MediaSession`
    /// opt-out). Nothing else in the app hardcodes a preference — `SettingsStore
    /// .classicNowPlaying` registers *this* value as its `UserDefaults` default, so
    /// changing it here changes the shipping default for every user who hasn't touched
    /// the toggle.
    ///
    /// Pending a simulator lock-screen pass (Lock Screen / Control Center / Dynamic
    /// Island / CarPlay) before this is considered settled. [device check]
    static let defaultPrefersClassic: Bool = false

    /// Classic whenever the framework isn't available *or* the user asked for it.
    /// `sessionAvailable` is the compile-and-runtime availability of `NowPlaying`
    /// (`#if canImport` ∧ `#available(iOS 27, *)`), resolved by the caller.
    static func resolveBackend(sessionAvailable: Bool, prefersClassic: Bool) -> Backend {
        guard sessionAvailable, !prefersClassic else { return .classic }
        return .session
    }

    /// 1-based `(current, total)` chapter position for `BookContent.chapter`, or `nil`
    /// for a book with no chapter data (the framework wants the field absent, not a
    /// `(0, 0)` sentinel).
    ///
    /// Containment uses the same half-open `start ..< end` rule as
    /// `AudioPlayerService.currentChapter` and `PlayerViewModel.chapterIndex(in:at:)`,
    /// so a position exactly on a boundary belongs to the *next* chapter everywhere in
    /// the app. When no chapter contains `currentTime` — before the first chapter's
    /// start, past the last chapter's end, or inside a gap between two chapters — the
    /// answer is clamped to the last chapter that *starts* at or before the position,
    /// falling back to chapter 1 when even that doesn't exist. That makes "before the
    /// first chapter" → 1 and "after the last chapter" → `total`, and a gap resolve to
    /// the chapter the listener most recently left rather than jumping to the end.
    static func chapterPosition(currentTime: Double, chapters: [Chapter]) -> (current: Int, total: Int)? {
        guard !chapters.isEmpty else { return nil }
        let total = chapters.count
        if let index = chapters.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end }) {
            return (index + 1, total)
        }
        if let index = chapters.lastIndex(where: { $0.start <= currentTime }) {
            return (index + 1, total)
        }
        return (1, total)
    }

    /// A framework-free mirror of the subset of
    /// `MediaPlaybackSnapshot.PlaybackState` this app publishes, so the mapping rule is
    /// testable on any OS. `NowPlayingSessionModel.playbackSnapshot` translates it.
    ///
    /// Only three cases: ShelfHead never publishes `.buffering` or `.interrupted`.
    /// LS-1 (docs/design-review.md): `isBuffering` is now shown in-app — the mini player
    /// and full player transport rings — but it's still deliberately not published to
    /// the Lock Screen here, and an interruption already comes through as a plain pause
    /// everywhere else in the app — introducing a fourth state on the lock screen only,
    /// and only on iOS 27, would make the two backends visibly disagree.
    enum SnapshotState: Equatable {
        case stopped
        case playing(rate: Float)
        case paused
    }

    /// `.stopped` whenever nothing is loaded, regardless of the other two arguments —
    /// `isPlaying` can briefly be true with no session during teardown, and publishing
    /// "playing" for a book that isn't there is the one state the lock screen can't
    /// recover from on its own.
    static func playbackState(hasItem: Bool, isPlaying: Bool, rate: Float) -> SnapshotState {
        guard hasItem else { return .stopped }
        return isPlaying ? .playing(rate: rate) : .paused
    }

    /// The app's own speed ladder, 0.5× to 3.0× in 0.25 steps — the same range
    /// `PlayerViewModel.setPlaybackRate` clamps to and `CarPlayCoordinator
    /// .nextPlaybackRate(after:)` steps across, so the iOS 27 rate picker offers exactly
    /// the rates the rest of the app accepts.
    ///
    /// Built from integer quarters rather than `stride(from: 0.5, through: 3.0, by:
    /// 0.25)` so the values are exactly representable and the top of the ladder is
    /// reliably 3.0 rather than 2.9999998 (which would round-trip into `perBookSpeed`
    /// and show as "3×" while never equalling it).
    static func supportedRates() -> [Float] {
        (2...12).map { Float($0) * 0.25 }
    }

    /// Clamp for `seekToPosition`, whose `TimeInterval` comes from a system scrubber and
    /// so can arrive negative, past the end, or non-finite. Mirrors
    /// `AudioPlayerService.clampedSeekTarget(current:delta:duration:)`'s contract: an
    /// unknown duration (0, or non-finite for an offline manifest session) is trusted
    /// rather than used to clamp the position to nothing.
    static func clampedSeekTarget(_ requested: TimeInterval, duration: Double) -> Double {
        guard requested.isFinite else { return 0 }
        if requested <= 0 { return 0 }
        guard duration.isFinite, duration > 0 else { return requested }
        return min(requested, duration)
    }

    // MARK: Batch 328 — what the Lock Screen actually renders

    /// The second Lock Screen line. Batch 328: the device pass showed iOS draws exactly
    /// two lines of text for a now-playing item and ignores `BookContent.chapter` (the
    /// daemon receives `ChapterNumber`/`TotalChapterCount`, the Lock Screen never shows
    /// them). The classic path put the chapter title in the album slot, which the system
    /// rendered as "Author — Chapter" on that second line — this reproduces it. No chapter
    /// (or a blank chapter title) leaves the author alone.
    static func subtitle(author: String, chapterTitle: String?) -> String {
        let trimmedAuthor = author.trimmingCharacters(in: .whitespaces)
        guard let chapter = chapterTitle?.trimmingCharacters(in: .whitespaces), !chapter.isEmpty else {
            return trimmedAuthor
        }
        return trimmedAuthor.isEmpty ? chapter : "\(trimmedAuthor) — \(chapter)"
    }

    /// Chapter-relative scrubber values, exactly the coordinate space
    /// `AudioPlayerService.updateNowPlaying()` publishes on the classic path: inside a
    /// chapter, elapsed counts from the chapter start and the duration is the chapter's
    /// length; with no chapter, whole-book values. Clamped so a position a hair outside
    /// the chapter (the boundary tick) can't show a negative or over-full scrubber.
    /// `nil` duration means "unknown" — a chapterless offline session before the asset
    /// reports a length.
    static func scrubberTiming(currentTime: Double, chapterStart: Double?, chapterEnd: Double?,
                               bookDuration: Double) -> (elapsed: Double, duration: Double?) {
        if let start = chapterStart, let end = chapterEnd, end > start, start.isFinite, end.isFinite {
            let length = end - start
            let elapsed = min(max(currentTime - start, 0), length)
            return (elapsed.isFinite ? elapsed : 0, length)
        }
        let duration: Double? = (bookDuration.isFinite && bookDuration > 0) ? bookDuration : nil
        let elapsed = currentTime.isFinite ? max(currentTime, 0) : 0
        return (duration.map { min(elapsed, $0) } ?? elapsed, duration)
    }

    /// The inverse of `scrubberTiming` for `seekToPosition`: the system hands back a
    /// position in the scrubber's coordinate space, so inside a chapter it is offset from
    /// that chapter's start (mirrors `changePlaybackPositionCommand`'s `+ currentChapter
    /// ?.start`), then clamped to the book like `clampedSeekTarget`.
    static func absoluteSeekTarget(_ requested: TimeInterval, chapterStart: Double?, bookDuration: Double) -> Double {
        let relative = requested.isFinite ? max(requested, 0) : 0
        let offset = (chapterStart?.isFinite ?? false) ? max(chapterStart ?? 0, 0) : 0
        return clampedSeekTarget(offset + relative, duration: bookDuration)
    }

    /// Framework-free mirror of `MediaCommand.FeedbackStatus`.
    enum FeedbackInput: Equatable { case positive, neutral, negative }

    /// What a tap on the Lock Screen's star should do. Batch 328: the daemon registers
    /// `.feedback` as a Like *and* a Dislike command, so the closure fires for both and
    /// for un-liking; "create a bookmark on every call" would bookmark a thumbs-down and
    /// double-bookmark a second tap. The star is a toggle for "a bookmark at this moment":
    /// filled while one made from the star sits within `nearbyTolerance` of the position.
    enum FeedbackAction: Equatable {
        case createBookmark
        case deleteBookmark(at: Double)
        case ignore
    }

    /// Bookmarks made from the star this session that count as "here" — the same width a
    /// listener would call the same moment after a skip back.
    static let nearbyTolerance: Double = 10

    static func nearbyBookmark(times: [Double], currentTime: Double, tolerance: Double = nearbyTolerance) -> Double? {
        guard currentTime.isFinite else { return nil }
        return times
            .filter { $0.isFinite && abs($0 - currentTime) <= tolerance }
            .min { abs($0 - currentTime) < abs($1 - currentTime) }
    }

    static func feedbackAction(_ input: FeedbackInput, nearbyBookmark: Double?) -> FeedbackAction {
        switch input {
        case .positive:
            return nearbyBookmark == nil ? .createBookmark : .ignore
        case .neutral:
            return nearbyBookmark.map { .deleteBookmark(at: $0) } ?? .ignore
        case .negative:
            return .ignore
        }
    }
}

// MARK: - The observed model

#if canImport(NowPlaying)

/// Batch 327: the `MediaSessionRepresentable` iOS 27's now-playing surfaces read.
///
/// All three protocol properties are **computed**, reading `AudioPlayerService.shared`
/// live. That is the whole point of the framework's model: `MediaSession` observes this
/// object, `AudioPlayerService` is already `@Observable`, and reading its properties from
/// inside these getters registers the framework's observation on *those* properties
/// transitively — so the lock screen, Control Center, Dynamic Island and CarPlay stay
/// current with **zero** publish calls from the player. Nothing in `AudioPlayerService`
/// has to call into this type on a timer, on a seek, or on a rate change (compare
/// `updateNowPlaying()`, which the classic path has to invoke from ~a dozen sites).
///
/// **Batch 328 correction.** Batch 327 published *whole-book* elapsed/duration plus
/// `BookContent.chapter` ("3 of 41"), on the theory that the framework's typed model would
/// render it. The device pass on an iOS 27 phone showed it does not: the Lock Screen draws
/// two text lines (title, author) and ignores the chapter field, so the user lost the
/// chapter title the classic path showed and got a whole-book scrubber for nothing. The
/// model now reproduces the classic path's Lock Screen exactly — "Title" /
/// "Author — Chapter title", chapter-relative scrubber, `seekToPosition` adding the
/// chapter start back — via `GenericContent` whenever a chapter is playing (see `content`).
@available(iOS 27, *)
@MainActor
@Observable
final class NowPlayingSessionModel: MediaSessionRepresentable {

    /// Stable for the life of the process and across books: the system keys the session
    /// on this, and ShelfHead only ever has one playback session at a time (a book
    /// change is a content change, not a new session).
    nonisolated var id: String { "com.shelfhead.playback" }

    /// Bookmarks created from the Lock Screen star this session, per item, in absolute
    /// book time. Stored (not computed) so a change re-runs `commands` through the
    /// framework's observation and the star fills/empties. Batch 328 — see
    /// `NowPlayingSessionRules.feedbackAction`. Deliberately not seeded from the server's
    /// bookmark list: the star's promise is "you bookmarked *this* moment from here", and
    /// the full list lives in the player UI.
    private var starBookmarkTimes: [String: [Double]] = [:]

    var content: (any MediaContentRepresentable)? {
        let service = AudioPlayerService.shared
        guard let itemId = service.currentItemId else { return nil }
        // Batch 433: while the "Previously On…" montage owns the transport it is the content: its
        // title/subtitle and own duration, with the book's cover. Reading `transientOverride` and the
        // override's own (observable) properties here is what re-publishes this when they change.
        if let override = service.transientOverride {
            let length = override.overrideDuration
            let recapDuration: MediaDuration? = (length.isFinite && length > 0) ? .finite(length) : nil
            return GenericContent(
                id: "recap-\(itemId)",
                title: override.overrideTitle,
                subtitle: override.overrideSubtitle,
                type: .audio,
                duration: recapDuration,
                artwork: Self.makeArtwork(itemId: itemId))
        }
        let item = service.currentSession?.libraryItem
        let title = item?.title ?? String(localized: "Unknown", comment: "Now Playing title placeholder when the book title is unavailable")
        let author = item?.authorName ?? ""
        let chapter = service.currentChapter
        let timing = NowPlayingSessionRules.scrubberTiming(
            currentTime: service.currentTime, chapterStart: chapter?.start, chapterEnd: chapter?.end,
            bookDuration: service.duration)
        // Explicit type rather than an inline ternary: `.finite(x)` vs `nil` against an
        // `Optional` parameter is the kind of inference that reads fine and then fails in
        // a way that looks unrelated. `.finite` only for a real length — an
        // offline-manifest session can legitimately not know one yet, and `.finite(0)`
        // would publish a scrubber with nowhere to go. `.continuous` is wrong too: the
        // book does end.
        let mediaDuration: MediaDuration? = timing.duration.map { .finite($0) }
        let artwork = Self.makeArtwork(itemId: itemId)

        // Batch 328 (device pass on an iOS 27 phone): the Lock Screen draws two text
        // lines and nothing else — it ignored `BookContent.chapter` even though the
        // daemon received the chapter number and total, and it never showed the narrator.
        // What the classic path gave the user was "Title" / "Author — Chapter title" plus
        // a chapter-relative scrubber; `GenericContent`'s free `subtitle` is the honest
        // way to say the same thing here, and `scrubberTiming` restores the chapter
        // coordinate space (so `seekToPosition` below adds the chapter start back, like
        // `changePlaybackPositionCommand`). A chapterless book keeps `BookContent`, whose
        // typed author/narrator fields are strictly more information for Siri.
        if let chapter {
            return GenericContent(
                id: itemId,
                title: title,
                subtitle: NowPlayingSessionRules.subtitle(author: author, chapterTitle: chapter.title),
                type: .audio,
                duration: mediaDuration,
                artwork: artwork)
        }
        return BookContent(
            id: itemId,
            title: title,
            authorName: author,
            narratorName: item?.narratorName,
            type: .audio,
            duration: mediaDuration,
            artwork: artwork)
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        let service = AudioPlayerService.shared
        // Batch 433: the recap montage's own position/state, at the book's speed.
        if let override = service.transientOverride, service.currentItemId != nil {
            return MediaPlaybackSnapshot(
                state: override.overrideIsPlaying ? .playing(rate: service.playbackRate) : .paused,
                defaultPlaybackRate: service.playbackRate,
                elapsedTime: override.overrideElapsed,
                timestamp: Date())
        }
        let state = NowPlayingSessionRules.playbackState(
            hasItem: service.currentItemId != nil,
            // Polish pass (PB-3): not "playing" while the player waits for data, so the
            // system doesn't extrapolate elapsed time through a stall. Reading `isBuffering`
            // here also makes the snapshot republish when it flips back at `.playing`.
            isPlaying: service.isPlaying && !service.isBuffering,
            rate: service.playbackRate)
        let mapped: MediaPlaybackSnapshot.PlaybackState
        switch state {
        case .stopped:            return nil
        case .playing(let rate):  mapped = .playing(rate: rate)
        case .paused:             mapped = .paused
        }
        // `elapsedTime` + `timestamp` together are what let the system extrapolate
        // position between updates — WWDC26 session 312: "for media with a defined
        // duration, include elapsedTime in the snapshot". `defaultPlaybackRate` carries
        // the speed so that extrapolation is right at 1.75× too, same reason
        // `updateNowPlaying()` sets `MPNowPlayingInfoPropertyDefaultPlaybackRate`.
        // Batch 328: chapter-relative, in step with `content`'s duration (see there).
        let chapter = service.currentChapter
        let timing = NowPlayingSessionRules.scrubberTiming(
            currentTime: service.currentTime, chapterStart: chapter?.start, chapterEnd: chapter?.end,
            bookDuration: service.duration)
        return MediaPlaybackSnapshot(
            state: mapped,
            defaultPlaybackRate: service.playbackRate,
            elapsedTime: timing.elapsed,
            timestamp: Date())
    }

    var commands: [MediaCommand] {
        let skipForward = SettingsStore.skipForwardInterval
        let skipBackward = SettingsStore.skipBackwardInterval
        return [
            // Batch 433: while `transientOverride` (the recap montage) is set, the transport commands
            // reach it instead of the book. Scrubbing and bookmarking are ignored for it.
            .play { await MainActor.run {
                if let override = AudioPlayerService.shared.transientOverride { override.overridePlay() }
                else { AudioPlayerService.shared.play() }
            } },
            .pause { await MainActor.run {
                if let override = AudioPlayerService.shared.transientOverride { override.overridePause() }
                else { AudioPlayerService.shared.pause() }
            } },
            .togglePlayPause { await MainActor.run {
                if let override = AudioPlayerService.shared.transientOverride { override.overrideTogglePlayPause() }
                else { AudioPlayerService.shared.togglePlayPause() }
            } },
            // `preferredIntervals` is what the system labels the button with, so it has
            // to be the user's own configured interval — the classic path does the same
            // thing via `MPRemoteCommandCenter.skipForwardCommand.preferredIntervals`
            // (and re-pushes it from `refreshSkipIntervals()`; here the value is simply
            // re-read every time `commands` is recomputed).
            .skipForward(preferredIntervals: [skipForward]) { _ in
                await MainActor.run {
                    if let override = AudioPlayerService.shared.transientOverride { override.overrideSkip(forward: true) }
                    else { AudioPlayerService.shared.skipForward() }
                }
            },
            .skipBackward(preferredIntervals: [skipBackward]) { _ in
                await MainActor.run {
                    if let override = AudioPlayerService.shared.transientOverride { override.overrideSkip(forward: false) }
                    else { AudioPlayerService.shared.skipBackward() }
                }
            },
            // Batch 328: the scrubber is chapter-relative again (see `content`), so add
            // the chapter start back exactly as `changePlaybackPositionCommand` does.
            .seekToPosition { position in
                await MainActor.run {
                    let service = AudioPlayerService.shared
                    if service.transientOverride != nil { return }   // Batch 433: no scrubbing the recap
                    service.seek(to: NowPlayingSessionRules.absoluteSeekTarget(
                        position, chapterStart: service.currentChapter?.start, bookDuration: service.duration))
                }
            },
            // Parity with the classic `nextTrackCommand`/`previousTrackCommand`
            // targets, which map track skipping to chapter navigation (Batch 328 — the
            // 327 brief wrongly said the classic path had no next/previous).
            .next { await MainActor.run {
                if let override = AudioPlayerService.shared.transientOverride { override.overrideSkip(forward: true) }
                else { AudioPlayerService.shared.skipToNextChapter() }
            } },
            .previous { await MainActor.run {
                if let override = AudioPlayerService.shared.transientOverride { override.overrideSkip(forward: false) }
                else { AudioPlayerService.shared.skipToPreviousChapter() }
            } },
            // Registered with the daemon with all eleven rates (verified in the
            // simulator log). The iOS Lock Screen does not draw a speed control for
            // third-party apps; this serves Siri ("play faster"), CarPlay and
            // headphones, not a Lock Screen button.
            .changePlaybackRate(supported: NowPlayingSessionRules.supportedRates()) { rate in
                await MainActor.run { AudioPlayerService.shared.setPlaybackRate(rate) }
            },
            // The Lock Screen star. Parity with the classic `bookmarkCommand` target for
            // the bookmark itself (same guard, same title, same `BookmarkSyncService`
            // call). Batch 328 made it a real toggle: the daemon registers `.feedback` as
            // a Like *and* a Dislike, so the closure fires with `.positive` (star tapped),
            // `.neutral` (star tapped again) and `.negative` (thumbs-down on surfaces
            // that show one); `feedbackAction` decides, and `status` reports "filled"
            // while a star-made bookmark sits at this position — which is also the only
            // visible confirmation the Lock Screen can give.
            .feedback(title: String(localized: "Bookmark", comment: "Lock Screen star button label; verb-like action to add a bookmark"), shortTitle: String(localized: "Bookmark", comment: "Lock Screen star button short label"), status: starStatus) { [weak self] status in
                await self?.handleStar(status)
            }
        ]
    }

    /// `.positive` while a bookmark made from the star is within
    /// `NowPlayingSessionRules.nearbyTolerance` of the current position, else `.neutral`.
    private var starStatus: MediaCommand.FeedbackStatus {
        nearbyStarBookmark() == nil ? .neutral : .positive
    }

    private func nearbyStarBookmark() -> Double? {
        let service = AudioPlayerService.shared
        guard let itemId = service.currentItemId else { return nil }
        return NowPlayingSessionRules.nearbyBookmark(
            times: starBookmarkTimes[itemId] ?? [], currentTime: service.currentTime)
    }

    /// `BookmarkSyncService` queues the write when the server is unreachable, which
    /// matters more here than anywhere else: the Lock Screen has no way to report an
    /// error back to the user.
    private func handleStar(_ status: MediaCommand.FeedbackStatus) async {
        let service = AudioPlayerService.shared
        guard service.transientOverride == nil,   // Batch 433: nothing to bookmark during the recap
              let itemId = service.currentItemId, service.currentTime > 0 else { return }
        let time = service.currentTime
        let input: NowPlayingSessionRules.FeedbackInput
        switch status {
        case .positive: input = .positive
        case .negative: input = .negative
        case .neutral:  input = .neutral
        @unknown default: input = .neutral
        }
        switch NowPlayingSessionRules.feedbackAction(input, nearbyBookmark: nearbyStarBookmark()) {
        case .createBookmark:
            ShelfLog.info(.playback, "Lock Screen star: bookmark at \(Int(time))s")
            starBookmarkTimes[itemId, default: []].append(time)
            // Batch 490 (REVIEW 2026-11-11 V8): same default title as the player's.
            await BookmarkSyncService.shared.create(
                itemId: itemId, time: time,
                title: BookmarkDefaultTitle.make(chapterTitle: service.currentChapter?.title, time: time))
        case .deleteBookmark(let at):
            ShelfLog.info(.playback, "Lock Screen star: removing bookmark at \(Int(at))s")
            starBookmarkTimes[itemId]?.removeAll { $0 == at }
            await BookmarkSyncService.shared.delete(itemId: itemId, time: at)
        case .ignore:
            break
        }
    }

    /// Cover art, as the async provider the framework calls "whenever it needs an image
    /// at a specific size" (WWDC26 session 312).
    ///
    /// The `id` folds in `CoverVersions.version(for:)` (Batch 315) so a cover replaced
    /// on the server produces a genuinely different `Artwork` identity and the system
    /// re-asks for bytes, instead of serving whatever it cached against the old id.
    ///
    /// The provider closure is `@Sendable`, so it captures **only** `itemId` (a
    /// `String`) — no `self`, no service reference. `shelfCoverURL` is `@MainActor`
    /// (it reads `DownloadManager.shared`), hence the explicit `MainActor.run` hop
    /// rather than an implicit one; bytes then come from
    /// `AudiobookshelfAPI.authorizedData(for:)`, the mandated authenticated-fetch entry
    /// point (CLAUDE.md: a raw `URLSession` call here is the known bug class that once
    /// broke every Watch cover).
    private nonisolated static func makeArtwork(itemId: String) -> Artwork {
        let artworkId: String
        if let version = CoverVersions.version(for: itemId) {
            artworkId = "\(itemId)#\(version)"
        } else {
            artworkId = itemId
        }
        return Artwork(id: artworkId) { size in
            // 300 is `shelfCoverURL`'s own default and the smallest size worth asking
            // the server for; 1200 caps a request the system makes for a very large
            // surface (CarPlay on a wide display) at something a self-hosted server can
            // resize without complaint.
            let width = min(max(Int(size.width), 300), 1200)
            let url: URL? = await MainActor.run { shelfCoverURL(itemId: itemId, width: width) }
            guard let url else {
                throw ArtworkRepresentation.ArtworkRepresentationError.noRepresentationAvailable
            }
            let data = try await AudiobookshelfAPI.shared.authorizedData(for: url)
            return try ArtworkRepresentation(data: data)
        }
    }
}

/// Batch 327: holds the two iOS 27-only objects together.
///
/// Exists only because a stored property can't be individually marked
/// `@available(iOS 27, *)` on a type that's available earlier — `NowPlayingSessionBridge`
/// below has to compile (and be callable) all the way back to iOS 17.6, so it keeps this
/// as an `AnyObject?` and downcasts inside an availability check.
@available(iOS 27, *)
@MainActor
final class NowPlayingSessionHolder {
    let model: NowPlayingSessionModel
    let session: MediaSession<NowPlayingSessionModel>

    init() {
        let model = NowPlayingSessionModel()
        self.model = model
        self.session = MediaSession(model)
    }
}

#endif

// MARK: - The bridge AudioPlayerService gates on

/// Batch 327: the single place the rest of the app asks "which now-playing backend is
/// this launch using?", and the owner of the iOS 27 `MediaSession` when the answer is
/// `.session`.
///
/// Compiles on every supported OS — nothing in this type's *signature* mentions
/// `NowPlaying`. On iOS 17.6–26.x (and on any toolchain without the framework at all)
/// `backend` is `.classic`, `activate()`/`playbackDidStart()` are no-ops, and
/// `AudioPlayerService` behaves exactly as it did before this batch.
@MainActor
final class NowPlayingSessionBridge {
    static let shared = NowPlayingSessionBridge()

    /// Resolved **once per launch**, deliberately.
    ///
    /// A `static let` rather than a computed property so flipping the Settings toggle
    /// can't switch backends underneath a live `MediaSession` — which would mean, for
    /// the remainder of that launch, both a session publishing state *and*
    /// `updateNowPlaying()` writing `MPNowPlayingInfoCenter`, the exact double-registered
    /// state the either/or design exists to prevent. Hence the toggle's footer: "Takes
    /// effect the next time ShelfHead launches."
    ///
    /// `nonisolated` for the same reason `AudioPlayerService.shared` is: a `static let`
    /// on a `@MainActor` type is otherwise a main-actor-isolated lazy initialization the
    /// compiler can't prove runs on the main actor, and this is read from
    /// `AudioPlayerService` — whose own `init()` is `nonisolated`. The initializer below
    /// touches no actor-isolated state: only `#available` and `UserDefaults`.
    nonisolated static let backend: NowPlayingSessionRules.Backend = {
        #if canImport(NowPlaying)
        var sessionAvailable = false
        if #available(iOS 27, *) { sessionAvailable = true }
        #else
        let sessionAvailable = false
        #endif
        return NowPlayingSessionRules.resolveBackend(
            sessionAvailable: sessionAvailable,
            prefersClassic: SettingsStore.classicNowPlaying)
    }()

    /// The `NowPlayingSessionHolder` on iOS 27 when the session backend is live; `nil`
    /// otherwise. Typed `AnyObject?` because a stored property can't carry availability
    /// of its own — see `NowPlayingSessionHolder`'s doc comment.
    private var holder: AnyObject?

    /// Whether this launch actually has a live `MediaSession`. Useful for Diagnostics and
    /// for asserting the either/or invariant while testing on device.
    var isActive: Bool { holder != nil }

    private init() {}

    /// Creates the model and session, once. Safe to call repeatedly; a no-op on any
    /// launch resolved to `.classic`.
    func activate() {
        guard Self.backend == .session, holder == nil else { return }
        #if canImport(NowPlaying)
        if #available(iOS 27, *) {
            holder = NowPlayingSessionHolder()
            ShelfLog.debug(.playback, "NowPlaying MediaSession created")
        }
        #endif
    }

    /// Ask the system to make this app the one the now-playing surfaces show.
    ///
    /// Called once per `startPlayback` rather than on every play/pause: there is no
    /// classic equivalent to this step (`MPNowPlayingInfoCenter` is implicitly whoever
    /// wrote last), and re-requesting on each resume would be asking the system for
    /// something it has already granted. Failures are logged, not surfaced — losing the
    /// request means the lock screen shows whatever else is playing, which is a
    /// degradation, not an error the user can act on.
    func playbackDidStart() {
        guard Self.backend == .session else { return }
        activate()
        #if canImport(NowPlaying)
        if #available(iOS 27, *) {
            guard holder is NowPlayingSessionHolder else { return }
            // The holder is re-read inside the `Task` rather than captured: `MediaSession`
            // is not `Sendable`, and `Task { @MainActor in ... }`'s closure is `@Sendable`
            // even when it opens on the actor it is already running on. Capturing this
            // (`@MainActor`, therefore implicitly `Sendable`) bridge weakly and reaching
            // through it is the same shape `AudioPlayerService` uses for every one of its
            // deferred main-actor hops.
            Task { @MainActor [weak self] in
                guard let holder = self?.holder as? NowPlayingSessionHolder else { return }
                do {
                    try await holder.session.requestToBecomeApplicationPrimary()
                } catch {
                    ShelfLog.error(.playback, "MediaSession could not become application primary: \(error.localizedDescription)")
                    return
                }
                // Deliberately NOT calling `requestToBecomeSystemPrimary()`. Batch 327
                // tried it; it threw `MediaSessionError.internalFailure` on the iOS 27
                // simulator AND on a real iPhone 17 (user's console, Batch 329), while the
                // Lock Screen, Control Center and star all worked without it — the daemon
                // makes the session the now-playing player on application-primary alone.
                // `isSystemPrimary` appears to describe cross-device arbitration, not
                // "is on the Lock Screen"; leaving the call out removes a misleading log
                // line per playback start.
            }
        }
        #endif
    }
}
