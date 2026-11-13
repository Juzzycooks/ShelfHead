import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Watch <-> iPhone shared DTOs
//
// Everything in this file is compiled into BOTH the `ShelfHead` (iPhone) target and the
// `ShelfHead Watch App` (watchOS) target — add it to both targets' membership in Xcode.
// It intentionally has zero dependency on AVFoundation/UIKit/the rest of the app so it
// stays trivially Sendable/Codable and portable to watchOS.
//
// SYNC BOUNDARY: these structs are the *entire* contract crossing WatchConnectivity.
// Keep them small (cover art is a downscaled JPEG capped at a few KB — see
// `WatchCoverArt.maxDimension`) and keep every payload scoped to a `WatchAccountScope`
// so a stale or cross-account message can never be silently applied.

// MARK: - Account scope

/// Identifies which server + which logged-in account a piece of Watch state or a Watch
/// command belongs to. ShelfHead is multi-account/multi-server, so nothing crosses
/// WatchConnectivity without this attached — the phone-side bridge (`WatchSessionManager`)
/// rejects any inbound command whose scope doesn't match the currently active account,
/// and the Watch-side store (`WatchConnectivityStore`) treats a scope change from the
/// phone as a reason to drop any cached book-specific state (chapters/bookmarks) rather
/// than risk showing stale data under the wrong account.
///
/// Deliberately does NOT carry a token, password, or any credential — the Watch never
/// authenticates directly to the Audiobookshelf server in this version; it only ever
/// asks the iPhone to act on its behalf.
///
/// **Superseded by Stage 2 (28 August 2026), WATCH_STANDALONE_PROPOSAL_2026-08-28-
/// ADDENDUM.md §2.1/§3/§7.3**: this decision is revisited, not silently overridden —
/// flagging it here per this project's own ground rule for touching a prior logged
/// decision (matching `DESIGN_DIRECTION.md`'s own addenda convention). The Watch now
/// *can* hold its own access + refresh token pair, received via a `sendMessage`
/// credential handoff from a reachable, already-signed-in iPhone (never the plaintext
/// password — that part of the original sentence above still holds) or entered
/// directly on-device as a manual-entry fallback. `WatchAccountScope` itself is
/// unchanged by this — it still carries no credential and still exists to scope
/// book/library *state*, a separate concern from the session that now lives
/// alongside it in `AuthStore`/`KeychainService` (shared into the Watch target as of
/// Stage 1). The addendum's §3 threat model is what makes this reversal defensible
/// rather than just a rollback of a security decision with no compensating control:
/// a real session-revocation path (`WatchAudiobookshelfAPI.getAuthSessions()`/
/// `revokeAuthSession(id:)`, `GET`/`DELETE /api/me/sessions`) ships in this same
/// stage, and the phone actively signals this Watch to wipe its credential on
/// sign-out or account switch (`WatchSessionManager.clearWatchState()` ->
/// `WatchConnectivityStore.apply(context:)`'s `"wipeCredentials"` branch ->
/// `WatchStore.wipeCredentials()`) rather than leaving a stale session to sit
/// unrevocable on a device the phone can no longer reach.
struct WatchAccountScope: Codable, Equatable, Hashable, Sendable {
    /// Server base URL (e.g. "https://abs.example.com"). No credentials embedded.
    var serverURL: String
    /// `AccountStore`'s persisted account id (`ServerAccount.id`), not a username —
    /// stable across password changes/reauth.
    var accountId: String

    func matches(_ other: WatchAccountScope) -> Bool {
        serverURL == other.serverURL && accountId == other.accountId
    }
}

// MARK: - Small cover art helper

/// Shared conventions for how cover thumbnails are sized before crossing
/// WatchConnectivity. Keeping this in one place means the iPhone encoder and the Watch
/// decoder agree on what "small" means without duplicating magic numbers.
enum WatchCoverArt {
    /// Longest edge, in points, for the Now Playing cover (rendered at ~44pt on the
    /// Watch, see `CoverThumbnail`'s default `side`) — 88 = 44pt @2x.
    static let maxDimension: CGFloat = 88
    /// WATCH-3 (REVIEW_2026-08-12.md): list rows (Downloads/Recently Added) render their
    /// cover at ~32pt (`WatchDownloadsView.downloadRow`'s `CoverThumbnail(..., side: 32)`),
    /// but every row used to be fetched/encoded at the same 88pt `maxDimension` as the big
    /// Now Playing cover — 7x more pixels than a 32pt thumbnail can even show, multiplied
    /// across up to 20 downloads + 20 recently-added rows. That's a large share of why the
    /// merged WCSession payload could approach the ~256KB `updateApplicationContext`
    /// ceiling. Row covers are now fetched/encoded at this smaller size instead (64 = 32pt
    /// @2x — enough for a Retina row, no more).
    static let listRowMaxDimension: CGFloat = 64
    static let jpegQuality: CGFloat = 0.6
}

// MARK: - Book / chapter / bookmark / download summaries

/// A lightweight description of a book, enough to render a row on the Watch.
struct WatchBookSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String            // libraryItemId
    var title: String
    var author: String
    var durationSeconds: Double
    /// 0...1, nil if unknown/never started.
    var progress: Double?
    /// Small JPEG (see `WatchCoverArt`), nil if not fetched/available.
    var coverData: Data?
}

struct WatchChapterSummary: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var title: String
    var start: Double
    var end: Double
}

struct WatchBookmarkSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var time: Double
}

/// Download status as known to the iPhone. The Watch never manages downloads itself in
/// this version — it only mirrors what `DownloadManager` on the phone reports.
///
/// **Superseding note (Stage 5, 28 August 2026, standalone Watch app):** this is no
/// longer true for a Watch running in standalone mode (`WatchStore.Mode.standalone`)
/// — that Watch now has its own real download manager
/// (`WatchLocalDownloadManager`, `ShelfHead Watch App Watch App/
/// WatchLocalDownloadManager.swift`), with its own state enum
/// (`WatchLocalDownloadState`) and manifest model (`WatchLocalDownload`), deliberately
/// kept separate from this pair rather than repurposing them: `WatchDownloadStatus`/
/// `WatchDownloadSummary` are `Codable` for a reason — they cross the WatchConnectivity
/// wire as part of `WatchSnapshot` (`WatchSessionManager`'s companion-mode payload) —
/// and `Codable` conformance requiring `coverData: Data?` to be sent inline is exactly
/// the shape a local-files-on-this-Watch model shouldn't copy (`WatchLocalDownload`
/// records a cover *path*, not embedded bytes). This type's own statement above — "the
/// Watch never manages downloads itself" — is therefore only accurate for companion
/// mode now, not universally.
enum WatchDownloadStatus: Codable, Equatable, Sendable {
    case queued
    case downloading(progress: Double)
    case downloaded
    case failed
}

struct WatchDownloadSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String            // libraryItemId
    var title: String
    var author: String
    var status: WatchDownloadStatus
    var coverData: Data?
}

/// A collection ("Collections" row on the Library Overview screen). Book lists are
/// capped small (see `WatchSessionManager.collectionBookCap`) to keep the
/// WatchConnectivity payload cheap — this is still a companion controller, not a full
/// library browser, so a long collection just shows its first N titles rather than
/// paginating.
struct WatchCollectionSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var books: [WatchBookSummary]
    var bookCount: Int
}

// MARK: - Playback state (phone -> watch)

/// A snapshot of the iPhone's active playback, pushed to the Watch. This is the ONLY
/// source of truth for "what's playing" on the Watch side — the Watch never mutates its
/// own copy except to locally *estimate* elapsed time between snapshots (see
/// `WatchProgressEstimator`), and always defers to the next real snapshot from the phone.
struct WatchPlaybackState: Codable, Equatable, Sendable {
    var scope: WatchAccountScope
    var itemId: String
    /// Server-side (or offline-) playback session id, if one is active. Included so a
    /// command that depends on an active session (e.g. `markFinished`) can be validated
    /// against it, not just the item id.
    var sessionId: String?
    var title: String
    var author: String
    var chapterTitle: String?
    var duration: Double
    /// The book-time position as of `lastUpdated` — NOT extrapolated. Extrapolation is
    /// the Watch's job (`WatchProgressEstimator`), so this struct stays a pure fact.
    var currentTime: Double
    var playbackRate: Double
    var isPlaying: Bool
    /// Wall-clock time this snapshot was produced on the phone — also used by
    /// `WatchProgressEstimator` as the reference point to extrapolate position from, so
    /// the Watch's own optimistic-apply code (`WatchConnectivityStore.togglePlayPause()`)
    /// deliberately rebases this to "now" on an unconfirmed local toggle too.
    var lastUpdated: Date
    /// P3-9 (third-pass review, 14 Aug 2026): staleness needs a SEPARATE timestamp from
    /// `lastUpdated` above. `togglePlayPause()`'s optimistic apply sets `lastUpdated =
    /// Date()` so the position estimator doesn't jump when play/pause flips — correct
    /// for that purpose, but `isStateStale` used to read `lastUpdated` too, so an
    /// unconfirmed optimistic toggle made a genuinely stale snapshot (phone unreachable
    /// for minutes) report as fresh the instant the user tapped Play, before the phone
    /// ever confirmed anything. If the command then failed, `rollback` only restores
    /// `isPlaying` (deliberately, to avoid moving the displayed position again) — so the
    /// UI was left permanently "fresh" until the next real snapshot, letting the user
    /// fire further position-dependent commands against stale state the phone would
    /// then reject. Only ever written by a REAL snapshot from the phone
    /// (`WatchSessionManager.buildPlaybackState()`) — the Watch's own optimistic code
    /// never touches it, so it stays an honest record of when the phone last actually
    /// confirmed something, independent of any local UI rebasing.
    var lastConfirmedUpdate: Date
    /// Small JPEG cover thumbnail, nil if unavailable.
    var coverData: Data?
    /// WATCH-5 (REVIEW_2026-08-12.md): the phone's REAL configured skip amounts
    /// (`SettingsStore.skipForwardInterval`/`skipBackwardInterval`) — previously not
    /// carried at all, so `WatchSettingsView` showed a hardcoded "15 Seconds" literal
    /// and `WatchConnectivityStore.rewind()`/`forward()` always sent a hardcoded 15s
    /// regardless of what the user had actually configured on the phone. Defaulted to
    /// the phone's own defaults (15/30) so an `idle` snapshot still shows something
    /// sane before the first real push arrives.
    var skipBackwardInterval: Double = 15
    var skipForwardInterval: Double = 30
    /// WATCH-5: mirrors the phone's actual sleep timer so the Watch's Sleep Timer page
    /// stops being a local fiction that forgets itself the moment the phone changes it
    /// from Settings, Siri, or the timer simply expiring — see `SleepTimerView`.
    var sleepTimerOption: WatchSleepTimerOption = .off
    var sleepTimerRemaining: Double = 0
    /// U7 (REVIEW_2026-08-20_UI_SECURITY.md): the phone's user-selected accent
    /// (`AppTheme.accentHex`), mirrored the same way `skipBackwardInterval`/
    /// `skipForwardInterval` already are above — so `WatchTheme.accent` can follow the
    /// user's actual pick instead of a hardcoded orange regardless of it. Defaults to
    /// `AppTheme.defaultAccentHex`'s value so an `idle` snapshot still shows the classic
    /// amber before the first real push arrives. No credential/identity concern here
    /// (unlike `WatchAccountScope`, deliberately kept minimal above) — this is cosmetic,
    /// so it lives on the frequently-refreshed playback snapshot rather than the scope.
    var accentHex: String = "E8A838"
    /// LS-1 (docs/design-review.md, Round 2): mirrors `AudioPlayerService.isBuffering`
    /// on the phone — true while playback is intended but AVPlayer is still waiting
    /// for data (`timeControlStatus == .waitingToPlayAtSpecifiedRate`), false once
    /// data starts flowing again (or nothing was ever buffering). Added after this
    /// struct first shipped, the same build-skew concern `accentHex`/the skip
    /// intervals above already handle — defaults to `false` in the memberwise init
    /// and decodes with `decodeIfPresent` (see `NEW-13`'s doc comment above) so a
    /// payload from an older phone build that doesn't send this key yet just shows
    /// no buffering ring instead of failing the whole decode.
    var isBuffering: Bool = false

    init(
        scope: WatchAccountScope, itemId: String, sessionId: String?, title: String,
        author: String, chapterTitle: String?, duration: Double, currentTime: Double,
        playbackRate: Double, isPlaying: Bool, lastUpdated: Date,
        lastConfirmedUpdate: Date? = nil, coverData: Data?,
        skipBackwardInterval: Double = 15, skipForwardInterval: Double = 30,
        sleepTimerOption: WatchSleepTimerOption = .off, sleepTimerRemaining: Double = 0,
        accentHex: String = "E8A838", isBuffering: Bool = false
    ) {
        self.scope = scope
        self.itemId = itemId
        self.sessionId = sessionId
        self.title = title
        self.author = author
        self.chapterTitle = chapterTitle
        self.duration = duration
        self.currentTime = currentTime
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.lastUpdated = lastUpdated
        // Every real construction site is on the phone, building a genuine snapshot —
        // defaulting to `lastUpdated` here (rather than requiring every call site to
        // pass it explicitly) keeps this a one-line addition at each of those sites.
        self.lastConfirmedUpdate = lastConfirmedUpdate ?? lastUpdated
        self.coverData = coverData
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.sleepTimerOption = sleepTimerOption
        self.sleepTimerRemaining = sleepTimerRemaining
        self.accentHex = accentHex
        self.isBuffering = isBuffering
    }

    private enum CodingKeys: String, CodingKey {
        case scope, itemId, sessionId, title, author, chapterTitle, duration,
             currentTime, playbackRate, isPlaying, lastUpdated, lastConfirmedUpdate, coverData,
             skipBackwardInterval, skipForwardInterval, sleepTimerOption, sleepTimerRemaining,
             accentHex, isBuffering
    }

    /// NEW-13 (follow-up review, 14 Aug 2026): hand-written rather than relying on
    /// synthesized `Decodable` — a stored property's own `= default` value is a
    /// Swift-code convenience for the MEMBERWISE initializer only; it has no effect
    /// on synthesized decoding, which still calls plain `decode` for every
    /// non-Optional key and throws `keyNotFound` if that key is missing. The four
    /// fields below were all added after this struct first shipped — in lockstep
    /// (phone and Watch built from the same source at the same time) that's
    /// invisible, but any build skew between the two sides (a staged App Store
    /// rollout where one side updates before the other) meant a payload from the
    /// newer side was missing these keys from the older side's perspective. The
    /// call site (`WatchConnectivityStore.apply(context:)`) uses `try?
    /// JSONDecoder().decode(...)`, so that decode failure silently dropped the
    /// ENTIRE `playbackState` update, not just these four fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(WatchAccountScope.self, forKey: .scope)
        itemId = try container.decode(String.self, forKey: .itemId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
        duration = try container.decode(Double.self, forKey: .duration)
        currentTime = try container.decode(Double.self, forKey: .currentTime)
        playbackRate = try container.decode(Double.self, forKey: .playbackRate)
        isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        // P3-9: added after this struct first shipped, same NEW-13 concern as the four
        // fields below — a payload from a build that doesn't send this key yet (staged
        // rollout skew) shouldn't fail this decode. Falls back to `lastUpdated` itself,
        // which is only very slightly more permissive than a dedicated "always fresh"
        // default — never less accurate than what the pre-fix code effectively assumed.
        lastConfirmedUpdate = try container.decodeIfPresent(Date.self, forKey: .lastConfirmedUpdate) ?? lastUpdated
        coverData = try container.decodeIfPresent(Data.self, forKey: .coverData)
        skipBackwardInterval = try container.decodeIfPresent(Double.self, forKey: .skipBackwardInterval) ?? 15
        skipForwardInterval = try container.decodeIfPresent(Double.self, forKey: .skipForwardInterval) ?? 30
        sleepTimerOption = try container.decodeIfPresent(WatchSleepTimerOption.self, forKey: .sleepTimerOption) ?? .off
        sleepTimerRemaining = try container.decodeIfPresent(Double.self, forKey: .sleepTimerRemaining) ?? 0
        // U7: same build-skew tolerance as the other optional fields above — a payload
        // from a build that doesn't send this key yet falls back to the classic amber.
        accentHex = try container.decodeIfPresent(String.self, forKey: .accentHex) ?? "E8A838"
        // LS-1: same build-skew tolerance — a payload from a build that doesn't send
        // this key yet is assumed not buffering rather than failing the whole decode.
        isBuffering = try container.decodeIfPresent(Bool.self, forKey: .isBuffering) ?? false
    }

    /// A snapshot with no active book — the Watch shows its empty/"open iPhone" states.
    static func idle(scope: WatchAccountScope, accentHex: String = "E8A838") -> WatchPlaybackState {
        WatchPlaybackState(
            scope: scope, itemId: "", sessionId: nil, title: "", author: "",
            chapterTitle: nil, duration: 0, currentTime: 0, playbackRate: 1.0,
            isPlaying: false, lastUpdated: Date(), coverData: nil,
            skipBackwardInterval: 15, skipForwardInterval: 30,
            sleepTimerOption: .off, sleepTimerRemaining: 0, accentHex: accentHex,
            isBuffering: false)
    }

    var hasActiveItem: Bool { !itemId.isEmpty }
}

// MARK: - Progress estimation (testable, no Foundation date-formatting dependencies)

/// Estimates "now" position from a `WatchPlaybackState` without re-syncing, so the Watch
/// UI can tick smoothly between the ~few-second snapshots pushed from the phone. Pure
/// function — trivially unit-testable.
enum WatchProgressEstimator {
    static func estimatedCurrentTime(state: WatchPlaybackState, now: Date = Date()) -> Double {
        guard state.hasActiveItem else { return 0 }
        guard state.isPlaying else {
            return clamp(state.currentTime, duration: state.duration)
        }
        let elapsedWallClock = now.timeIntervalSince(state.lastUpdated)
        // Never let a clock skew or a very stale snapshot run the estimate backwards.
        guard elapsedWallClock > 0 else {
            return clamp(state.currentTime, duration: state.duration)
        }
        let projected = state.currentTime + elapsedWallClock * state.playbackRate
        return clamp(projected, duration: state.duration)
    }

    /// Clamp between 0 and duration (or 0 if duration is unknown/zero) — guards against
    /// ever showing negative time or overshooting past the end from extrapolation.
    static func clamp(_ time: Double, duration: Double) -> Double {
        guard duration > 0 else { return max(0, time) }
        return min(max(time, 0), duration)
    }

    static func progressFraction(state: WatchPlaybackState, now: Date = Date()) -> Double {
        guard state.duration > 0 else { return 0 }
        return estimatedCurrentTime(state: state, now: now) / state.duration
    }
}

// MARK: - Staleness

/// How ShelfHead Watch decides a phone-provided snapshot is too old to trust for display
/// or to act commands against. Kept as a single named threshold so the Watch UI and the
/// command-validation path agree on the definition of "fresh."
enum WatchStaleness {
    /// Snapshots older than this are shown as "Syncing…" and block new commands that
    /// depend on knowing the current position (seek/bookmark/markFinished) until a
    /// fresh snapshot arrives.
    static let threshold: TimeInterval = 45

    static func isStale(lastUpdated: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastUpdated) > threshold
    }
}

// MARK: - Playback speed cycling

/// The fixed set of speeds surfaced on the Watch (matches the mockup / common iOS
/// presets). Cycling (rather than a full picker) keeps the watch interaction to a single
/// tap for the common case, with `WatchPlaybackCommand.setPlaybackSpeed` still able to
/// carry any arbitrary rate if a picker is added later.
enum WatchSpeedCycler {
    static let speeds: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Next speed after `current`: the nearest preset strictly above it, wrapping to the
    /// lowest preset only from the top.
    // Critique 2026-10-06 (harden): a custom phone rate like 1.1x used to fall back to the
    // first preset (0.8x), i.e. a tap on "faster" slowed playback down.
    static func next(after current: Double) -> Double {
        if let above = speeds.first(where: { $0 > current + 0.001 }) { return above }
        return speeds.first ?? 1.0
    }

    /// Up to two decimals, trailing zeros trimmed, with the multiplication sign the phone
    /// and CarPlay use (`CarPlayCoordinator.formattedPlaybackRate`, PL-13). `%.2g` showed
    /// 1.25 as "1.2x" and 1.75 as "1.8x". Not shared with that function because it lives
    /// in the iOS-only CarPlay file.
    static func label(for speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }
}

// MARK: - Play-request decision

/// What a tap on a book row should do in companion mode. Playing a different book replaces
/// whatever the phone is playing, so that case asks first.
// Critique 2026-10-06 (harden): a stray tap on a list row used to cut off the current book
// on the phone with no warning.
enum WatchPlayRequestDecision: Equatable {
    case playNow
    case confirmReplacing(currentTitle: String)

    /// Same book, nothing active, or a paused session: play immediately. Only a different
    /// book that is actively playing needs confirmation.
    static func decide(requestedItemId: String, current: WatchPlaybackState?) -> WatchPlayRequestDecision {
        guard let current, current.hasActiveItem, current.isPlaying,
              current.itemId != requestedItemId else { return .playNow }
        return .confirmReplacing(currentTitle: current.title)
    }
}

// MARK: - Sleep timer

/// Sleep timer options exposed on the Watch. Deliberately a smaller set than the phone's
/// full `SleepTimerOption` (no arbitrary chapter-count or scheduled options) — the phone
/// side maps this onto its own richer enum (see `WatchSessionManager`).
enum WatchSleepTimerOption: Codable, Equatable, Hashable, Sendable {
    case off
    case minutes(Int)
    case endOfChapter

    static let presets: [WatchSleepTimerOption] = [
        .off, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter,
    ]

    var label: String {
        switch self {
        case .off: return String(localized: "Off", comment: "Sleep timer option: timer disabled")
        case .minutes(let m): return String(localized: "\(m) Minutes", comment: "Sleep timer option. %lld is the number of minutes.")
        case .endOfChapter: return String(localized: "End of Chapter", comment: "Sleep timer option: stop at the end of the current chapter")
        }
    }
}

// MARK: - Commands (watch -> phone)

enum WatchCommandKind: Codable, Equatable, Sendable {
    case playPause
    case play
    case pause
    case rewind(seconds: Double)
    case forward(seconds: Double)
    case seek(time: Double)
    case seekToChapter(chapterId: Int, startTime: Double)
    case addBookmark
    case seekToBookmark(time: Double)
    case setPlaybackSpeed(rate: Double)
    case setSleepTimer(option: WatchSleepTimerOption)
    /// Batch 490 (REVIEW 2026-11-11 F29): add `seconds` to the running sleep timer
    /// (the Watch sends 900, "Add 15 Minutes"). The phone applies it through
    /// `PlayerViewModel.extendSleepTimer(by:)`. A phone older than Batch 490 can't decode
    /// this case and replies "malformed", so the Watch shows the command as failed and
    /// rolls its optimistic countdown back; nothing else changes on either side.
    case extendSleepTimer(seconds: Double)
    case markFinished
    /// Batch 414: mark a specific book finished, whether or not it is the one playing
    /// (Watch Book Details without a Watch session). `.markFinished` stays for Now
    /// Playing, which means "the current book" and is checked against it. A phone older
    /// than Batch 414 can't decode this case and the command fails on the Watch.
    case markItemFinished(itemId: String)
    /// Ask the phone to start playing a specific (not-currently-active) item — used
    /// from the Downloads / Continue Listening rows.
    case playItem(itemId: String)
    /// Ask the phone to push a completely fresh snapshot (launch, foreground, or after
    /// detecting staleness) rather than waiting for the next periodic push.
    case requestSnapshot

    /// Whether this command requires an already-active, non-stale playback session to
    /// mean anything (as opposed to `playItem`/`requestSnapshot`, which are meaningful
    /// even with no active book).
    var requiresActiveItem: Bool {
        switch self {
        case .playItem, .markItemFinished, .requestSnapshot:
            return false
        default:
            return true
        }
    }

    /// WATCH-1: whether this command's correctness actually depends on the phone's
    /// playback snapshot (position, current chapter) being *fresh*, as opposed to just
    /// requiring some active item to apply to. `.playPause`/`.play`/`.pause`/
    /// `.setPlaybackSpeed`/`.setSleepTimer` don't touch position at all, and
    /// `.rewind`/`.forward` skip relative to the phone's own live `currentTime` — not
    /// the Watch's (possibly stale) estimate of it — so none of those need the
    /// snapshot to be recent, only present. An absolute seek, a bookmark, or "mark
    /// finished," by contrast, only make sense relative to a position/chapter the
    /// Watch actually still trusts. Before this distinction existed, *every*
    /// `requiresActiveItem` command failed `WatchStaleness`'s 45s check identically —
    /// including the ones that had nothing to do with position — which is what made
    /// leaving the Watch open on a paused book eventually break its play/pause button
    /// too (see WATCH-1 in REVIEW_2026-08-12.md).
    var isPositionDependent: Bool {
        switch self {
        case .seek, .seekToChapter, .seekToBookmark, .addBookmark, .markFinished:
            return true
        case .playPause, .play, .pause, .rewind, .forward, .setPlaybackSpeed, .setSleepTimer,
             .extendSleepTimer, .playItem, .markItemFinished, .requestSnapshot:
            return false
        }
    }
}

/// A command sent from the Watch to the iPhone. Always carries the scope the Watch
/// believed was active, and (when relevant) the item id the Watch believed it was
/// controlling — both are re-validated on the phone before anything is applied (see
/// `WatchSessionManager.handle(command:)`), so a command generated against
/// stale/cross-account state fails safely instead of mutating the wrong book/account.
struct WatchPlaybackCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Nil only for `.requestSnapshot`, sent when the Watch has no snapshot yet at all
    /// (first launch, reinstall, or after clearing local state) and so has no scope to
    /// report — this is the one command that's specifically meant to recover from that
    /// situation, so it can't itself require already knowing the scope. Every other
    /// command kind always carries a real scope; see `WatchCommandValidator.validate`
    /// for how the two cases are handled differently.
    var scope: WatchAccountScope?
    /// The item id the Watch believed was active when it issued this command. Nil only
    /// for commands that don't depend on a specific item (`requestSnapshot`); `playItem`
    /// carries its *target* item id inside `kind`, not here.
    var itemId: String?
    var issuedAt: Date = Date()
    var kind: WatchCommandKind
}

// MARK: - Command validation (testable, pure)

/// Centralised "is this command safe to apply" logic, shared conceptually between the
/// phone (which enforces it for real) and unit tests (which exercise it directly without
/// needing a live WCSession). See `WatchSessionManager.handle(command:)` for where this
/// is actually invoked against live state.
enum WatchCommandValidator {
    enum Failure: Error, Equatable {
        case scopeMismatch
        case itemMismatch
        case staleState
        case noActiveItem
    }

    /// - Parameters:
    ///   - command: the inbound command from the Watch.
    ///   - activeScope: the phone's currently active account scope (nil if signed out).
    ///   - activeItemId: the phone's currently active item id (nil if nothing playing).
    ///   - stateLastUpdated: when the phone's own playback state was last touched, used
    ///     to reject commands issued against a since-superseded state. Nil = no active
    ///     state (fine for commands that don't require one).
    ///   - now: injectable for testing.
    static func validate(
        _ command: WatchPlaybackCommand,
        activeScope: WatchAccountScope?,
        activeItemId: String?,
        stateLastUpdated: Date?,
        now: Date = Date()
    ) -> Result<Void, Failure> {
        // `.requestSnapshot` is the one command a Watch that doesn't know its scope yet
        // can send (see `WatchPlaybackCommand.scope`) — it's exactly the recovery path
        // for that situation, so it can't itself require a scope match. There's nothing
        // unsafe about it: it doesn't mutate anything, it just triggers a fresh push of
        // whatever the phone's real current state already is.
        if case .requestSnapshot = command.kind {
            return .success(())
        }

        guard let activeScope, let commandScope = command.scope, activeScope.matches(commandScope) else {
            return .failure(.scopeMismatch)
        }

        if !command.kind.requiresActiveItem {
            return .success(())
        }

        guard let activeItemId else { return .failure(.noActiveItem) }

        if let cmdItemId = command.itemId, cmdItemId != activeItemId {
            return .failure(.itemMismatch)
        }

        // WATCH-1: only the commands whose correctness actually depends on a fresh
        // position/chapter snapshot are gated on staleness — see
        // `WatchCommandKind.isPositionDependent`. Every `requiresActiveItem` command
        // used to be gated identically here, so `.playPause`/`.play`/`.pause`/
        // `.setPlaybackSpeed` (none of which touch position) failed right alongside
        // real seeks the moment the phone's snapshot aged past
        // `WatchStaleness.threshold` — which, combined with `pushIfNeeded()` never
        // refreshing `lastUpdated` while paused, meant leaving the Watch open on a
        // paused book eventually broke its play/pause button with no way to recover.
        if command.kind.isPositionDependent,
           let stateLastUpdated, WatchStaleness.isStale(lastUpdated: stateLastUpdated, now: now) {
            return .failure(.staleState)
        }

        return .success(())
    }
}

// MARK: - Timed chapter skip (Batch 399, mirrored for standalone Watch playback)

/// The phone's timed-chapter-skip settings (`SettingsStore.defaultChapterSkip` plus the
/// per-book overrides) as one small Codable payload. The phone pushes it over
/// WatchConnectivity (`WatchSessionManager`), and the Watch persists the last copy it
/// received so standalone playback keeps honouring it with the phone gone.
/// Values are seconds; 0 = off. `overrides[itemId]` is `[start, end]`, same shape the
/// phone stores.
///
/// Batch 495 (REVIEW 2026-11-11 W7): the same payload now also carries the rest of the
/// phone's playback settings standalone Watch playback honours. Every new field is
/// optional and decoded leniently (`init(from:)` below), so a new phone and an old Watch
/// app (unknown keys ignored) or an old phone and a new Watch app (keys missing, `nil`)
/// still agree on chapter skip. `nil` means "the phone didn't say".
nonisolated struct WatchChapterSkipSettings: Codable, Equatable, Sendable {
    var defaultStart: Int = 0
    var defaultEnd: Int = 0
    var overrides: [String: [Int]] = [:]
    /// `SettingsStore.skipBackwardInterval` / `skipForwardInterval`, seconds.
    var skipBackwardInterval: Double? = nil
    var skipForwardInterval: Double? = nil
    /// `SettingsStore.smartRewind`.
    var smartRewind: Bool? = nil
    /// `SettingsStore.defaultPlaybackSpeed`.
    var defaultSpeed: Double? = nil
    /// The phone's remembered per-book speeds (`SettingsKeys.perBookSpeed`), by item id.
    var perBookSpeeds: [String: Double]? = nil

    private nonisolated enum CodingKeys: String, CodingKey {
        case defaultStart, defaultEnd, overrides
        case skipBackwardInterval, skipForwardInterval, smartRewind, defaultSpeed, perBookSpeeds
    }

    /// The (start, end) trim for `itemId`: its override when present, else the default.
    func resolved(forItem itemId: String) -> (start: Int, end: Int) {
        if let pair = overrides[itemId], pair.count == 2 { return (pair[0], pair[1]) }
        return (defaultStart, defaultEnd)
    }

    /// UserDefaults key for the Watch's persisted copy.
    static let defaultsKey = "watch_chapterSkipSettings"

    static func load(from defaults: UserDefaults = .standard) -> WatchChapterSkipSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WatchChapterSkipSettings.self, from: data)
        else { return WatchChapterSkipSettings() }
        return decoded
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// In an extension so the memberwise initializer stays.
extension WatchChapterSkipSettings {
    /// Batch 495 (W7): the chapter-skip fields decode as they always did; each newer field
    /// is `try?`, so a missing or malformed one is `nil` instead of failing the whole
    /// payload (and with it chapter skip).
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultStart = try container.decodeIfPresent(Int.self, forKey: .defaultStart) ?? 0
        defaultEnd = try container.decodeIfPresent(Int.self, forKey: .defaultEnd) ?? 0
        overrides = try container.decodeIfPresent([String: [Int]].self, forKey: .overrides) ?? [:]
        skipBackwardInterval = (try? container.decodeIfPresent(Double.self, forKey: .skipBackwardInterval)) ?? nil
        skipForwardInterval = (try? container.decodeIfPresent(Double.self, forKey: .skipForwardInterval)) ?? nil
        smartRewind = (try? container.decodeIfPresent(Bool.self, forKey: .smartRewind)) ?? nil
        defaultSpeed = (try? container.decodeIfPresent(Double.self, forKey: .defaultSpeed)) ?? nil
        perBookSpeeds = (try? container.decodeIfPresent([String: Double].self, forKey: .perBookSpeeds)) ?? nil
    }
}

// MARK: - Watch book speed (Batch 497, REVIEW 2026-11-11 W7)

/// A speed set on the Watch for one book, sent to the iPhone so it remembers it too
/// (`SettingsStore.setSpeed(_:forItem:)`). Sent with `transferUserInfo` under
/// `userInfoKey`: queued and delivered even while the iPhone app isn't running or
/// reachable. Backward compatible both ways: an iPhone app without the receiver never
/// reads the key, and an older Watch app never sends it.
nonisolated struct WatchBookSpeedUpdate: Codable, Equatable, Sendable {
    static let userInfoKey = "watchBookSpeed"

    var itemId: String
    var rate: Double

    /// The iPhone's decision: the speed to store for `itemId`, or nil to drop the update.
    /// Dropped for an empty id or an unusable rate, and during SharePlay
    /// (`AudioPlayerService.isCoordinatingPlayback`): the group sets the rate then, and the
    /// iPhone doesn't remember speeds for a book it plays with the group. Otherwise clamped
    /// to 0.5×–3× and rounded to the nearest 0.05, as `PlayerViewModel.setPlaybackRate` does.
    static func acceptedRate(itemId: String, rate: Double, isCoordinatingPlayback: Bool) -> Double? {
        guard !itemId.isEmpty, rate.isFinite, rate > 0, !isCoordinatingPlayback else { return nil }
        let clamped = min(max(rate, 0.5), 3.0)
        return (clamped * 20).rounded() / 20
    }
}

// MARK: - Smart rewind (Batch 495, mirrored for standalone Watch playback)

/// Seconds to rewind when playback resumes, scaled by how long it was paused.
///
/// Under 10 s: 0, under a minute: 3, under 10 minutes: 5, under an hour: 10, longer: 20.
/// The one scale for both devices: the iPhone's `SettingsStore.smartRewindAmount(pausedFor:)`
/// forwards here, and the Watch's standalone engine calls it directly.
nonisolated enum WatchSmartRewind {
    static func seconds(pausedFor seconds: TimeInterval, isEnabled: Bool) -> Double {
        guard isEnabled, seconds.isFinite else { return 0 }
        switch seconds {
        case ..<10: return 0
        case ..<60: return 3
        case ..<600: return 5
        case ..<3600: return 10
        default: return 20
        }
    }
}

/// Pure timed-chapter-skip decision for the Watch's standalone engine.
///
/// KEEP IN SYNC with `AudioPlayerService.chapterSkipTarget` (iOS), which this is a
/// faithful port of (same guards, same 0.05 s landing past a boundary, never on the last
/// chapter, `minimumKept`). The iOS target can't share the Watch's chapter type and
/// that function takes the iOS `Chapter`, so the two are pinned by parallel tests
/// (`ChapterSkipDecisionTests` / `WatchChapterSkipTests`). The iOS one may later forward here.
///
/// Only ordinary playback triggers it: `previousTime` is the last tick's position (or the
/// last seek target) and the step to `currentTime` must be a short forward one, so a
/// deliberate seek into a trimmed region is left alone.
enum WatchChapterSkipRule {
    struct Bounds: Equatable, Sendable {
        var start: Double
        var end: Double
    }

    nonisolated static func target(
        chapters: [Bounds], previousTime: Double?, currentTime: Double,
        start: Int, end: Int, maxStep: Double = 2.0, minimumKept: Double = 10
    ) -> Double? {
        guard start > 0 || end > 0, let previousTime,
              currentTime >= previousTime, currentTime - previousTime <= maxStep,
              let index = chapters.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end })
        else { return nil }

        let startTrim = Double(start), endTrim = Double(end)
        func trimmable(_ chapter: Bounds) -> Bool {
            chapter.end - chapter.start >= startTrim + endTrim + minimumKept
        }
        let chapter = chapters[index]
        guard trimmable(chapter) else { return nil }

        if startTrim > 0, previousTime < chapter.start, currentTime < chapter.start + startTrim {
            return chapter.start + startTrim
        }

        let threshold = chapter.end - endTrim
        if endTrim > 0, index + 1 < chapters.count,
           previousTime < threshold, currentTime >= threshold {
            let next = chapters[index + 1]
            return next.start + (startTrim > 0 && trimmable(next) ? startTrim : 0.05)
        }
        return nil
    }
}

// MARK: - Watch setup report (Batch 496, REVIEW 2026-11-11 W13)

/// What the Watch tells the iPhone about its own sign-in, so Settings › Apple Watch can say
/// whether this account is set up there. Sent Watch → iPhone with
/// `updateApplicationContext` (latest wins, delivered when the iPhone app next runs) under
/// `contextKey`. Carries no token: a state, the session kind's raw value, the server URL
/// and the iPhone account id the last hand-over came from.
nonisolated struct WatchSetupReport: Codable, Equatable, Sendable {
    nonisolated enum State: String, Codable, Equatable, Sendable {
        case notSetUp, active, expired
    }

    static let contextKey = "watchSetup"

    var state: State
    /// `WatchSessionKind` / `WatchHandoffSessionKind` raw value ("dedicated", "durable",
    /// "shared"), nil when unknown.
    var sessionKind: String?
    var serverURL: String?
    /// The iPhone's `ServerAccount.id` from the hand-over reply's `accountId` key. Nil after
    /// a sign-in on the Watch itself, or a hand-over from an older iPhone build.
    var handoffAccountId: String?
    /// The iPhone's account switch or sign-out signed this Watch out, and it hasn't been
    /// set up again or told "Not Now".
    var signedOutOnPhone: Bool
    /// Seconds since 1970, `Int64` for arm64_32.
    var updatedAt: Int64
}
