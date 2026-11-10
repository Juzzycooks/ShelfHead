import Foundation

// Shares the current playback snapshot via the App Group below so the widget
// (Home Screen / Lock Screen) can render it.
//
// P3-16 (third-pass review, 14 Aug 2026): this file's header used to instruct readers
// to keep a hand-duplicated widget-side copy in sync (`ShelfHeadWidgets/
// SharedPlayback.swift`) — that setup was deliberately removed (see the WATCH-5
// follow-up review): this single file is now added directly to BOTH the app and
// widget targets' Sources build phases (a real, explicit `PBXBuildFile` entry on each,
// mirroring `WatchModels.swift`'s existing app+watch pattern), not a second
// hand-maintained copy. `ShelfHeadWidgets/SharedPlayback.swift` itself is gutted down
// to a comment explaining exactly this. Following the OLD instruction here — editing
// this struct and then going to update "the widget's copy" — would recreate the exact
// duplication this project deliberately removed, since there is no second copy left to
// update.
//
// IMPORTANT: this struct is still shared across an App Group JSON boundary (one side
// encodes with `JSONEncoder`, the phone-side services that write it and the widget
// that reads it are still two independently-built targets), so a change here still
// needs to stay something both sides can agree on — just not by hand-copying a second
// file anymore. This has bitten before (a since-deleted `ShelfHeadExtras/` copy fell
// out of sync and was missing `rate` and the on-disk cover storage) — the fix for that
// was moving to this single-shared-file setup, not a reason to distrust it.

enum SharedPlayback {
    static let appGroup = "group.com.shelfhead.app"
    private static let key = "currentPlayback"
    private static let coverFileName = "widget_cover.jpg"

    /// Control Center kinds — shared verbatim with the widget extension's control
    /// definitions and with `AudioPlayerService`'s `ControlCenter.reloadControls(ofKind:)`
    /// calls, so both sides must agree on the exact string.
    static let playbackControlKind = "com.shelfhead.app.playbackControl"
    static let sleepTimerControlKind = "com.shelfhead.app.sleepTimerControl"

    /// W3 (REVIEW_2026-09-04_UI.md Pass 4): stamped into every record this build writes,
    /// so a record left behind by an older build can be recognised and re-derived once
    /// instead of sitting on the Home Screen forever. Bump it when a stored record needs
    /// re-deriving again; `migrating(_:)` owns what that means.
    ///
    /// Version `0` is "written before this stamp existed", and that is exactly the record
    /// found on a real upgraded device: a pre-G2 title still carrying "(Unabridged)", plus
    /// the cover still embedded in the record under a `coverData` key this build's decoder
    /// ignores — so the widget drew a stale title next to its placeholder glyph, because
    /// the `widget_cover.jpg` the current code reads had never been written.
    static let currentSnapshotVersion = 1

    struct Snapshot: Codable, Sendable, Equatable {
        var itemId: String
        var title: String
        var author: String
        var currentTime: Double
        var duration: Double
        var isPlaying: Bool
        var updatedAt: Date
        var rate: Double?      // playback speed, so the widget advances progress correctly
        // WATCH-3 (follow-up review, 14 Aug 2026): the widget's skip buttons previously
        // showed hardcoded "gobackward.15"/"goforward.30" icons and matching "Skip back/
        // forward 15/30 seconds" accessibility labels regardless of what the user has
        // actually configured (`SettingsStore.skipBackwardInterval`/`skipForwardInterval`)
        // — the same class of bug WATCH-5 already fixed for the Watch app's own Skip
        // Duration row. `decodeIfPresent(...) ?? default` on decode so an old cached
        // snapshot written by a not-yet-updated main app (or a stale widget-side decode
        // during a staged rollout) degrades to the previous fixed 15/30 behavior instead
        // of failing to decode the whole snapshot.
        var skipBackwardInterval: Double?
        var skipForwardInterval: Double?
        /// Whether a sleep timer is currently armed — read by the Control Center sleep
        /// timer toggle so its shown state matches reality without a round trip.
        var sleepTimerActive: Bool?
        /// The length (minutes) the Control Center sleep timer toggle arms when turned on.
        var sleepTimerDefaultMinutes: Int?
        /// The current chapter's title, so the large widget can show it next to the
        /// chapter skip buttons. `nil` for a chapterless book/episode — the large
        /// layout hides the chapter row entirely in that case rather than showing a
        /// blank line.
        var chapterTitle: String?
        /// See `currentSnapshotVersion`. Non-optional so it always round-trips; `0` is
        /// what a record written by a build that predates it decodes to.
        var version: Int

        var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }

        enum CodingKeys: String, CodingKey {
            case itemId, title, author, currentTime, duration, isPlaying, updatedAt, rate
            case skipBackwardInterval, skipForwardInterval
            case sleepTimerActive, sleepTimerDefaultMinutes, chapterTitle, version
        }

        init(itemId: String, title: String, author: String, currentTime: Double, duration: Double,
             isPlaying: Bool, updatedAt: Date, rate: Double? = nil,
             skipBackwardInterval: Double? = nil, skipForwardInterval: Double? = nil,
             sleepTimerActive: Bool? = nil, sleepTimerDefaultMinutes: Int? = nil,
             chapterTitle: String? = nil,
             version: Int = SharedPlayback.currentSnapshotVersion) {
            self.itemId = itemId
            self.title = title
            self.author = author
            self.currentTime = currentTime
            self.duration = duration
            self.isPlaying = isPlaying
            self.updatedAt = updatedAt
            self.rate = rate
            self.skipBackwardInterval = skipBackwardInterval
            self.skipForwardInterval = skipForwardInterval
            self.sleepTimerActive = sleepTimerActive
            self.sleepTimerDefaultMinutes = sleepTimerDefaultMinutes
            self.chapterTitle = chapterTitle
            self.version = version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            itemId = try container.decode(String.self, forKey: .itemId)
            title = try container.decode(String.self, forKey: .title)
            author = try container.decode(String.self, forKey: .author)
            currentTime = try container.decode(Double.self, forKey: .currentTime)
            duration = try container.decode(Double.self, forKey: .duration)
            isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            rate = try container.decodeIfPresent(Double.self, forKey: .rate)
            skipBackwardInterval = try container.decodeIfPresent(Double.self, forKey: .skipBackwardInterval)
            skipForwardInterval = try container.decodeIfPresent(Double.self, forKey: .skipForwardInterval)
            sleepTimerActive = try container.decodeIfPresent(Bool.self, forKey: .sleepTimerActive)
            sleepTimerDefaultMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepTimerDefaultMinutes)
            chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// The cover JPEG used to live *inside* `Snapshot` (and so got re-encoded into every
    /// one of the ~60 future timeline entries the widget generates while playing — up to
    /// ~1-2 MB of duplicate bytes against the widget extension's tight memory ceiling).
    /// It's now written once, to a small file in the App Group container, only when the
    /// cover actually changes (i.e. on track change) — not on every playback tick. The
    /// widget view reads it directly from disk at render time instead of carrying it on
    /// each entry.
    private static var coverFileURL: URL? { containerURL?.appendingPathComponent(coverFileName) }

    // MARK: - Signed-in state (PL-9, docs/design-review.md Round 5)
    //
    // The widget's empty state used to say "Start a book in ShelfHead" unconditionally,
    // which is the wrong advice for someone who just installed the app and hasn't signed
    // in yet. `AuthViewModel` (the app's only owner of `isAuthenticated`) publishes this
    // flag here on every transition of that property — see its `didSet` — so the widget's
    // timeline provider can tell "signed out" from "signed in, nothing played yet" apart
    // without reaching for network or Keychain access it doesn't have.
    private static let signedInKey = "isSignedIn"

    /// The raw stored flag. `nil` means the key has never been written: either a fresh
    /// install that hasn't reached `AuthViewModel` yet, or a device that updated from a
    /// build before this flag existed. Callers that need to render an empty state should
    /// go through `resolvedSignedIn(hasSnapshot:)` instead, which resolves that gap.
    static var isSignedIn: Bool? {
        guard let defaults, defaults.object(forKey: signedInKey) != nil else { return nil }
        return defaults.bool(forKey: signedInKey)
    }

    /// Publishes whether the app is currently signed in. Call on every sign-in success
    /// AND on sign-out/removal-of-the-active-account — not just on sign-in — so the flag
    /// never lags the real session. Returns whether the stored value actually changed,
    /// so a caller that reloads widget timelines on a change (as `AuthViewModel` does)
    /// can skip a redundant `WidgetCenter.reloadAllTimelines()` when nothing moved.
    @discardableResult
    static func setSignedIn(_ value: Bool) -> Bool {
        guard let defaults else { return false }
        let hadKey = defaults.object(forKey: signedInKey) != nil
        let previous = defaults.bool(forKey: signedInKey)
        guard !hadKey || previous != value else { return false }
        defaults.set(value, forKey: signedInKey)
        return true
    }

    /// What the widget should treat "signed in" as, given whether a playback snapshot is
    /// currently on disk. Resolves the legacy/unknown gap: a device that updated from a
    /// build before `setSignedIn(_:)` existed has no key yet, and there's no way to tell
    /// "never signed in" from "signed in, but this build never got the chance to publish
    /// it" — except that the latter case can only have a playback snapshot if the user
    /// really was signed in at some point (nothing writes one otherwise). So a missing key
    /// resolves to `true` when a snapshot exists, and to `nil` (genuinely unknown) when it
    /// doesn't — which the widget renders as its original, account-agnostic "Start a book"
    /// copy, never as "sign in" for a user who might already be signed in.
    static func resolvedSignedIn(hasSnapshot: Bool) -> Bool? {
        if let isSignedIn { return isSignedIn }
        return hasSnapshot ? true : nil
    }

    // MARK: - Owning account (28 Oct 2026)
    //
    // The playback snapshot, the widget library and Up Next are single, unscoped App Group
    // records. Sign-out and account switches clear them (`tearDownAccountScopedState`), but
    // a session can also end without that teardown — the Keychain session is gone at
    // launch (`checkExistingSession`'s no-credentials path: a restore to a new phone, a
    // wiped Keychain), or the app dies mid sign-out. The records then outlived their
    // account, and the next account to sign in got the old one's book in its mini player
    // (restored on the following launch) and on its widgets. Recording which account the
    // records belong to lets every sign-in claim them, clearing them first when they were
    // left by another (or an unknown) account.
    private static let ownerAccountKey = "sharedSurfacesAccountId"

    /// The account the shared records were last claimed by; `nil` before any claim
    /// (including every record written by a build older than this key).
    static var ownerAccountId: String? { defaults?.string(forKey: ownerAccountKey) }

    static func setOwnerAccountId(_ id: String?) {
        if let id { defaults?.set(id, forKey: ownerAccountKey) } else { defaults?.removeObject(forKey: ownerAccountKey) }
    }

    /// Whether the shared records must be cleared before `incoming` claims them. An unknown
    /// owner counts as foreign: there's no telling whose book a legacy record holds, and
    /// the cost of being wrong the safe way is one empty mini player for the same account.
    static func recordsNeedClearing(owner: String?, incoming: String?) -> Bool {
        owner == nil || owner != incoming
    }

    // MARK: - Writing (item 24, REVIEW-2026-09-09-REMAINING.md)
    //
    // `write(_:)` used to JSON-encode and write straight to the App Group `UserDefaults`
    // synchronously, on whatever actor called it — in practice the main actor, from
    // `AudioPlayerService.updateNowPlaying()`, which fires on every play/pause/seek/
    // track-change/chapter-boundary tick. A serial background queue plus "last write
    // wins" coalescing moves the actual encode+write off the caller entirely: a burst of
    // calls before the queue gets to run only pays for one encode+write, of whichever
    // snapshot was most recent when it ran.
    //
    // `pendingSnapshot` is `Snapshot??` (not `Snapshot?`) so "no write queued" (outer
    // `nil`) and "queued write that clears the record" (`.some(nil)`, from `write(nil)`)
    // stay distinguishable.
    private static let writeQueue = DispatchQueue(label: "com.shelfhead.sharedplayback.write", qos: .utility)
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var pendingSnapshot: Snapshot??
    nonisolated(unsafe) private static var writeInFlight = false

    /// Call from the main app whenever playback state changes. Never blocks the caller —
    /// see the section header above.
    static func write(_ snapshot: Snapshot?) {
        stateLock.lock()
        pendingSnapshot = snapshot
        let needsSchedule = !writeInFlight
        writeInFlight = true
        stateLock.unlock()
        guard needsSchedule else { return }
        writeQueue.async { drainPendingWrite() }
    }

    /// Runs on `writeQueue`. Keeps draining until nothing new arrived while the previous
    /// write was in flight, so a call to `write(_:)` that lands mid-encode is never lost
    /// — just coalesced with whatever's still pending when this loop gets back around.
    private static func drainPendingWrite() {
        while true {
            stateLock.lock()
            guard let next = pendingSnapshot else {
                writeInFlight = false
                stateLock.unlock()
                return
            }
            pendingSnapshot = nil
            stateLock.unlock()
            performWrite(next)
        }
    }

    /// The last snapshot actually persisted (as opposed to merely queued) — confined to
    /// `writeQueue`, since only `performWrite` (always called on that queue) touches it.
    ///
    /// `Snapshot??`: the outer `nil` means "nothing written by this process yet", which is
    /// not the same as "the stored record is empty". As a plain `Snapshot?` the two were
    /// conflated, so a `write(nil)` that was a process's first write compared equal to the
    /// initial `nil` and was dropped as redundant — leaving the previous run's record on
    /// disk (28 Oct 2026: a sign-in's clear of another account's book never landed, and the
    /// next launch restored that book into the mini player).
    nonisolated(unsafe) private static var lastWritten: Snapshot?? = .none

    /// The actual encode + `UserDefaults` write, run only on `writeQueue`.
    private static func performWrite(_ snapshot: Snapshot?) {
        guard !shouldSkipWrite(snapshot, lastWritten: lastWritten) else { return }
        lastWritten = .some(snapshot)
        guard let defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Blocks until every write already handed to `write(_:)` has actually landed in
    /// `UserDefaults`. `writeQueue` is serial, so an empty `sync` block behind it can't
    /// return before everything queued ahead of it (i.e. every prior `drainPendingWrite`)
    /// has finished — no separate "is anything pending" bookkeeping needed.
    ///
    /// For a caller that must guarantee the App Group record is current before the
    /// process might be suspended — `AudioPlayerService.flushProgress()` (the
    /// background/terminate path) calls this after `startPendingWrites()` — and before
    /// `WidgetCenter.shared.reloadAllTimelines()` actually runs, so a throttled reload
    /// can't read a not-yet-written value back out of `UserDefaults`
    /// (`reloadWidgetsThrottled()` in `AudioPlayerService`). Safe, and cheap, to call when
    /// nothing is pending.
    static func flush() {
        writeQueue.sync {}
    }

    /// Whether writing `snapshot` right after `previous` would be indistinguishable from
    /// not writing at all — pulled out as a pure equality check (no I/O, no threading) so
    /// it's unit-testable on its own; the coalescing/threading above is what actually uses
    /// it to skip a redundant encode+write. In practice this mostly catches the same
    /// state being pushed twice in a row from two different call sites in one tick (e.g.
    /// `stop()`'s explicit `write(nil)` following an already-nil record); `Snapshot.
    /// updatedAt` being stamped fresh on nearly every real playback write means it rarely
    /// fires for ordinary ticking playback, which is expected — this is a narrow
    /// dedup, not the main fix (the queue above is).
    static func isRedundantWrite(_ snapshot: Snapshot?, previous: Snapshot?) -> Bool {
        snapshot == previous
    }

    /// `performWrite`'s skip decision. Never skips before this process has written
    /// anything (`lastWritten == .none`): what's on disk is then unknown, so even a clear
    /// must go through.
    static func shouldSkipWrite(_ snapshot: Snapshot?, lastWritten: Snapshot??) -> Bool {
        guard case .some(let previous) = lastWritten else { return false }
        return isRedundantWrite(snapshot, previous: previous)
    }

    /// Read from the widget timeline provider.
    ///
    /// W3 (REVIEW_2026-09-04_UI.md Pass 4): this also re-derives a record left behind by
    /// an older build, once, in place. Doing it here rather than from an app-launch hook
    /// is deliberate — the widget extension reads this too, so a user who upgrades and
    /// never presses play still gets a corrected title and a real cover on the next
    /// timeline render instead of waiting for the app to be opened.
    ///
    /// The rewrite is idempotent and self-limiting: it only runs while the stored record
    /// is behind `currentSnapshotVersion`, and the record it writes back is stamped
    /// current. The one race it accepts is the app writing a fresh position between the
    /// decode and the rewrite, which would cost at most one `updateCurrentTime` tick
    /// (~20s of position) and is corrected by the app's very next write — the alternative,
    /// leaving a stale title on the Home Screen indefinitely for anyone who doesn't play
    /// something, is the worse trade.
    static func read() -> Snapshot? {
        guard let data = defaults?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard let migrated = migrating(snapshot) else { return snapshot }
        // Rescue the cover before rewriting: the record is about to be re-encoded by this
        // build's `Snapshot`, which has no `coverData` key, so the bytes are gone after this.
        if readCover() == nil, let embedded = embeddedCoverData(inRecord: data) {
            writeCover(embedded)
        }
        write(migrated)
        return migrated
    }

    // MARK: - Upgrade migration

    /// Pure half of the migration — what a stored record *should* look like under this
    /// build, or `nil` when it is already current. Split out from `read()`'s file/defaults
    /// work so the rules can be pinned by tests.
    static func migrating(_ snapshot: Snapshot) -> Snapshot? {
        guard snapshot.version < currentSnapshotVersion else { return nil }
        var migrated = snapshot
        migrated.title = normalizedTitle(snapshot.title)
        migrated.version = currentSnapshotVersion
        return migrated
    }

    /// The cover bytes a pre-split record carried inline under `coverData`, if any.
    ///
    /// `Snapshot` deliberately has no such key any more (see `coverFileURL`), so the only
    /// way to recover them is to decode the raw record a second time against a shape that
    /// does. Returns nil for a record that never had one, or whose value is empty.
    static func embeddedCoverData(inRecord data: Data) -> Data? {
        struct LegacyRecord: Decodable { let coverData: Data? }
        guard let legacy = try? JSONDecoder().decode(LegacyRecord.self, from: data),
              let cover = legacy.coverData, !cover.isEmpty else { return nil }
        return cover
    }

    /// The same display rule as `LibraryItem.displayTitle` (G2) — strip a trailing
    /// "(Unabridged)" / "[Unabridged]" / ": Unabridged" / " - Unabridged" — re-implemented
    /// here rather than called.
    ///
    /// It has to be: this file is compiled into the **widget** target as well as the app
    /// (see the header), and `LibraryItem` — the whole `Models/` layer — isn't in that
    /// target. `SharedPlaybackMigrationTests` asserts the two implementations agree over a
    /// shared corpus. `LibraryItem.displayTitle` now delegates here (folded at integration),
    /// so this is the one implementation of the rule.
    static func normalizedTitle(_ raw: String) -> String {
        let pattern = #"\s*(?:[\(\[]\s*unabridged\s*[\)\]]|[:\-\u2013\u2014]\s*unabridged)\s*$"#
        guard let range = raw.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return raw
        }
        let stripped = raw[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? raw : stripped
    }

    /// Call whenever the current track's cover image changes (not on every progress update).
    static func writeCover(_ data: Data?) {
        guard let coverFileURL else { return }
        if let data {
            try? data.write(to: coverFileURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: coverFileURL)
        }
    }

    /// Read from the widget view at render time.
    static func readCover() -> Data? {
        guard let coverFileURL else { return nil }
        return try? Data(contentsOf: coverFileURL)
    }
}

// MARK: - Live Activities (Batch 406)
//
// The two Live Activities' data shapes. They live in this file, not a new one, because
// this is the one source already compiled into both the app (which starts, updates and
// ends the activities — `LiveActivityController`) and the widget extension (which draws
// them — `ShelfHeadWidgets/ShelfHeadLiveActivities.swift`); a second shared file would
// need a `project.pbxproj` membership edit.
//
// The content states are plain `Codable`/`Hashable` structs outside the ActivityKit guard
// on purpose: `LiveActivityController`'s pure decision functions (and their tests) build
// and compare them without touching ActivityKit. Only the `ActivityAttributes`
// conformances need the framework. Keep both sides in agreement the same way as
// `Snapshot` above: the app encodes these, the widget decodes them, and ActivityKit caps
// the encoded content at 4 KB (`Activity.update(_:)` documentation), so no covers or
// other blobs belong here.

/// Dynamic content of the sleep timer Live Activity.
struct SleepTimerActivityState: Codable, Hashable, Sendable {
    /// Which sleep timer is armed — drives the one-word label ("Sleep in" vs "Chapter
    /// end" vs "Book end"); the countdown itself is always a wall-clock end date.
    enum Kind: String, Codable, Hashable, Sendable {
        case countdown
        case chapter
        case endOfBook
    }

    var kind: Kind
    var bookTitle: String
    /// Wall-clock moment the timer will fire, for `Text(timerInterval:)` to count down to
    /// without any further update from the app. `nil` while paused.
    var endDate: Date?
    /// Wall-clock seconds left, frozen, shown while `isPaused`.
    var pausedRemaining: TimeInterval
    var isPaused: Bool
}

/// Dynamic content of the aggregate downloads Live Activity.
struct DownloadsActivityState: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        case downloading
        /// The queue drained with at least one book saved. Shown briefly, then dismissed.
        case finished
        /// The queue drained and every book in this run failed.
        case failed
    }

    var phase: Phase
    /// Books still in flight (paused ones included while anything else is moving).
    var activeCount: Int
    /// Aggregate progress over this run's books, 0...1. Finished books count as 1.
    var fraction: Double
    var finishedCount: Int
    var failedCount: Int
    /// The book's title when exactly one is in flight, so the line can name it.
    var singleTitle: String?
}

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.2, *)
struct SleepTimerActivityAttributes: ActivityAttributes {
    typealias ContentState = SleepTimerActivityState
}

@available(iOS 16.2, *)
struct DownloadsActivityAttributes: ActivityAttributes {
    typealias ContentState = DownloadsActivityState
}
#endif
