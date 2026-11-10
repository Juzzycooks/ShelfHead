import Foundation

/// The one wrapper every standalone (`WatchAudiobookshelfAPI`) call goes through —
/// added 9 September 2026 for the review's MEDIUM "`.sessionExpired` never reaches
/// `signalSessionExpired()` from the paths users hit."
///
/// **What was broken:** `WatchAPIError.sessionExpired` is raised by
/// `WatchAudiobookshelfAPI.send(...)` for a 401 that survived one refresh attempt —
/// i.e. this Watch's session is genuinely dead and the only way out is a re-handoff
/// or a manual sign-in. `WatchStore.signalSessionExpired()` is what puts the app into
/// the `.sessionExpired` state that offers those, but it was only wired to the two
/// auth-session-management calls (`getAuthSessions`/`revokeAuthSession`), each with
/// its own hand-written `catch`. Every path a user actually hits — browsing the
/// library, paging, searching, starting playback, the periodic session sync, starting
/// a download, pushing queued progress — mapped the same error to a generic
/// "Couldn't reach the server" string and left `authState` at `.active`, so the app
/// kept insisting it was signed in and offered a retry that could never work.
///
/// **Why a free function and not a method on `WatchStore`:** the standalone callers
/// (`WatchStandaloneLibraryStore`, `StandaloneAudioEngine`, `WatchLocalDownloadManager`,
/// `WatchProgressSyncCoordinator`) hold `api` directly and are *constructed by*
/// `WatchStore`, so routing through an instance method would mean each of them holding
/// a back-reference to their owner. `WatchStore.shared` is read at call time, long
/// after `init`, so there's no initialisation cycle.
///
/// Deliberately **not** applied to `WatchCoverLoader`: a single cover request failing
/// with a 401 (an image URL a proxy handles differently, say) shouldn't be able to
/// sign the user out, and a cover failure has a harmless fallback (the placeholder)
/// that a library page or a playback session does not.
@MainActor
enum WatchStandaloneCall {

    /// Runs `operation`, and — if it fails with `WatchAPIError.sessionExpired` — raises
    /// the session-expired flag before rethrowing untouched. Every existing caller's
    /// own error handling keeps working exactly as it did; the only change is that the
    /// app now also *knows* the session is gone.
    static func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        do {
            return try await operation()
        } catch {
            // Pattern-match rather than `catch WatchAPIError.sessionExpired`: a
            // `rethrows` function may only rethrow the error it caught, not throw a
            // freshly-constructed one, so this shape keeps the signature honest.
            if case WatchAPIError.sessionExpired = error {
                WatchStore.shared.signalSessionExpired()
            }
            throw error
        }
    }
}
