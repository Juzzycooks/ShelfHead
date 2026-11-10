import Foundation
import CoreGraphics

// Critique 2026-10-06 (harden, then shape → onboard): the Watch's run journey. The Watch
// is designed as a player for runs, and the second critique found that journey broken at
// both ends: a download resumed from the Watch's own (often stale) position instead of
// where the iPhone left off, you couldn't load a book onto the Watch with the phone in the
// room, a headphone gate read the audio route before activating the session, the
// transport overflowed 40 mm, failures were invisible, and chapter/bookmark taps had no
// Jump back. The decisions behind those fixes live here, pure and Foundation-only, so
// `WatchRunJourneyTests` can pin them without a paired device. Same precedent as
// `WatchNowPlayingDecisions` and `WatchRootTiles`.
//
// Every type is `nonisolated`: this target builds with SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor and the test target doesn't.

// MARK: - Server progress (item 1)

/// The server's idea of a book's position, as the Watch last saw it: from the playback
/// session that resolved a download (stored in the download manifest), from a fresh
/// `GET /api/items/<id>` before playing, or from the iPhone's companion snapshot.
nonisolated struct WatchServerProgress: Codable, Equatable, Sendable {
    /// Seconds into the book.
    var currentTime: Double
    /// Epoch milliseconds of the server's `lastUpdate` (the unit `resumePosition(...)`
    /// compares), or `nil` when the source didn't say.
    var lastUpdateMs: Double?

    /// A usable reading: a finite, non-negative position.
    var isUsable: Bool { currentTime.isFinite && currentTime >= 0 }

    /// The iPhone's snapshot as a server-side reading, when it's about the same book on
    /// the same server. A playing phone is extrapolated to `now` (it's still moving); a
    /// paused one is timestamped when the phone last confirmed it.
    static func fromCompanion(snapshotItemId: String, requestedItemId: String,
                              sameServer: Bool, estimatedTime: Double, isPlaying: Bool,
                              lastConfirmedUpdate: Date, now: Date = Date()) -> WatchServerProgress? {
        guard sameServer, !snapshotItemId.isEmpty, snapshotItemId == requestedItemId,
              estimatedTime.isFinite, estimatedTime > 0 else { return nil }
        let at = isPlaying ? now : lastConfirmedUpdate
        return WatchServerProgress(currentTime: estimatedTime, lastUpdateMs: at.timeIntervalSince1970 * 1000)
    }
}

nonisolated enum WatchServerProgressPicker {
    /// The newest of several server-side readings. A reading with a known clock beats one
    /// without; among known clocks the latest wins; ties (and the all-unknown case) go to
    /// the earliest argument, so callers list the fresher source first (fresh fetch,
    /// then the iPhone's snapshot, then the manifest).
    static func newest(_ candidates: [WatchServerProgress?]) -> WatchServerProgress? {
        let usable = candidates.compactMap { $0 }.filter(\.isUsable)
        var best: WatchServerProgress?
        for candidate in usable {
            guard let current = best else { best = candidate; continue }
            switch (current.lastUpdateMs, candidate.lastUpdateMs) {
            case (nil, .some):
                best = candidate
            case (let a?, let b?) where b > a:
                best = candidate
            default:
                break
            }
        }
        return best
    }
}

/// Which side a resume decision took. Same rules as `StandaloneAudioEngine
/// .resumePosition(...)`, which still owns the position itself (and its clamp); this only
/// says whose it was, so the engine knows when the server's reading became the Watch's
/// baseline (see `WatchProgressBaseline`).
nonisolated enum WatchResumeWinner: Equatable, Sendable {
    case server
    case local
    case none

    static func decide(serverTime: Double?, serverLastUpdateMs: Double?,
                       localTime: Double?, localLastUpdateMs: Double?) -> WatchResumeWinner {
        switch (serverTime, localTime) {
        case (let server?, let local?):
            if let serverMs = serverLastUpdateMs, let localMs = localLastUpdateMs, serverMs != localMs {
                return serverMs > localMs ? .server : .local
            }
            return server >= local ? .server : .local
        case (.some, nil):
            return .server
        case (nil, .some):
            return .local
        default:
            return .none
        }
    }
}

/// The resume point the root hero shows for one download, from the same two sides the
/// engine compares (so "Resume · 4h 12m left" on the hero is where Play will land).
nonisolated enum WatchResumePoint {
    /// Position and the time it was recorded (epoch ms), or `nil` position when neither
    /// side knows anything.
    static func resolve(server: WatchServerProgress?, localTime: Double?, localUpdatedAtMs: Double?,
                        duration: Double) -> (position: Double?, updatedAtMs: Double?) {
        let winner = WatchResumeWinner.decide(
            serverTime: server?.currentTime, serverLastUpdateMs: server?.lastUpdateMs,
            localTime: localTime, localLastUpdateMs: localUpdatedAtMs)
        let position = StandaloneAudioEngine.resumePosition(
            serverTime: server?.currentTime, serverLastUpdateMs: server?.lastUpdateMs,
            localTime: localTime, localLastUpdateMs: localUpdatedAtMs, duration: duration)
        switch winner {
        case .none:
            return (nil, nil)
        case .server:
            return (position, server?.lastUpdateMs ?? localUpdatedAtMs)
        case .local:
            return (position, localUpdatedAtMs ?? server?.lastUpdateMs)
        }
    }
}

/// Whether the server still holds the position the Watch last adopted or pushed. When it
/// does, anything the Watch listened to since is its own forward progress, not a write
/// from the iPhone, so it can be pushed without a "Progress Doesn't Match" prompt.
///
/// Two ways to know: the server's clock hasn't moved past the baseline's (the original
/// heuristic), or the server's position is still within `tolerance` of the baseline's. The
/// second covers a baseline adopted from the iPhone's snapshot, whose timestamp is the
/// phone's clock, not the server's.
nonisolated enum WatchProgressBaseline {
    static let tolerance: Double = 60

    static func serverUnchanged(serverTime: Double?, serverLastUpdateMs: Double,
                                baselinePosition: Double, baselineTimeMs: Double) -> Bool {
        if serverLastUpdateMs <= baselineTimeMs { return true }
        guard let serverTime, serverTime.isFinite else { return false }
        return abs(serverTime - baselinePosition) <= tolerance
    }
}

/// "4h 12m" / "12m" / "1m". Rounds up, so the last partial minute never reads "0m".
nonisolated enum WatchShortDuration {
    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int((seconds / 60).rounded(.up))
        let hours = total / 60
        let minutes = total % 60
        if hours > 0 { return minutes > 0 ? String(localized: "\(hours)h \(minutes)m", comment: "duration: hours and minutes, e.g. 4h 12m") : String(localized: "\(hours)h", comment: "duration: whole hours, e.g. 4h") }
        return String(localized: "\(minutes)m", comment: "duration: minutes only, e.g. 12m")
    }
}

// MARK: - Run setup (item 3)

/// The one-time "Get this Watch ready for runs" prompt on the root screen.
nonisolated enum WatchRunSetupPrompt {
    static let dismissedDefaultsKey = "watchRunSetup.dismissed"
    static let completedDefaultsKey = "watchRunSetup.completed"

    /// Shown only to a Watch that has never been set up: no session (not "checking",
    /// not expired — an expired Watch was set up once, and Account says how to
    /// reconnect), and neither dismissed nor completed before.
    static func shouldShow(hasNoSession: Bool, wasDismissed: Bool, wasCompleted: Bool) -> Bool {
        hasNoSession && !wasDismissed && !wasCompleted
    }
}

/// Copy on Account's iPhone handoff button.
nonisolated enum WatchAccountCopy {
    /// "Set Up via iPhone" on a Watch that has no session at all (never connected, or
    /// signed out from the phone); "Reconnect via iPhone" when there was one.
    static func handoffTitle(hasNoSession: Bool) -> String {
        // Critique 2026-10-06 (polish): title case, like "Reconnect via iPhone" and the
        // home prompt's "Set Up" button that leads here.
        hasNoSession ? String(localized: "Set Up via iPhone") : String(localized: "Reconnect via iPhone")
    }
}

// MARK: - Audio route (item 4)

/// What `StandaloneAudioEngine` does once the audio session has been activated.
///
/// Apple's `activate(options:completionHandler:)` page (checked 6 Oct 2026 via the JSON
/// endpoint): with `.playback` and the long-form policy, "the system selects a reachable
/// route automatically when one is available"; if not, it routes to the Watch's built-in
/// speaker where supported, or "presents the route picker", and "if the user dismisses
/// the picker without selecting a valid route, the system calls the completion handler
/// with false". So the route is only meaningful *after* activation.
nonisolated enum StandaloneRouteDecision: Equatable, Sendable {
    /// Headphones (or the speaker, already accepted for this book): play.
    case play
    /// The system settled on the Watch's own speaker. Say so before any sound comes out
    /// of a wrist in public.
    case askAboutSpeaker
    /// Activation came back `false`: the route picker was dismissed with nothing chosen.
    case noRoute

    static func afterActivation(activated: Bool, hasExternalOutput: Bool, speakerAccepted: Bool) -> StandaloneRouteDecision {
        guard activated else { return .noRoute }
        if hasExternalOutput || speakerAccepted { return .play }
        return .askAboutSpeaker
    }
}

/// What Now Playing says about the audio route. Plain and short: what happened, then
/// what the button does.
nonisolated enum StandaloneRouteIssue: Equatable, Sendable {
    /// The system chose the Watch speaker; nothing has played yet.
    case speakerOnly
    /// The route picker was dismissed with nothing chosen.
    case noOutputChosen
    /// Headphones went away mid-book, so playback paused.
    case headphonesDisconnected

    var message: String {
        switch self {
        case .speakerOnly: return String(localized: "No headphones connected. This would play from the Watch speaker.")
        case .noOutputChosen: return String(localized: "No headphones were chosen, so nothing is playing.")
        case .headphonesDisconnected: return String(localized: "Your headphones disconnected, so playback paused.")
        }
    }

    /// The notice's button, or `nil` when Play on the transport is the next step.
    var actionTitle: String? {
        switch self {
        case .speakerOnly: return String(localized: "Play on Speaker")
        case .noOutputChosen: return String(localized: "Try Again")
        case .headphonesDisconnected: return nil
        }
    }
}

// MARK: - Transport sizing (item 5)

/// The transport row sized from the screen width. 44 + 54 + 44 + 2 × 12 = 166 pt, but a
/// 40 mm screen is 162 pt wide before the content padding. Skip buttons keep the 44 pt
/// minimum target; the gaps shrink first, then Play, never below 44.
nonisolated struct WatchTransportLayout: Equatable, Sendable {
    var skip: CGFloat
    var play: CGFloat
    var spacing: CGFloat

    static let skipSize: CGFloat = 44
    static let preferredPlay: CGFloat = 54
    static let minimumPlay: CGFloat = 44
    static let preferredSpacing: CGFloat = 12
    static let minimumSpacing: CGFloat = 4
    /// Horizontal space the row can't use: `WatchMetrics.scrollContentHorizontalPadding`
    /// on both sides plus a small allowance for the system's own margins.
    static let reservedWidth: CGFloat = 2 * 4 + 8

    var totalWidth: CGFloat { 2 * skip + play + 2 * spacing }

    static func forScreenWidth(_ screenWidth: CGFloat) -> WatchTransportLayout {
        let available = max(0, screenWidth - reservedWidth)
        let fixed = 2 * skipSize
        let gapAtPreferredPlay = (available - fixed - preferredPlay) / 2
        if gapAtPreferredPlay >= minimumSpacing {
            return WatchTransportLayout(skip: skipSize, play: preferredPlay,
                                        spacing: min(preferredSpacing, gapAtPreferredPlay.rounded(.down)))
        }
        let play = max(minimumPlay, (available - fixed - 2 * minimumSpacing).rounded(.down))
        return WatchTransportLayout(skip: skipSize, play: min(play, preferredPlay), spacing: minimumSpacing)
    }
}

/// At accessibility text sizes the header sheds its cover and the title's second line
/// before Play is pushed below the fold.
nonisolated struct WatchNowPlayingHeaderLayout: Equatable, Sendable {
    var showsCover: Bool
    var titleLineLimit: Int

    static func forAccessibilitySize(_ isAccessibilitySize: Bool) -> WatchNowPlayingHeaderLayout {
        isAccessibilitySize
            ? WatchNowPlayingHeaderLayout(showsCover: false, titleLineLimit: 1)
            : WatchNowPlayingHeaderLayout(showsCover: true, titleLineLimit: 2)
    }

    /// Batch 410: the header cover's side. Was a fixed 36 pt under a scrolling screen.
    /// Now Playing fits one viewport, so the cover takes what the screen height leaves
    /// after the top bar, time row, transport and tool row (`reservedHeight`), between
    /// 40 pt and `maximumCoverSide`, and never past 45% of the width (the brief's
    /// figure). The big cover is the Shelf's job (Batch 411); here it identifies the book.
    static let minimumCoverSide: CGFloat = 40
    static let maximumCoverSide: CGFloat = 56
    static let reservedHeight: CGFloat = 192

    static func coverSide(screenWidth: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let byHeight = (screenHeight - reservedHeight).rounded(.down)
        let byWidth = (screenWidth * 0.45).rounded(.down)
        return max(minimumCoverSide, min(maximumCoverSide, byWidth, byHeight))
    }
}

// MARK: - Bookmark outcome (item 6)

/// What the tool row's Bookmark button says after a tap, from the real result: the
/// iPhone's reply in companion mode, the server (or the offline queue) in standalone.
nonisolated enum WatchBookmarkOutcome: Equatable, Sendable {
    case saving
    case saved
    /// Standalone, offline: kept on the Watch and sent when the server is reachable.
    case savedOffline
    case failed

    var title: String {
        switch self {
        case .saving: return String(localized: "Saving…", comment: "bookmark save status")
        case .saved: return String(localized: "Saved", comment: "bookmark save status")
        case .savedOffline: return String(localized: "Will Sync", comment: "bookmark saved offline, will sync later")
        case .failed: return String(localized: "Not Saved", comment: "bookmark save status")
        }
    }

    var systemImage: String {
        switch self {
        case .saving: return "bookmark"
        case .saved, .savedOffline: return "bookmark.fill"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .saving: return String(localized: "Saving bookmark")
        case .saved: return String(localized: "Bookmark saved")
        case .savedOffline: return String(localized: "Bookmark saved on this Watch, it will sync later")
        case .failed: return String(localized: "Bookmark not saved, tap to try again")
        }
    }

    /// How long the label stays before going back to "Bookmark". A failure stays longer
    /// so it can be read.
    var displaySeconds: Double {
        switch self {
        case .saving: return 10
        case .saved, .savedOffline: return 2
        case .failed: return 4
        }
    }
}

// MARK: - Jump back (item 7)

/// A chapter or bookmark tap moves the listener a long way at once. After one, Now
/// Playing offers "Jump back" for a few seconds, the Watch half of the phone's undo for
/// large seeks.
nonisolated struct WatchJumpBack: Equatable, Sendable {
    let itemId: String
    /// Where the listener was before the jump, and where the chip takes them.
    let restoreTime: Double
    let jumpedTo: Double

    static let visibleSeconds: Double = 8
    /// A jump shorter than this isn't worth an undo.
    static let minimumDistance: Double = 2

    static func make(itemId: String?, from: Double, to: Double) -> WatchJumpBack? {
        guard let itemId, !itemId.isEmpty, from.isFinite, to.isFinite, from >= 0,
              abs(to - from) >= minimumDistance else { return nil }
        return WatchJumpBack(itemId: itemId, restoreTime: from, jumpedTo: to)
    }

    /// Only for the same book: a different book loaded since would make "back" a seek
    /// into the wrong book.
    func canApply(currentItemId: String?) -> Bool { currentItemId == itemId }

    var label: String { String(localized: "Jump back to \(restoreTime.watchFormattedTime)", comment: "%@ is a time like 1:02:03") }
}

// MARK: - Chapters empty state (item 8)

nonisolated enum WatchChaptersEmptyState {
    /// Companion mode's empty Chapters page: nothing playing, not synced yet, or a book
    /// that really has no chapters. Only the middle one is fixed by opening the iPhone.
    static func message(hasActiveItem: Bool, isStale: Bool) -> String {
        if !hasActiveItem { return String(localized: "Nothing playing on iPhone") }
        if isStale { return String(localized: "Open ShelfHead on iPhone to sync chapters") }
        return String(localized: "This book has no chapters")
    }
}

// MARK: - Book detail (item 2)

/// The one-line progress summary on `WatchBookDetailView`.
nonisolated enum WatchBookProgressText {
    static func text(currentTime: Double?, duration: Double?, progress: Double?, isFinished: Bool) -> String {
        if isFinished || (progress ?? 0) >= 0.99 { return String(localized: "Finished", comment: "book progress summary") }
        let fraction = min(max(progress ?? 0, 0), 1)
        if let duration, duration > 0 {
            let position = currentTime ?? fraction * duration
            if position <= 0 { return String(localized: "Not started", comment: "book progress summary") }
            return String(localized: "\(WatchShortDuration.text(max(0, duration - position))) left", comment: "%@ is a short duration like 4h 12m")
        }
        guard fraction > 0 else { return String(localized: "Not started", comment: "book progress summary") }
        return String(localized: "\(Int((fraction * 100).rounded()))% listened", comment: "%lld is a percentage")
    }
}

/// What the detail screen's play button does in each mode. Companion mode plays on the
/// iPhone (the companion stack owns Now Playing and the remote commands there —
/// `WatchRemoteCommandRouter`); standalone plays on this Watch.
nonisolated enum WatchBookPlayTarget: Equatable, Sendable {
    case iPhone
    case watch

    static func forStandaloneMode(_ isStandalone: Bool) -> WatchBookPlayTarget {
        isStandalone ? .watch : .iPhone
    }

    var buttonTitle: String {
        switch self {
        case .iPhone: return String(localized: "Play on iPhone")
        case .watch: return String(localized: "Play on Watch")
        }
    }

    var systemImage: String {
        switch self {
        case .iPhone: return "iphone"
        case .watch: return "applewatch"
        }
    }
}

// MARK: - Third critique (6 Oct 2026): play target, eviction, palette

// Critique 2026-10-06 (shape → harden): the third critique's P1. With the iPhone nearby
// the Watch wouldn't play its own download (Automatic mode is companion whenever the phone
// is reachable, and companion's detail screen only offered "Play on iPhone"), and storage
// eviction could delete a half-finished book with no word. The user's decision: the Watch is
// a player for runs first, so a downloaded book's primary action is "Play on Watch" in both
// modes, with "Play on iPhone" second, and the Watch holds its own mode while that book is
// loaded. The decisions live here, pure, for `WatchThirdCritiqueTests`.

/// The detail screen's play buttons: one primary, at most one secondary.
nonisolated struct WatchBookPlayOptions: Equatable, Sendable {
    let primary: WatchBookPlayTarget
    let secondary: WatchBookPlayTarget?

    /// - A book on this Watch plays here first, whatever the mode. The iPhone is the second
    ///   choice when it's reachable to take the command.
    /// - A book that isn't downloaded plays where the mode says: on the iPhone in companion
    ///   (the Watch would have to stream it), on the Watch in standalone. In standalone the
    ///   iPhone is still offered when it happens to be reachable (a "This Watch" override).
    static func decide(isDownloaded: Bool, isStandaloneMode: Bool, phoneIsReachable: Bool) -> WatchBookPlayOptions {
        if isDownloaded || isStandaloneMode {
            return WatchBookPlayOptions(primary: .watch, secondary: phoneIsReachable ? .iPhone : nil)
        }
        return WatchBookPlayOptions(primary: .iPhone, secondary: nil)
    }
}

/// What starting a book on this Watch does to the iPhone. The Watch and the iPhone
/// shouldn't both be talking into the same headphones, so a playing iPhone is paused
/// (pausing keeps its place; nothing is lost). A *different* book playing on the iPhone
/// gets the same "this replaces what's playing" question the companion Play path asks
/// (`WatchPlayRequestDecision`), worded for a pause.
nonisolated enum WatchPlayOnWatchPhoneAction: Equatable, Sendable {
    /// The iPhone isn't reachable, has nothing playing, or its snapshot is too old to act on.
    case nothing
    /// The iPhone is playing this same book: pause it and carry on here (a hand-off).
    case pausePhone
    /// The iPhone is playing a different book: ask, then pause it.
    case confirmPausingPhone(currentTitle: String)

    static func decide(requestedItemId: String, phoneIsReachable: Bool, phoneIsPlaying: Bool,
                       phoneItemId: String?, phoneTitle: String, phoneStateIsStale: Bool) -> WatchPlayOnWatchPhoneAction {
        guard phoneIsReachable, phoneIsPlaying, !phoneStateIsStale else { return .nothing }
        guard let phoneItemId, !phoneItemId.isEmpty, phoneItemId != requestedItemId else { return .pausePhone }
        return .confirmPausingPhone(currentTitle: phoneTitle)
    }
}

/// Where a downloaded book stands for eviction. Built from whatever the Watch knows: its
/// own last position (`WatchPendingProgressQueue`) and the server's (the manifest, or the
/// iPhone's snapshot), resolved by `WatchResumePoint`.
nonisolated enum WatchDownloadListening: Equatable, Sendable {
    case finished
    case unstarted
    /// Progress > 0 and not finished. Never evicted.
    case inProgress

    /// Finished within `WatchResumeCandidate.finishedTailSeconds` of the end (the hero's
    /// rule, so the two never disagree). No known position counts as unstarted.
    static func classify(position: Double?, duration: Double) -> WatchDownloadListening {
        guard let position, position.isFinite, position > 0 else { return .unstarted }
        if duration > 0, duration - position <= WatchResumeCandidate.finishedTailSeconds { return .finished }
        return .inProgress
    }

    /// From both sides, newest wins (`WatchResumeWinner`, the engine's rule). Not via
    /// `WatchResumePoint`: its position goes through `resumePosition(...)`, which turns a
    /// position at or past the end into 0 (a finished book restarts), and that would make
    /// a finished book look unstarted here.
    static func classify(server: WatchServerProgress?, localTime: Double?, localUpdatedAtMs: Double?,
                         duration: Double) -> WatchDownloadListening {
        let winner = WatchResumeWinner.decide(
            serverTime: server?.currentTime, serverLastUpdateMs: server?.lastUpdateMs,
            localTime: localTime, localLastUpdateMs: localUpdatedAtMs)
        switch winner {
        case .server: return classify(position: server?.currentTime, duration: duration)
        case .local: return classify(position: localTime, duration: duration)
        case .none: return .unstarted
        }
    }

    /// Eviction order: finished first, then unstarted. `nil` = never.
    var evictionRank: Int? {
        switch self {
        case .finished: return 0
        case .unstarted: return 1
        case .inProgress: return nil
        }
    }
}

/// Whether a new download fits under the storage cap, and what it would cost.
nonisolated enum WatchDownloadRoomPlan: Equatable, Sendable {
    /// Fits as things are.
    case fits
    /// Fits once these downloads (finished, then unstarted, oldest first) are removed.
    case fitsAfterRemoving([String])
    /// Can't fit without removing a book that's part-way through. Nothing is removed.
    case noRoom

    static func plan(newBytes: Int64, downloads: [WatchLocalDownload], capBytes: Int64,
                     protectedItemIds: Set<String>, listening: [String: WatchDownloadListening]) -> WatchDownloadRoomPlan {
        let used = downloads.reduce(Int64(0)) { $0 + $1.totalBytes }
        let total = used + max(0, newBytes)
        guard total > capBytes else { return .fits }
        let victims = WatchLocalDownloadManager.evictionVictims(
            downloads: downloads, totalBytesUsed: total, capBytes: capBytes,
            protectedItemIds: protectedItemIds, listening: listening)
        let freed = downloads.filter { victims.contains($0.id) }.reduce(Int64(0)) { $0 + $1.totalBytes }
        return total - freed <= capBytes ? .fitsAfterRemoving(victims) : .noRoom
    }
}

/// The storage cap: the smaller of a fixed ceiling and half of what's free. Pure so the
/// before-download check and the after-download eviction use the same number.
nonisolated enum WatchDownloadCap {
    static let fixedCeilingBytes: Int64 = 500 * 1024 * 1024

    /// `pendingBytes` is a download not yet on disk: free space will shrink by that much,
    /// so the cap it will be measured against is computed from what's left after it.
    static func capBytes(availableBytes: Int64?, pendingBytes: Int64 = 0) -> Int64 {
        guard let availableBytes else { return fixedCeilingBytes }
        return min(fixedCeilingBytes, max(0, availableBytes - max(0, pendingBytes)) / 2)
    }
}

/// The copy that goes with eviction: before (detail screen), refused, and after.
nonisolated enum WatchDownloadRoomCopy {
    static func noRoom(title: String) -> String {
        String(localized: "Not enough room on this Watch. Remove a book to download \u{201C}\(title)\u{201D}.", comment: "%@ is a book title")
    }

    /// "Removes “A” to make room." / "Removes 3 finished or unstarted books to make room."
    static func willRemove(titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return String(localized: "Removes \u{201C}\(titles[0])\u{201D} to make room.", comment: "%@ is a book title")
        case 2: return String(localized: "Removes \u{201C}\(titles[0])\u{201D} and \u{201C}\(titles[1])\u{201D} to make room.", comment: "%1$@ and %2$@ are book titles")
        default: return String(localized: "Removes \(titles.count) finished or unstarted books to make room.", comment: "%lld is a book count")
        }
    }

    static func removed(titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return String(localized: "Removed \u{201C}\(titles[0])\u{201D} to make room.", comment: "%@ is a book title")
        case 2: return String(localized: "Removed \u{201C}\(titles[0])\u{201D} and \u{201C}\(titles[1])\u{201D} to make room.", comment: "%1$@ and %2$@ are book titles")
        default: return String(localized: "Removed \(titles.count) finished or unstarted books to make room.", comment: "%lld is a book count")
        }
    }

    /// "320 MB · 180 MB free for downloads".
    static func sizeLine(bookBytes: Int64, roomBytes: Int64) -> String {
        let book = ByteCountFormatter.string(fromByteCount: max(0, bookBytes), countStyle: .file)
        let room = ByteCountFormatter.string(fromByteCount: max(0, roomBytes), countStyle: .file)
        return String(localized: "\(book) \u{00B7} \(room) free for downloads", comment: "%1$@ is a book size, %2$@ is free room, e.g. 320 MB · 180 MB free for downloads")
    }
}

/// Which of `/api/me/items-in-progress`'s books Library's "In Progress" section shows:
/// books (podcasts aren't downloadable here) in the library on screen, not finished. An
/// item with no library id is kept rather than hidden.
nonisolated enum WatchLibraryInProgressFilter {
    static func keeps(itemLibraryId: String?, isPodcast: Bool, isFinished: Bool, selectedLibraryId: String) -> Bool {
        guard !isPodcast, !isFinished else { return false }
        guard let itemLibraryId, !itemLibraryId.isEmpty else { return true }
        return itemLibraryId == selectedLibraryId
    }
}
