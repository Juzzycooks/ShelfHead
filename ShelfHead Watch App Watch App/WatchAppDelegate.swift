// `@preconcurrency` for the same reason `WatchConnectivityStore.swift` uses it on
// `WatchConnectivity`: `WKRefreshBackgroundTask` and its subclasses predate Swift's
// concurrency checking (`WKBackgroundTask.h` carries no `NS_SWIFT_UI_ACTOR`, unlike
// `WKApplicationDelegate` itself), so a task object handed to us here isn't `Sendable`
// even though every delivery is on the main thread.
@preconcurrency import WatchKit

/// The Watch app's `WKApplicationDelegate` — added 9 September 2026 for the review's
/// HIGH "background download session has no `WKURLSessionRefreshBackgroundTask`
/// handler."
///
/// **What was broken:** `WatchLocalDownloadManager` creates a background
/// `URLSessionConfiguration` with `sessionSendsLaunchEvents = true`, which is a
/// promise to the system that this app will handle being relaunched in the background
/// when its transfers finish. Nothing implemented `handle(_:)`, and there was no
/// `@WKApplicationDelegateAdaptor` at all, so watchOS had nowhere to deliver the
/// launch event: a download that completed while the app wasn't running left the
/// moved-into-place file with no manifest written, no completion haptic, and no
/// state update until the user next opened the app (and, because the relaunch's
/// background task was never completed, watchOS counts it against this app's
/// background budget).
///
/// **Ownership rule:** this type recognises the event and hands the session
/// identifier to `WatchLocalDownloadManager`; it never touches downloads itself.
/// Same split as `WatchConnectivityStore.apply(context:)`'s `"wipeCredentials"`
/// branch — the delegate knows *that* something happened, the owner knows *what to
/// do*.
///
/// **[device check]**: written without a watchOS device/simulator available. The
/// relaunch path (kill the app, let a download finish, confirm the manifest and
/// haptic land without reopening) can only be confirmed on real hardware.
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    func applicationDidFinishLaunching() {
        // One process-wide registration of the `MPRemoteCommandCenter` handlers, for
        // whichever mode is active at the moment a command arrives — see
        // `WatchRemoteCommandRouter`'s own doc comment for the ownership rule this
        // replaces (both stores used to register their own targets at init).
        WatchRemoteCommandRouter.shared.activate()
        // Trim the standalone cover cache if it's grown past the Watch's cap. A directory
        // walk, so off-main and low-priority, as on the phone (`ShelfHeadApp`).
        Task.detached(priority: .utility) {
            DiskCoverCache.evictIfNeeded(limitBytes: WatchCoverLoader.diskCacheLimitBytes)
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let urlTask = task as? WKURLSessionRefreshBackgroundTask else {
                // Every other kind (app refresh, snapshot, WatchConnectivity, …) is
                // completed immediately rather than held: this app schedules none of
                // them, and an un-completed background task is charged against the
                // app's background budget whether or not it was asked for.
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            let identifier = urlTask.sessionIdentifier
            WatchLocalDownloadManager.shared.handleBackgroundSessionEvents(identifier: identifier) {
                // Held open until `urlSessionDidFinishEvents(forBackgroundURLSession:)`
                // fires (or the manager's own watchdog gives up), so the process isn't
                // suspended midway through moving files and writing the manifest.
                // `false`: nothing this handler does changes the complication/snapshot,
                // so asking for a snapshot refresh here would be wasted work.
                urlTask.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
