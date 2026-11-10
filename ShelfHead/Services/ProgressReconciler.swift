import Foundation

/// §8 decomposition (REVIEW_2026-08-12.md): the review counted **three** independent
/// implementations of "which side's listening progress is more recent" scattered across
/// `PlayerViewModel.resolvedStartTime`, `DownloadManager.reconcile`, and a third site it
/// cited in `AudioPlayerService.swift`. Re-reading current source, only the first two
/// still exist as of this batch — the third no longer does (this file/logic has moved
/// or been rewritten since the review was written, and no equivalent "local vs. server
/// timestamp" comparison remains in `AudioPlayerService.swift`). The two real
/// duplicates are genuinely the same underlying question asked in two different
/// contexts:
///   - `PlayerViewModel.resolvedStartTime`: "which position should I resume playback
///     from?" — a simple pick between local and server, no conflict concept, because
///     starting playback isn't the moment to interrupt the user with a decision.
///   - `DownloadManager.reconcile`: "should I push, pull, or ask the user?" — the same
///     newer-wins comparison, but with an added divergence check that surfaces
///     `pendingProgressConflict` instead of silently discarding a large gap.
///
/// Extracting a single `Side` primitive both call sites share, plus the richer
/// `reconcile(...)` decision `DownloadManager` alone needs, removes the duplication
/// that actually exists without forcing the two different UX needs into one identical
/// API. This is a pure, `Sendable`, dependency-free type — directly unit-testable (see
/// `ProgressReconcilerTests.swift`) without touching `DownloadManager`/`PlayerViewModel`
/// or any of their `@MainActor`/service dependencies.
enum ProgressReconciler {
    enum Side: Equatable, Sendable {
        case local
        case server
    }

    /// Which side's timestamp is more recent. Both values must be in the same unit
    /// (callers in this codebase use epoch milliseconds). A tie resolves to `.server` —
    /// this matches the exact pre-existing behavior at both original call sites, which
    /// each tested `localMs > serverMs` (strictly greater) before treating local as
    /// newer, so an exact tie already fell through to the server side in both places.
    /// (Starting playback no longer uses this; see `startPosition`.)
    static func newerSide(localLastUpdate: Double, serverLastUpdate: Double) -> Side {
        localLastUpdate > serverLastUpdate ? .local : .server
    }

    /// One saved position a book could start from, with the time it was written (epoch
    /// **milliseconds**) when that's known. `nil` means unknown, never "zero".
    struct StartCandidate: Equatable, Sendable {
        let time: Double
        let updatedAtMs: Double?

        init(time: Double, updatedAtMs: Double?) {
            self.time = time
            self.updatedAtMs = updatedAtMs
        }
    }

    /// Polish pass Phase 2a #3 (4 November 2026): the position a book starts from.
    ///
    /// Replaces `resolvedStartTime`, which compared the local manifest's timestamp with
    /// `item.mediaProgress?.lastUpdate ?? 0`. A restored or list item often carries no
    /// progress, so the server side read as "written at 1970" and the local copy always
    /// won — a downloaded book resumed at its own stale position and the next sync pushed
    /// that over newer listening from another device.
    ///
    /// The rule now:
    ///   - **Server answered** (`serverAnswered`): the furthest-ahead valid position among
    ///     the fresh server session, the downloaded copy, and a position still queued for
    ///     upload. Timestamps don't pick the winner.
    ///   - **Server didn't answer in time**: the furthest-ahead valid position among the
    ///     downloaded copy, the queue, and the last server position this device knew, so
    ///     a local start never begins behind what the server last said.
    ///   - **A reset wins.** A server side at the start (under 1 s) whose timestamp is
    ///     known and newer than another candidate's is a deliberate "start over" (Book
    ///     Detail's Reset Progress, or the web player). Candidates written before it, or
    ///     with no timestamp, don't count. Without a known server timestamp there's no
    ///     way to tell a reset from a never-started book, so furthest-ahead applies.
    ///
    /// "Valid" means finite, above zero, and within `duration` when the duration is known.
    /// A deliberate rewind on another device is overridden by a further-ahead copy here;
    /// that trade-off is the user's call (4 November 2026).
    static func startPosition(
        serverAnswered: Bool,
        server: StartCandidate?,
        local: StartCandidate?,
        queued: StartCandidate?,
        lastKnownServer: StartCandidate?,
        duration: Double
    ) -> Double {
        let serverSide = serverAnswered ? server : lastKnownServer
        func isValid(_ t: Double) -> Bool {
            t.isFinite && t > 0 && (duration <= 0 || t <= duration)
        }
        // A known, recent "back to the start" on the server disqualifies anything older.
        let resetAtMs: Double? = {
            guard let serverSide, serverSide.time < 1, let stamp = serverSide.updatedAtMs, stamp > 0 else { return nil }
            return stamp
        }()
        func survivesReset(_ c: StartCandidate) -> Bool {
            guard let resetAtMs else { return true }
            guard let stamp = c.updatedAtMs else { return false }
            return stamp > resetAtMs
        }
        let others = [local, queued].compactMap { $0 }.filter(survivesReset)
        let pool = ([serverSide].compactMap { $0 } + others).map(\.time).filter(isValid)
        return pool.max() ?? 0
    }

    enum ReconcileOutcome: Equatable, Sendable {
        /// Neither side is newer (a tie, or one/both sides have no meaningful position
        /// yet) — nothing to do this pass.
        case noAction
        /// Local progress is newer — the caller should push it to the server.
        case pushLocal
        /// The server's progress is newer — the caller should pull it into the local
        /// manifest.
        case pullServer
        /// The two sides diverge by more than `conflictThreshold`, the server copy isn't
        /// finished, **and** the gap isn't explained by one side simply having listened
        /// on past the other — too large a gap to silently pick a side; the caller should
        /// surface this to the user instead (see `DownloadManager.pendingProgressConflict`).
        case conflict
    }

    /// The per-book decision `DownloadManager.reconcile` makes. This function only
    /// decides WHICH action to take; the caller still performs the actual mutation
    /// (updating its own manifest, calling the network API, etc.) using its own full
    /// context, since those values (e.g. the exact `MediaProgress` object) aren't worth
    /// threading through a pure decision function just to hand back unchanged.
    ///
    /// **Conflict semantics (fix 2.3, REVIEW-2026-09-09.md).** This used to return
    /// `.conflict` on *raw divergence alone* — `localTime > 0`, `serverTime > 0`, gap
    /// past the threshold — decided before it ever looked at which side's `lastUpdate`
    /// was newer. That made two entirely ordinary situations look like conflicts:
    ///   1. Listening offline for more than five minutes and then reconnecting. The
    ///      device's own forward progress is the only thing that moved, but the user got
    ///      "Progress Doesn't Match", and because `DownloadManager.reconcile` skips a
    ///      conflicted book entirely, the genuinely newer local position was never
    ///      pushed until the prompt was answered — the offline listening the prompt was
    ///      warning about was itself held hostage by the prompt.
    ///   2. Listening on another device (or the web player) while this one sat idle. The
    ///      server was strictly newer *and* strictly ahead; this device had nothing to
    ///      lose, and the honest action was a silent pull.
    /// The Watch documents the same defect and works around it locally in
    /// `WatchProgressSyncCoordinator.evaluateAndPush` — "suppress the conflict when the
    /// divergence is fully explained by this device's own forward progress." That's what
    /// `isUnexplainedDivergence` below ports, expressed in the inputs this function
    /// actually has (see its own comment for the limitation this leaves behind).
    ///
    /// - Parameters:
    ///   - serverEntryExists: whether the server actually reported *any* progress for
    ///     this item (as opposed to `serverTime`/`serverLastUpdate` simply defaulting to
    ///     "no value" because there's nothing to report) — kept as its own parameter
    ///     rather than inferred from `serverTime != nil`, because the caller's pull
    ///     branch only requires a progress entry to exist, not that its `currentTime`
    ///     specifically be non-nil (a nil `currentTime` on an existing entry still
    ///     stamps the local `lastUpdate` forward, via `server.currentTime ??
    ///     book.currentTime`). Collapsing that into `serverTime != nil` would silently
    ///     change this edge case's outcome.
    static func reconcile(
        localTime: Double, localLastUpdate: Double, localDuration: Double,
        serverEntryExists: Bool, serverTime: Double?, serverLastUpdate: Double, serverIsFinished: Bool,
        conflictThreshold: Double
    ) -> ReconcileOutcome {
        if serverEntryExists, !serverIsFinished, localTime > 0,
           let serverTime, serverTime > 0,
           abs(localTime - serverTime) > conflictThreshold,
           isUnexplainedDivergence(
               localTime: localTime, localLastUpdate: localLastUpdate,
               serverTime: serverTime, serverLastUpdate: serverLastUpdate) {
            return .conflict
        }
        if localLastUpdate > serverLastUpdate, localTime > 0, localDuration > 0 {
            return .pushLocal
        } else if serverLastUpdate > localLastUpdate, serverEntryExists {
            return .pullServer
        }
        return .noAction
    }

    /// Whether a beyond-threshold gap between the two positions is one that last-write-wins
    /// would resolve *destructively* — i.e. the side that wrote most recently is the side
    /// that is **behind**, so auto-picking it would drag the book's position backwards past
    /// the threshold and throw away listening the other side did.
    ///
    /// The reasoning, side by side:
    ///   - **Local newer and ahead** → this device listened on from (at least) where the
    ///     server already was. Nothing to ask about: push. This is the offline-listening
    ///     case, and it is exactly the Watch's "divergence fully explained by this
    ///     device's own forward progress" suppression.
    ///   - **Server newer and ahead** → another device/the web player listened on from
    ///     where this one was. Nothing to lose here: pull.
    ///   - **Local newer but behind** → this device wrote a *lower* position after the
    ///     server had already been moved higher, which is the flight case: we were offline,
    ///     so we listened from a stale base while someone else advanced the server. Both
    ///     positions are real and picking either loses one. Ask.
    ///   - **Server newer but behind** → the mirror image (someone rewound or restarted
    ///     the book elsewhere after this device had listened further). Ask.
    ///   - **Exact `lastUpdate` tie with a large gap** → no side is newer at all, so
    ///     there is nothing to explain the gap with. Ask. (Previously this fell through to
    ///     `.noAction`, which left the two positions permanently disagreeing with neither
    ///     a push nor a pull ever happening.)
    ///
    /// **Limitation, stated honestly:** this function's inputs are two positions and two
    /// timestamps. There is no record of the last position the two sides actually agreed
    /// on, and Audiobookshelf's `MediaProgress` carries no device attribution (the same
    /// dead end `WatchProgressSyncCoordinator` documents), so "both sides moved forward
    /// since we last agreed" cannot be distinguished from "only one side moved" whenever
    /// the newer side is also the one that's ahead. In that shape the newer-and-ahead side
    /// wins silently, which can still cost another device its place in a book both sides
    /// advanced. Catching it would need a persisted per-item "last successfully synced
    /// position" (the Watch keeps one as `lastSuccessfulPush`, which is why it can also
    /// suppress on *its own* last push rather than only on direction) — deliberately not
    /// added here in this batch, since it introduces new per-account persistence and, with
    /// a stale or clock-skewed record, its own class of false prompt. What is fixed here is
    /// the whole class of prompts the review actually reported, plus the guarantee that a
    /// position never silently moves backwards by more than the threshold.
    private static func isUnexplainedDivergence(
        localTime: Double, localLastUpdate: Double, serverTime: Double, serverLastUpdate: Double
    ) -> Bool {
        if localLastUpdate > serverLastUpdate { return localTime < serverTime }
        if serverLastUpdate > localLastUpdate { return serverTime < localTime }
        return true
    }
}
