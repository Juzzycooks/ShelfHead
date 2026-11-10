import Foundation
import Observation

/// The one place bookmark mutations go through, so "try the server, keep it if that fails"
/// exists once instead of being re-decided (or, as it was, silently skipped) at each of the
/// eight `try? await ...Bookmark(...)` call sites.
///
/// Mirrors how `AudioPlayerService` owns progress sync: attempt the write, queue it in
/// `PendingBookmarkQueue` if the attempt fails, and replay the queue when connectivity
/// comes back. Callers get a `Bool` back — `true` when the server has it, `false` when it
/// is safely queued — so a screen can say "saved, will sync" rather than either lying or
/// showing an error for something that isn't lost.
///
/// Reads are not routed through here on purpose: `AudiobookshelfAPI.getBookmarks`/
/// `getAllBookmarks` fold the queue in themselves, so all seven existing read sites (the
/// player, book detail, All Bookmarks, CarPlay, the Watch bridge) show pending work with no
/// change at the call site and no risk of one of them being forgotten.
@MainActor
@Observable
final class BookmarkSyncService {

    /// Plain `static let shared` / `private init()`, both inheriting `@MainActor` — **not**
    /// the `nonisolated` pair `AudioPlayerService`/`DownloadManager` use. Those two need it
    /// because they have genuine background callers (`URLSessionDelegate`,
    /// `NotificationCenter`); this type is only ever reached from main-actor contexts, and
    /// `ThemeStore`/`FavoritesStore` both document the `nonisolated` pattern as a real
    /// build-error trap for an `@Observable` type when there's no such caller to justify it.
    static let shared = BookmarkSyncService()

    /// Queued bookmark operations for the active account, for the diagnostics screen —
    /// the counterpart to `AudioPlayerService.pendingProgressCount`.
    var pendingCount: Int = 0

    /// Guards against two flushes running at once (connectivity restored while a launch
    /// flush is still in flight), which would replay the same entries twice. Only ever
    /// read and written synchronously on the main actor, before `flush()`'s first
    /// `await` — see that method's doc comment for why that ordering is the fix and not
    /// an incidental detail.
    private var isFlushing = false

    private init() {
        // Replay whatever is queued as soon as the network returns. `NetworkMonitor`
        // supports multiple observers, so this sits alongside `AudioPlayerService`'s own
        // progress flush rather than displacing it. The nested `[weak self]` on the `Task`
        // is deliberate and load-bearing — see the identical hop in `AudioPlayerService`'s
        // initializer for the Swift 6 capture reasoning it exists to satisfy.
        NetworkMonitor.shared.addConnectivityRestoredObserver { [weak self] in
            Task { @MainActor [weak self] in
                await self?.flush()
            }
        }
    }

    // MARK: - Mutations

    /// Create a bookmark. Returns `true` if the server accepted it, `false` if it was
    /// queued for later. Never throws: a queued bookmark is a success from the user's point
    /// of view, and the one outcome this type exists to make impossible is losing it.
    @discardableResult
    func create(itemId: String, time: Double, title: String) async -> Bool {
        await perform(.create, itemId: itemId, time: time, title: title)
    }

    /// Edit an existing bookmark's note.
    @discardableResult
    func update(itemId: String, time: Double, title: String) async -> Bool {
        await perform(.update, itemId: itemId, time: time, title: title)
    }

    /// Delete a bookmark.
    @discardableResult
    func delete(itemId: String, time: Double) async -> Bool {
        await perform(.delete, itemId: itemId, time: time, title: "")
    }

    private func perform(
        _ operation: PendingBookmarkQueue.Operation, itemId: String, time: Double, title: String
    ) async -> Bool {
        // Captured synchronously, before the first `await` — the account must not be able
        // to change out from under an in-flight write and re-scope it. Same rule, same
        // reason, as `PendingProgressQueue.Entry.scope`.
        let scope = PendingBookmarkQueue.currentScope()
        let now = Date().timeIntervalSince1970
        do {
            try await Self.send(operation, itemId: itemId, time: time, title: title, expectedScope: scope)
            // The write can succeed while an older operation for the same bookmark is still
            // queued (made offline, then again once back online) — clear it so a later
            // flush doesn't replay stale text over what just landed.
            await PendingBookmarkQueue.shared.clear(
                itemId: itemId, time: time, scope: scope, ifNotNewerThan: now)
            await refreshPendingCount()
            return true
        } catch {
            await PendingBookmarkQueue.shared.record(.init(
                scope: scope, itemId: itemId, time: time, title: title,
                operation: operation, updatedAt: now))
            await refreshPendingCount()
            ShelfLog.info(.sync, "Queued offline bookmark \(operation.rawValue) for \(ShelfLog.redact(itemId))")
            return false
        }
    }

    /// The single mapping from queued operation to server call, shared by the live path
    /// above and `flush()` below so a replay can never diverge from the original attempt.
    ///
    /// Review 2 Low (Sync) (30 October 2026): the scope is checked again here, immediately
    /// before the call, so the window between the caller's check and the request is as small
    /// as this file can make it, and passed into the API, which checks it again inside the
    /// actor right before it builds the request (`AudiobookshelfAPI.send(expectedScope:)`).
    private static func send(
        _ operation: PendingBookmarkQueue.Operation, itemId: String, time: Double, title: String,
        expectedScope: String
    ) async throws {
        guard scopeIsUnchanged(captured: expectedScope, current: PendingBookmarkQueue.currentScope()) else {
            throw AccountChangedError()
        }
        switch operation {
        case .create:
            try await AudiobookshelfAPI.shared.addBookmark(itemId: itemId, time: time, title: title, expectedScope: expectedScope)
        case .update:
            try await AudiobookshelfAPI.shared.updateBookmark(itemId: itemId, time: time, title: title, expectedScope: expectedScope)
        case .delete:
            try await AudiobookshelfAPI.shared.deleteBookmark(itemId: itemId, time: time, expectedScope: expectedScope)
        }
    }

    // MARK: - Flush

    /// Replays queued operations against the server, oldest first. An entry is only
    /// cleared once its own write has actually succeeded — or has failed in a way that
    /// replaying it again can never fix (see `isTerminalBookmarkSyncError`).
    ///
    /// Fix 9.1 (REVIEW-2026-09-09.md) rewrote two things here:
    ///
    /// - **The single-flight guard now closes before the first `await`.** `isFlushing`
    ///   used to be set *after* `refreshPendingCount()`, so the two callers that fire
    ///   together on foregrounding — the `scenePhase == .active` hook in `ShelfHeadApp`
    ///   and the connectivity-restored observer in `init()` above — both got past
    ///   `guard !isFlushing` while the other was suspended on that first `await`.
    ///   `PendingBookmarkQueue.drain` doesn't remove what it returns (by design: an
    ///   entry only leaves the queue once its write has landed), so both flushes
    ///   replayed the *same* create list and the user got duplicate bookmarks on the
    ///   server. Setting the flag synchronously, before anything suspends, is the whole
    ///   fix: this method is `@MainActor`, so nothing can interleave between the guard
    ///   and the assignment.
    /// - **A permanently-failing entry no longer blocks the ones behind it.** The loop
    ///   used to `break` on any error, which is right for "the connection went away
    ///   again" and badly wrong for a `404`/`403`/`410` — a delete of a bookmark that is
    ///   already gone from the server, or an operation against an item this account
    ///   can't touch, would fail identically forever and strand every later bookmark
    ///   behind it until `drain`'s 30-day `maxAge` finally evicted it. Those are now
    ///   dropped (with a log line) and the loop continues; transport failures, `5xx`
    ///   and a `401` that survived `send`'s own refresh-and-retry still stop the flush,
    ///   because for those the remaining entries really are better off staying queued.
    func flush() async {
        // Set before *any* `await` — see the doc comment above; this ordering is the fix.
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Refreshed before the connectivity guard, not after: this is the only thing that
        // populates `pendingCount` on a cold launch, and a launch with queued bookmarks and
        // still no connection is exactly when the user most needs the count to be right.
        await refreshPendingCount()
        guard NetworkMonitor.shared.isConnected else { return }

        let scope = PendingBookmarkQueue.currentScope()
        let queued = await PendingBookmarkQueue.shared.drain(activeScope: scope)
        guard !queued.isEmpty else {
            await refreshPendingCount()
            return
        }

        for entry in queued {
            // Review Medium 18 (30 October 2026): the account can switch while an earlier
            // send was suspended. Re-checked before every send so a bookmark queued for the
            // old account is never sent to (or 404-deleted on) the new server.
            guard Self.scopeIsUnchanged(captured: scope, current: PendingBookmarkQueue.currentScope()) else {
                ShelfLog.info(.sync, "Bookmark flush stopped: the account changed mid-flush")
                break
            }
            do {
                try await Self.send(
                    entry.operation, itemId: entry.itemId, time: entry.time, title: entry.title,
                    expectedScope: scope)
                // The send above is the suspension point; the entry's own scope is what the
                // clear uses, so it can only ever remove the entry it replayed.
                await PendingBookmarkQueue.shared.clear(
                    itemId: entry.itemId, time: entry.time,
                    scope: entry.scope, ifNotNewerThan: entry.updatedAt)
            } catch let error where Self.isTerminalBookmarkSyncError(error)
                        && Self.scopeIsUnchanged(captured: scope, current: PendingBookmarkQueue.currentScope()) {
                // Unreplayable. Log it — this is the one path that discards something the
                // user asked for, so it must not be silent — and clear it so the entries
                // behind it get their turn. `ifNotNewerThan` still applies: if the user
                // re-made this bookmark while the failing write was in flight, the newer
                // entry survives and is replayed on the next flush.
                ShelfLog.error(
                    .sync,
                    "Dropping unreplayable bookmark \(entry.operation.rawValue) for "
                        + "\(ShelfLog.redact(entry.itemId)): \(error.localizedDescription)")
                await PendingBookmarkQueue.shared.clear(
                    itemId: entry.itemId, time: entry.time,
                    scope: entry.scope, ifNotNewerThan: entry.updatedAt)
            } catch {
                ShelfLog.error(.sync, "Bookmark flush stopped: \(error.localizedDescription)")
                break
            }
        }
        await refreshPendingCount()
    }

    /// Review Medium 18: pure scope comparison for the flush's account-switch guard.
    nonisolated static func scopeIsUnchanged(captured: String, current: String) -> Bool {
        captured == current
    }

    // MARK: - Error classification

    /// The HTTP status behind an error, when it has one. `AudiobookshelfAPI` funnels
    /// every response through `validateStatus`, which turns the status into a specific
    /// `APIError` case rather than carrying the number — so `401`/`403`/`404` arrive as
    /// `.unauthorized`/`.forbidden`/`.notFound` and everything else keeps its number in
    /// `.serverError`/`.httpError`. Mapping back to a number here keeps the actual
    /// policy (`isTerminalBookmarkSyncError(statusCode:)`) expressed in status codes,
    /// which is how the review and the server's own docs talk about it.
    ///
    /// `nil` for a transport error (`URLError`), a decoding error, or anything else with
    /// no status at all — all of which are retryable by definition.
    nonisolated static func bookmarkSyncStatusCode(for error: Error) -> Int? {
        guard let apiError = error as? APIError else { return nil }
        switch apiError {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .serverError(let code): return code
        case .httpError(let code): return code
        case .invalidURL, .invalidResponse, .decodingError: return nil
        }
    }

    /// Whether a status means "replaying this will fail the same way forever", so the
    /// entry should be dropped instead of blocking the queue behind it.
    ///
    /// Terminal:
    /// - `400`/`422` — the server rejected the *shape* of this operation. A replay sends
    ///   the identical body, so it can only be rejected identically.
    /// - `403` — this account isn't allowed to touch this item (a permission change, or
    ///   a library that was un-shared). Not a connection problem, and not one more
    ///   attempts can solve.
    /// - `404`/`410` — the bookmark or item is gone. For a queued `.delete` this is
    ///   arguably a success; for an `.update` there's nothing left to update.
    ///
    /// Deliberately *not* terminal:
    /// - `401` — `AudiobookshelfAPI.send` already refreshes and retries once, so a `401`
    ///   reaching here means the session is dead. The next flush runs after the user has
    ///   re-authenticated, and by then the same write may well succeed.
    /// - `408`/`429` and every `5xx` — explicitly "try again later".
    /// - anything with no status (offline, TLS failure, timeout) — the connection went
    ///   away, which is exactly the case the flush's `break` exists for.
    nonisolated static func isTerminalBookmarkSyncError(statusCode: Int) -> Bool {
        switch statusCode {
        case 400, 403, 404, 410, 422: return true
        default: return false
        }
    }

    /// Convenience over the two above, for the `catch where` clause in `flush()`.
    nonisolated static func isTerminalBookmarkSyncError(_ error: Error) -> Bool {
        guard let status = bookmarkSyncStatusCode(for: error) else { return false }
        return isTerminalBookmarkSyncError(statusCode: status)
    }

    func refreshPendingCount() async {
        pendingCount = await PendingBookmarkQueue.shared.count(forScope: PendingBookmarkQueue.currentScope())
    }
}
