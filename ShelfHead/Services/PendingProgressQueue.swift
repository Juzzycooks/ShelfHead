import Foundation

/// Serialized owner of the offline/failed-sync progress queue (ARCH-3, REVIEW_2026-08-12.md).
///
/// Before this type existed, the queue was a `load-whole-dictionary → mutate one key →
/// save-whole-dictionary` pattern spread across several `private static func`s on
/// `AudioPlayerService`, backed by `UserDefaults`. All of it ran on the main actor, but
/// every mutation still raced every other one across an `await` boundary:
///
/// 1. `flushPendingProgress` snapshots the dictionary (`{itemId: t=100}`) and suspends on
///    the network write.
/// 2. The 30s periodic timer fires `syncProgress()` in between, which records a newer
///    position (`t=400`) — the intervening `syncSession` call happens to fail, so it stays
///    queued, which is the entire point of the queue.
/// 3. The flush's write of `t=100` finally succeeds, and it deletes the entry by key —
///    including the `t=400` the concurrent `record` just wrote. Five minutes of real
///    listening time is gone, with no error anywhere.
///
/// A second, independent bug lived alongside it: the old `pendingKey(itemId:)` read
/// `AuthStore.shared.serverURL` / `AccountStore.currentAccountId` **at the moment the
/// queued `Task` body actually ran**, not at the moment the position was captured. Since
/// `AuthViewModel.switchAccount` calls `stop()` (which syncs/queues progress, spawning a
/// `Task`) and only *then* logs into the new account, a `Task` that happened to be
/// scheduled after the login landed would queue the *outgoing* account's position under
/// the *incoming* account's scope key — silently mis-attributing progress across accounts,
/// exactly the failure the composite scope key was introduced to prevent in the first place.
///
/// This actor closes both bugs structurally rather than patching around them:
/// - It is the **single serialized owner** of the queue. Every mutation (`record`, `clear`,
///   `drain`) runs one at a time on the actor's own executor, so there is no `await`
///   boundary in the middle of a read-modify-write for another call to land in.
/// - `clear(itemId:scope:ifNotNewerThan:)` takes the `updatedAt` of the entry the caller
///   is trying to clear (the one whose write just succeeded) and refuses to delete
///   anything newer — the guard the old `clearPendingKey` never had.
/// - `Entry.scope` is computed by the caller **synchronously, before any `await`**, and
///   handed over as plain data. The actor never reads `AuthStore`/`AccountStore` itself,
///   so there's no later point at which the active account could have changed out from
///   under an in-flight write.
actor PendingProgressQueue {

    /// The shared instance every `AudioPlayerService` call site uses. Tests construct
    /// their own instance with a scratch `fileURL` instead of touching this one.
    static let shared = PendingProgressQueue()

    /// One queued offline/failed-sync position.
    ///
    /// `scope` is computed the same way as `DownloadManager.currentScopeKey()` (see
    /// `AudioPlayerService.currentProgressScope()`), so a server+account pair that's been
    /// signed out of — or merely switched away from — never has its queued position
    /// mistaken for the account that happens to be active when the queue is next drained.
    struct Entry: Codable, Sendable, Equatable {
        let scope: String
        let itemId: String
        let currentTime: Double
        let duration: Double
        let updatedAt: Double

        /// Set by `drain(...)` when this entry sits more than `conflictThreshold` *behind*
        /// the server's own position for the same item — the shape
        /// `ProgressReconciler.reconcile` calls `.conflict` and surfaces as the "Progress
        /// Doesn't Match" prompt. Such an entry must not be pushed (it would clobber the
        /// server's newer place in the book before the user has answered), must not be
        /// counted as a pending push in the UI, and must not be aged out as if it were
        /// ordinary stale weight.
        ///
        /// It is **not** sticky state a caller has to remember to clear: `drain` rewrites
        /// it from the current server position on every pass, and `record(_:)` replaces the
        /// whole entry (a fresh capture always arrives with `heldForConflict == false`), so
        /// the hold lifts by itself the moment the server stops being far ahead — which is
        /// exactly what `DownloadManager.resolveProgressConflict(_:keepLocal:)` produces on
        /// either branch (it pushes this device's position up, or pulls the server's down
        /// into the manifest so the next capture matches it). Nothing in
        /// `DownloadManager` has to call a new method for the hold to be released.
        ///
        /// Defaulted on decode (see `init(from:)`), so a queue file written before this
        /// field existed still decodes.
        let heldForConflict: Bool

        /// Set when this position was queued by something that had **already decided this
        /// exact divergence**, with strictly more information than the flush has:
        ///
        /// - `DownloadManager.resolveProgressConflict(_:keepLocal: true)` — the user tapped
        ///   "Keep This Device" on the "Progress Doesn't Match" prompt and the push failed
        ///   (offline, a transient error), so it is queued for retry.
        /// - `DownloadManager.reconcile`'s `.pushLocal` branch — `ProgressReconciler`
        ///   weighed both positions, both timestamps *and* `serverIsFinished` and chose to
        ///   push; the queued entry is only that decision's retry.
        ///
        /// `disposition(...)` treats such an entry as push-eligible no matter how far
        /// behind the server's position it sits. Without this, the hold-back introduced for
        /// the *undecided* case would silently veto the answer the user just gave — and
        /// `resolveProgressConflict` has no queue call on its success path to release a
        /// hold with, so the veto would last until the prompt was raised and answered all
        /// over again.
        ///
        /// It exempts the entry from the position gap only. A server write that lands
        /// *after* the decision was made still drops it (see `disposition`), and any
        /// ordinary `record(_:)` from playback replaces the whole entry with an unflagged
        /// one — so the exemption can't outlive the decision it belongs to.
        let conflictResolved: Bool

        /// Set only for an ebook reading-position entry (`Views/EbookReaderView.swift`,
        /// P-15 follow-up) — the PDF page index last written, as the string form
        /// `AudiobookshelfAPI.updateEbookProgress(itemId:location:progress:)` expects for
        /// `ebookLocation`. `nil` for every ordinary audio entry, and always non-nil
        /// together with `ebookProgress` on an ebook entry (see `isEbook` below).
        ///
        /// Added as an *optional* field specifically so a queue file written before this
        /// pass still decodes: `decodeIfPresent` (see `init(from:)`) is the same pattern
        /// `heldForConflict` established when it was added — a hard `decode` would fail
        /// the whole `[String: Entry]` dictionary and silently discard every queued
        /// offline position on the first launch after the update.
        let ebookLocation: String?

        /// The 0–1 fraction paired with `ebookLocation`, for the same
        /// `updateEbookProgress` call. `nil` for an audio entry.
        let ebookProgress: Double?

        /// True for an ebook reading-position entry, false for an ordinary audio one.
        /// `ebookLocation` is the discriminator (an ebook entry always sets it); computed
        /// rather than a stored `kind` so a legacy on-disk entry — which has neither field
        /// — decodes unambiguously as audio with no extra default to keep in sync.
        var isEbook: Bool { ebookLocation != nil }

        enum CodingKeys: String, CodingKey {
            case scope, itemId, currentTime, duration, updatedAt, heldForConflict, conflictResolved
            case ebookLocation, ebookProgress
        }

        init(
            scope: String, itemId: String, currentTime: Double, duration: Double,
            updatedAt: Double, heldForConflict: Bool = false, conflictResolved: Bool = false,
            ebookLocation: String? = nil, ebookProgress: Double? = nil
        ) {
            self.scope = scope
            self.itemId = itemId
            self.currentTime = currentTime
            self.duration = duration
            self.updatedAt = updatedAt
            self.heldForConflict = heldForConflict
            self.conflictResolved = conflictResolved
            self.ebookLocation = ebookLocation
            self.ebookProgress = ebookProgress
        }

        /// Convenience factory for `EbookReaderView` — an ebook entry has no meaningful
        /// `currentTime`/`duration` (there's nothing to reconcile a PDF page against), so
        /// both are left at 0 rather than asking every call site to invent a value.
        static func ebook(
            scope: String, itemId: String, location: String, progress: Double, updatedAt: Double
        ) -> Entry {
            Entry(scope: scope, itemId: itemId, currentTime: 0, duration: 0, updatedAt: updatedAt,
                  ebookLocation: location, ebookProgress: progress)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scope = try c.decode(String.self, forKey: .scope)
            itemId = try c.decode(String.self, forKey: .itemId)
            currentTime = try c.decode(Double.self, forKey: .currentTime)
            duration = try c.decode(Double.self, forKey: .duration)
            updatedAt = try c.decode(Double.self, forKey: .updatedAt)
            // `decodeIfPresent` rather than `decode`: every entry written before this
            // field was added has no `heldForConflict` key at all, and a hard decode
            // would fail the *whole* dictionary (`[String: Entry]`), silently throwing
            // away every queued offline position on the first launch after an update.
            heldForConflict = try c.decodeIfPresent(Bool.self, forKey: .heldForConflict) ?? false
            conflictResolved = try c.decodeIfPresent(Bool.self, forKey: .conflictResolved) ?? false
            // Same reasoning, same pattern: a queue file written before this pass has
            // neither key, and must still decode as an ordinary (non-ebook) audio entry.
            ebookLocation = try c.decodeIfPresent(String.self, forKey: .ebookLocation)
            ebookProgress = try c.decodeIfPresent(Double.self, forKey: .ebookProgress)
        }

        /// Same entry with the conflict hold flipped. `let`-only struct, so this is a copy
        /// rather than a mutation — the actor swaps it into `entries` under its own
        /// serialization.
        func settingHeld(_ held: Bool) -> Entry {
            Entry(scope: scope, itemId: itemId, currentTime: currentTime, duration: duration,
                  updatedAt: updatedAt, heldForConflict: held, conflictResolved: conflictResolved,
                  ebookLocation: ebookLocation, ebookProgress: ebookProgress)
        }
    }

    /// The server's own view of one item's progress, as `drain(...)` needs it: when the
    /// server last wrote (seconds since epoch, normalised from Audiobookshelf's epoch
    /// milliseconds) and where in the book it thinks the listener is.
    ///
    /// `currentTime` is the field this type was introduced for. The queue used to be
    /// handed timestamps alone, which answers "has the server moved on since we captured
    /// this?" but not "would pushing this drag the book *backwards*?" — the second
    /// question is the one the conflict prompt exists to ask.
    struct ServerPosition: Sendable, Equatable {
        let lastUpdate: Double?
        let currentTime: Double?

        init(lastUpdate: Double?, currentTime: Double?) {
            self.lastUpdate = lastUpdate
            self.currentTime = currentTime
        }
    }

    /// What `drain(...)` should do with one queued entry, given what the server reports
    /// for the same item.
    enum EntryDisposition: Equatable, Sendable {
        /// Safe to push to the server, and to remove once that push succeeds.
        case push
        /// Beyond-threshold *behind* the server — hold it back until the "Progress Doesn't
        /// Match" prompt has been resolved (see `Entry.heldForConflict`).
        case hold
        /// The server has written a strictly newer position than this entry; ours is
        /// stale and pushing it would clobber real listening from another device.
        case drop
    }

    /// The push / hold / drop decision for one queued entry — pure, `nonisolated` and
    /// unit-tested (`PendingProgressQueueTests`), per this project's convention of pinning
    /// the decision rather than the I/O around it.
    ///
    /// Order matters. The staleness test comes first and is unchanged from the original
    /// inline rule (`serverTime > entry.updatedAt + 1`, the 1s slack absorbing clock and
    /// round-trip jitter): a server that wrote *later* than we captured has genuinely moved
    /// on, whether it moved forwards or backwards, and its copy wins.
    ///
    /// Only then does the position gap matter. Everything reaching that point was written
    /// no later than our capture, so a server position more than `conflictThreshold`
    /// **ahead** of ours is the "local newer but behind" shape
    /// `ProgressReconciler.isUnexplainedDivergence` singles out: both sides hold a real
    /// position, and pushing ours would move the book backwards by more than the threshold.
    /// That is precisely what `DownloadManager.reconcile` refuses to auto-resolve, so the
    /// flush must refuse it too — otherwise the queue quietly wins the argument before the
    /// user is ever asked.
    ///
    /// The comparison is deliberately one-sided: local *ahead* of the server by any amount
    /// is ordinary offline listening and pushes normally.
    ///
    /// **`entryConflictResolved` short-circuits the hold, and only the hold.** The rule,
    /// stated explicitly because the two halves pull in opposite directions:
    ///   - The user (or `ProgressReconciler`, with `serverIsFinished` in hand) decided this
    ///     divergence at `entryUpdatedAt`, having been shown the server position as it
    ///     stood then. A server timestamp *older* than that was already part of what they
    ///     were deciding about, so the gap must not veto the decision — push.
    ///   - A server write *later* than `entryUpdatedAt` is new information the decision
    ///     never covered: someone listened elsewhere after the choice was made. Last write
    ///     wins, exactly as for any other entry — drop. That's why the staleness test stays
    ///     ahead of this exemption rather than being skipped along with the hold.
    nonisolated static func disposition(
        entryCurrentTime: Double,
        entryUpdatedAt: Double,
        entryConflictResolved: Bool = false,
        server: ServerPosition?,
        conflictThreshold: Double
    ) -> EntryDisposition {
        guard let server else { return .push }
        if let serverLastUpdate = server.lastUpdate, serverLastUpdate > entryUpdatedAt + 1 {
            return .drop
        }
        // An already-answered divergence is not re-litigated on position alone.
        guard !entryConflictResolved else { return .push }
        // A progress record with no `currentTime` tells us nothing about *where* the
        // server is, so there is no gap to measure and no reason to hold.
        guard let serverCurrentTime = server.currentTime else { return .push }
        if serverCurrentTime - entryCurrentTime > conflictThreshold { return .hold }
        return .push
    }

    /// Review Medium 15: whether an entry may be held for the conflict prompt. Only
    /// downloaded books get that prompt; `nil` means "unknown", which keeps every item
    /// holdable (the pre-fix behaviour).
    nonisolated static func mayHold(itemId: String, downloadedItemIds: Set<String>?) -> Bool {
        guard let downloadedItemIds else { return true }
        return downloadedItemIds.contains(itemId)
    }

    /// Keyed by `storageKey(scope:itemId:isEbook:)`: `"scope|itemId"` for an audio entry,
    /// `"scope|itemId|ebook"` for an ebook one. So the same item id under two different
    /// scopes (two accounts, or the same account on two servers) never collides — and, as
    /// of this pass, neither do an audio and an ebook entry for the *same* item/scope.
    ///
    /// Before this, a library item with both an audio version being listened to and an
    /// ebook file being read at the same time, offline, in the same window, had its audio
    /// position and its ebook page compete for one `"scope|itemId"` slot — whichever
    /// `record(_:)` call landed last silently won, same as any other same-key write, with
    /// no error and no way to recover the loser.
    ///
    /// Audio deliberately keeps the un-suffixed key rather than both kinds moving to a new
    /// scheme: every entry any previous build ever wrote was audio, so it already sits at
    /// the key this scheme still uses for audio, and needs no migration. An ebook entry
    /// written by a build before this pass, though, was filed under that same *audio* key
    /// (the only key that existed at the time) — left alone, it would sit at the wrong key
    /// forever, invisible to any `clear(isEbook: true)` call and to `count`/`drain` reading
    /// it back as an (incorrectly-shaped) audio entry. `loadFromDiskIfNeeded()` runs every
    /// freshly decoded dictionary through `rekeyed(_:)` — pure, `nonisolated`, and unit-
    /// tested (`PendingEbookProgressTests`) rather than inline — which re-files each entry
    /// under its own canonical `storageKey(scope:itemId:isEbook:)`. An audio entry's
    /// canonical key is the key it's already at, so this is a no-op for every entry any
    /// build has ever written except a pre-this-pass ebook one, which moves onto its
    /// `"|ebook"` key on the very first load after the update. The very next `persist()`
    /// writes the migrated (canonical) keys back to disk, so the rekey only ever runs once
    /// per file.
    private var entries: [String: Entry] = [:]
    private var hasLoadedFromDisk = false
    private let fileURL: URL

    /// `Application Support/PendingProgress/queue.json` by default — a real file rather
    /// than `UserDefaults`, per the review's persistence audit (§9): this structure is
    /// mutated far more often than it's read, and `UserDefaults` round-trips its entire
    /// property-list blob on every single `set`, which is the wrong storage for something
    /// this hot even though any one entry is tiny.
    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingProgress", isDirectory: true)
        return dir.appendingPathComponent("queue.json")
    }

    /// `fileURL` is an initializer parameter (not hardcoded) purely so tests can point a
    /// fresh instance at a scratch location instead of the app's real queue file.
    init(fileURL: URL = PendingProgressQueue.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// The canonical on-disk/in-memory key for one entry. `isEbook` is a parameter rather
    /// than read off an `Entry` here so `rekeyed(_:)` (below) can compute the key a decoded
    /// entry *should* be at without first having to look up whatever key it was decoded
    /// under.
    private static func storageKey(scope: String, itemId: String, isEbook: Bool) -> String {
        isEbook ? "\(scope)|\(itemId)|ebook" : "\(scope)|\(itemId)"
    }

    /// Re-files a decoded on-disk dictionary so every entry sits under its own canonical
    /// `storageKey(scope:itemId:isEbook:)` — the one-time migration `loadFromDiskIfNeeded()`
    /// needs for a queue file written before the key started discriminating audio vs. ebook
    /// (see the doc comment on `entries` above). An audio entry's canonical key is the key
    /// it's already stored under, so this is a no-op for it; only a legacy ebook entry
    /// (filed under the audio key, since that was the only key that existed) actually
    /// moves. Pure and `nonisolated` specifically so it's unit-testable
    /// (`PendingEbookProgressTests`) without standing up a real file or actor.
    ///
    /// On a same-canonical-key collision — two decoded entries whose `scope`/`itemId`/
    /// `isEbook` all agree, which in practice only a hand-edited or manually merged file
    /// could produce — keeps the one with the newer `updatedAt`, the same tie-break
    /// `record(_:)` applies between two writes for the same item.
    nonisolated static func rekeyed(_ decoded: [String: Entry]) -> [String: Entry] {
        var result: [String: Entry] = [:]
        result.reserveCapacity(decoded.count)
        for entry in decoded.values {
            let canonicalKey = storageKey(scope: entry.scope, itemId: entry.itemId, isEbook: entry.isEbook)
            if let existing = result[canonicalKey], existing.updatedAt > entry.updatedAt {
                continue
            }
            result[canonicalKey] = entry
        }
        return result
    }

    /// Loads the queue file at most once per *conclusive* read.
    ///
    /// The flag used to be set on the line above the read, with both the read and the
    /// decode `try?`-swallowed — so an unreadable or corrupt file loaded as an empty queue
    /// and the very next `persist()` wrote that emptiness back over it, losing every
    /// unsynced listening position permanently. `PersistedStoreLoad` (bottom of
    /// `PendingBookmarkQueue.swift`) tells the three cases apart; see its doc comment for
    /// why it lives there and what each outcome means. A file we could not read leaves the
    /// flag false, which both blocks `persist()` from overwriting it and lets the next
    /// access retry (protected data becoming available after first unlock is the realistic
    /// case on iOS, and this queue is written from playback that can start before it).
    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        let outcome: PersistedStoreLoad.Outcome<[String: Entry]> = PersistedStoreLoad.load(
            fileURL: fileURL, label: "PendingProgressQueue"
        ) { try JSONDecoder().decode([String: Entry].self, from: $0) }

        switch outcome {
        case .loaded(let decoded):
            // `rekeyed(_:)` first: moves any legacy ebook entry (filed under the audio key
            // by a build before this pass) onto its own canonical key. A no-op for every
            // audio entry and every already-canonical ebook entry — see the doc comment on
            // `entries` and on `rekeyed(_:)` itself.
            let migrated = Self.rekeyed(decoded)
            // In-memory wins on a key collision. Normally `entries` is empty here and this
            // is plain assignment; it differs only on a retry after an unreadable read, and
            // there anything already in `entries` is a position captured *after* the file
            // was last written, so it is the newer of the two — which is also the rule
            // `record(_:)` applies between two queued positions for the same item.
            entries = migrated.merging(entries) { _, inMemory in inMemory }
            hasLoadedFromDisk = true
        case .empty:
            // Nothing on disk, or the unreadable bytes are now quarantined as
            // `queue.json.corrupt`. Whatever is already in `entries` (again, only
            // non-empty on a retry) stands.
            hasLoadedFromDisk = true
        case .unavailable:
            break
        }
    }

    private func persist() {
        // Refusing to write is the entire fix: a queue file whose contents we never
        // established must be left exactly as it is rather than replaced with whatever
        // this process happens to be holding.
        guard hasLoadedFromDisk else {
            ShelfLog.error(.storage, "PendingProgressQueue: skipping persist — the queue file has not been read yet, writing now would destroy it")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records (or overwrites) the queued position for `entry.scope`/`entry.itemId`.
    ///
    /// NEW-8 (follow-up review, 14 Aug 2026): the doc comment here used to claim
    /// `entry.updatedAt` is always the newest observation "by construction, since
    /// the caller just captured it synchronously" — true for any single call site
    /// in isolation, but not across two independent call sites racing each other.
    /// At end of book, `AudioPlayerService.moveToNextTrack()` runs `syncProgress()`
    /// (captures `updatedAt = T1`) and `recordFinishedProgress()` (captures
    /// `updatedAt = T2 > T1`, `currentTime = duration`) as two separate tasks with
    /// no ordering guarantee on the shared executor — if T1's `record(_:)` call
    /// happens to land AFTER T2's, it silently overwrote the finished entry with
    /// the earlier, pre-finish position. Guarded the same way `clear(ifNotNewerThan:)`
    /// already guards against the equivalent race in the other direction: an
    /// incoming entry only wins if there's nothing queued yet, or what's queued is
    /// no newer than it.
    func record(_ entry: Entry) {
        loadFromDiskIfNeeded()
        let key = Self.storageKey(scope: entry.scope, itemId: entry.itemId, isEbook: entry.isEbook)
        // P3-8 (third-pass review, 14 Aug 2026): NEW-8's guard above closed the
        // end-of-book clobber race, but `updatedAt` is `Date().timeIntervalSince1970` —
        // wall-clock, not monotonic. If the device clock regresses between the two
        // racing calls (NTP correcting a post-dead-battery boot clock, a manual date
        // change), `existing.updatedAt <= entry.updatedAt` can read false even though
        // `entry` is the genuinely newer observation, and every subsequent `record` for
        // that item is then silently dropped until it flushes or ages out after 30 days
        // — offline listening lost with no error, the exact class of failure ARCH-3
        // exists to prevent. Relaxed to also accept an entry whose `currentTime` has
        // actually advanced, which still closes the original NEW-8 race (the
        // pre-finish position's `currentTime` is always < the finished position's
        // `duration`) without depending on the clock agreeing with itself.
        //
        // Ebook follow-up: `key` now encodes `isEbook` (see `storageKey(...)`), so
        // `entries[key]`, when present, is always the same kind as `entry` — audio can no
        // longer collide with ebook at a shared key the way it could before this pass.
        // What's still true, and still needs its own branch, is that an ebook entry's
        // `currentTime` is always 0 (there's no position to compare — see
        // `Entry.ebook(...)`), so the `currentTime` escape hatch below would let an older
        // ebook write always win ties against a newer one (`0 >= 0`). An ebook entry falls
        // back to `updatedAt` alone — plain newest-wall-clock-write-wins dedupe, which is
        // what "the same way audio entries do" means once there's no position to fall
        // back on.
        guard entries[key].map({ existing in
            if entry.isEbook {
                return existing.updatedAt <= entry.updatedAt
            }
            return existing.updatedAt <= entry.updatedAt || entry.currentTime >= existing.currentTime
        }) ?? true else { return }
        entries[key] = entry
        persist()
    }

    /// Removes the entry for `scope`/`itemId` **only if** it hasn't been superseded by a
    /// newer `record` since the caller captured `ifNotNewerThan` (the `updatedAt` of the
    /// write that just succeeded, or of the drained entry a flush just pushed). This is
    /// the missing guard described in the type's doc comment: without it, a flush's own
    /// success can delete a newer position that raced in while the network call was still
    /// in flight, silently discarding real listening time.
    ///
    /// `isEbook` defaults to `false` so every existing (audio) call site keeps compiling
    /// and clearing the same key it always did. The one ebook flush site
    /// (`AudioPlayerService.flushPendingProgress`, the `entry.isEbook` branch) must pass
    /// `isEbook: true` — otherwise it would clear at the *audio* key for this item/scope,
    /// which is either nothing (silent no-op, the entry it just pushed stays queued
    /// forever) or, worse, an unrelated in-flight audio position for the same item, which
    /// this call has no business deleting. A successful push of one kind must never clear
    /// the other kind's entry.
    func clear(itemId: String, scope: String, isEbook: Bool = false, ifNotNewerThan: Double) {
        loadFromDiskIfNeeded()
        let key = Self.storageKey(scope: scope, itemId: itemId, isEbook: isEbook)
        guard let existing = entries[key], existing.updatedAt <= ifNotNewerThan else { return }
        entries.removeValue(forKey: key)
        persist()
    }

    /// Review Medium 15 (30 October 2026): removes the audio entry for an item outright.
    /// "Use Server" in the "Progress Doesn't Match" prompt adopts the server's position, so
    /// the offline entry held back for that same prompt has been answered and must not stay
    /// behind (it would sit in the held count forever, or be pushed later over the choice).
    /// Unconditional on purpose: the user's answer covers whatever is queued for the item.
    func discardAudioEntry(itemId: String, scope: String) {
        loadFromDiskIfNeeded()
        let key = Self.storageKey(scope: scope, itemId: itemId, isEbook: false)
        guard entries.removeValue(forKey: key) != nil else { return }
        persist()
    }

    /// Returns everything currently queued for `activeScope` that is actually safe to
    /// push, for `flushPendingProgress` to attempt sending to the server. While it has the
    /// queue open it also applies `disposition(...)` to each of this scope's entries and
    /// sweeps dead weight across *every* scope:
    ///
    /// - `.drop` — the server reports it has already moved past this entry; flushing it
    ///   would clobber a genuinely newer position written from another device.
    /// - `.hold` — the entry sits more than `conflictThreshold` *behind* the server. Not
    ///   returned (pushing it would answer the "Progress Doesn't Match" question on the
    ///   user's behalf) and not deleted (their offline listening is still real). Flagged
    ///   `heldForConflict`, which also keeps it out of `count(forScope:)` and out of the
    ///   age sweep below.
    /// - `.push` — returned, with any stale hold flag from an earlier pass cleared.
    ///
    /// Entries stale enough (`maxAge`) are evicted regardless of scope — without this, one
    /// belonging to a permanently signed-out or removed account would sit here forever,
    /// since it can never again match an `activeScope`.
    ///
    /// `conflictThreshold` is passed in rather than read from `DownloadManager` here so
    /// this stays a self-contained, testable actor with no main-actor dependency; the one
    /// production call site hands it `DownloadManager.conflictThreshold`, the same
    /// constant `reconcile` measures a conflict with.
    func drain(
        activeScope: String,
        serverProgress: [String: ServerPosition],
        conflictThreshold: Double,
        downloadedItemIds: Set<String>? = nil,
        maxAge: TimeInterval = 30 * 24 * 3600
    ) -> [Entry] {
        loadFromDiskIfNeeded()
        let now = Date().timeIntervalSince1970
        var changed = false
        var result: [Entry] = []
        for (key, entry) in entries {
            // `serverProgress` describes the **active** account only, so an entry belonging
            // to some other scope gets nothing but the age sweep — exactly as before. It
            // can never match an `activeScope` again if that account was signed out, which
            // is the whole reason the sweep isn't scoped.
            guard entry.scope == activeScope else {
                if now - entry.updatedAt > maxAge {
                    entries.removeValue(forKey: key)
                    changed = true
                }
                continue
            }
            // Ebook entries bypass `disposition(...)` entirely: that decision exists to
            // ask "would pushing this drag the *audio* position backwards past the
            // server's own?", measured via `currentTime`/`conflictThreshold`. An ebook
            // entry's `currentTime` is always 0 (see `Entry.ebook(...)`) — there is no
            // position to reconcile and no "Progress Doesn't Match" prompt for reading
            // location, so holding it back would only ever wait on nothing. Same age
            // sweep as any other entry; otherwise always safe to push (the server-side
            // write is a plain overwrite, last-write-wins, same as `updateEbookProgress`
            // already documents).
            if entry.isEbook {
                if now - entry.updatedAt > maxAge {
                    entries.removeValue(forKey: key)
                    changed = true
                } else {
                    result.append(entry)
                }
                continue
            }
            // Review Medium 15 (30 October 2026): the "Progress Doesn't Match" prompt only
            // exists for downloaded books (`DownloadManager.reconcile`), so a held entry for
            // a streamed book waited on a prompt that never comes and the rewind was lost.
            // Pass `downloadedItemIds` to restrict holding to downloaded books; nil keeps the
            // old behaviour (every item may be held).
            var disp = Self.disposition(
                entryCurrentTime: entry.currentTime, entryUpdatedAt: entry.updatedAt,
                entryConflictResolved: entry.conflictResolved,
                server: serverProgress[entry.itemId], conflictThreshold: conflictThreshold
            )
            if disp == .hold, !Self.mayHold(itemId: entry.itemId, downloadedItemIds: downloadedItemIds) {
                disp = .push
            }
            switch disp {
            case .drop:
                entries.removeValue(forKey: key)
                changed = true
                ShelfLog.info(.sync, "Skipped stale offline progress (server newer) for \(ShelfLog.redact(entry.itemId))")
            case .hold:
                // Held back, and deliberately NOT age-evicted while it is: the 30-day
                // sweep exists for entries that can never match again, and this one is
                // waiting on an answer, not rotting. Age eviction resumes the moment the
                // hold lifts (`.push` below) or the account is switched away from (the
                // other-scope branch above), so this can't pin an entry forever across a
                // sign-out.
                if !entry.heldForConflict {
                    entries[key] = entry.settingHeld(true)
                    changed = true
                    ShelfLog.info(.sync, "Holding queued progress behind the server's position for \(ShelfLog.redact(entry.itemId)) — waiting on the progress-conflict prompt")
                }
            case .push:
                // Recomputed from this pass's server position, so a hold set on an earlier
                // pass clears itself once the conflict is resolved either way — no
                // explicit release call from `DownloadManager` required.
                var current = entry
                if entry.heldForConflict {
                    current = entry.settingHeld(false)
                    entries[key] = current
                    changed = true
                }
                if now - current.updatedAt > maxAge {
                    entries.removeValue(forKey: key)
                    changed = true
                    continue
                }
                result.append(current)
            }
        }
        if changed { persist() }
        return result
    }

    /// Test-only accessor for the current on-disk-backed contents, keyed the same way as
    /// storage. Not gated behind `#if DEBUG`/`private` beyond normal `internal` visibility,
    /// matching this codebase's existing pattern of loosening just enough for
    /// `@testable import` rather than adding conditional-compilation seams.
    func allEntries() -> [String: Entry] {
        loadFromDiskIfNeeded()
        return entries
    }

    /// Polish pass Phase 2a #3: the queued audio position for one book, read without
    /// evicting anything, so starting playback can take a newer unsent position into
    /// account instead of letting the server's older one supersede (and drop) it.
    func audioEntry(itemId: String, scope: String) -> Entry? {
        loadFromDiskIfNeeded()
        return entries[Self.storageKey(scope: scope, itemId: itemId, isEbook: false)]
    }

    /// Design review (14 Aug 2026), item 2 — "nothing tells the user whether their
    /// position is saved": a read-only count for `activeScope`, so the UI can surface
    /// "N positions waiting to sync" without going through `drain(...)`, which mutates
    /// the queue (evicts stale/superseded entries) and is meant to be called once per
    /// actual flush attempt, not on every render. Doesn't evict anything itself — a
    /// stale entry just sits in the count until the next real `drain` call cleans it up,
    /// which is fine for a number that only needs to be roughly right.
    func count(forScope activeScope: String) -> Int {
        loadFromDiskIfNeeded()
        // Entries held back pending the "Progress Doesn't Match" prompt are excluded:
        // they are not waiting on the network, they're waiting on the user, and counting
        // them as "N positions waiting to sync" would show a number that never falls no
        // matter how good the connection gets.
        return entries.values.filter { $0.scope == activeScope && !$0.heldForConflict }.count
    }

    /// Entries in `activeScope` currently held back by `drain(...)` because they sit more
    /// than the conflict threshold behind the server. Separate from `count(forScope:)` so
    /// a diagnostics surface can tell "waiting on the network" apart from "waiting on you"
    /// without either number double-counting the other.
    func heldForConflictCount(forScope activeScope: String) -> Int {
        loadFromDiskIfNeeded()
        return entries.values.filter { $0.scope == activeScope && $0.heldForConflict }.count
    }

    /// Items in `activeScope` whose divergence has already been decided and whose push is
    /// merely queued for retry (`Entry.conflictResolved`).
    ///
    /// `DownloadManager.reconcile` reads this once per pass so it doesn't re-raise the
    /// "Progress Doesn't Match" prompt for a book the user has already answered: until the
    /// queued push lands, the manifest and the server still disagree by exactly the amount
    /// that first raised it, so the reconciler would otherwise ask the same question again
    /// on the very next library refresh.
    ///
    /// Explicitly excludes ebook entries (`!$0.isEbook`), even though nothing currently
    /// constructs an ebook entry with `conflictResolved: true` — `Entry.ebook(...)`, the
    /// only factory `EbookReaderView` uses, doesn't expose that parameter. Stated
    /// explicitly rather than left to that accident of the call graph: there is no
    /// "Progress Doesn't Match" prompt for a reading position (`drain(...)` never holds an
    /// ebook entry — see its own doc comment), so an ebook entry has nothing for this set
    /// to be suppressing a prompt about, and a future direct `Entry(...)` construction that
    /// happened to set both flags must not silently start suppressing one.
    func resolvedConflictItemIds(forScope activeScope: String) -> Set<String> {
        loadFromDiskIfNeeded()
        return Set(entries.values
            .filter { $0.scope == activeScope && $0.conflictResolved && !$0.isEbook }
            .map(\.itemId))
    }
}
