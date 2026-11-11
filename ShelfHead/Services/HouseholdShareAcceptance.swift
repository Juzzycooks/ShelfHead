import UIKit
import CloudKit

/// Batch 453: receives a tapped household invitation. CloudKit hands the metadata to the window scene's
/// delegate (`windowScene(_:userDidAcceptCloudKitShareWith:)`, iOS 13) when the app is running, and in
/// `connectionOptions.cloudKitShareMetadata` when the tap launched it
/// (https://developer.apple.com/documentation/cloudkit/ckshare/metadata). The AppDelegate hands this class
/// to the default window scene configuration (`AppDelegate.application(_:configurationForConnecting:options:)`).
final class HouseholdSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in HouseholdShareAcceptance.receive(metadata) }
        }
        // Batch 490 (REVIEW 2026-11-11 F13): a Home Screen quick action that launched the app
        // arrives here, not in `windowScene(_:performActionFor:completionHandler:)`
        // (https://developer.apple.com/documentation/uikit/uiscene/connectionoptions/shortcutitem).
        // Held until the main tabs are up, then routed like any `shelfhead://` link.
        if let item = connectionOptions.shortcutItem,
           let url = QuickActionRoute.url(forShortcutType: item.type) {
            Task { @MainActor in IncomingLinkInbox.shared.hold(url) }
        }
    }

    /// Batch 490 (REVIEW 2026-11-11 F13): a quick action chosen while the app is already running
    /// (https://developer.apple.com/documentation/uikit/uiwindowscenedelegate/windowscene(_:performactionfor:completionhandler:)).
    /// Goes through the same inbox and deep-link path, so it waits behind App Lock too.
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let url = QuickActionRoute.url(forShortcutType: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        Task { @MainActor in IncomingLinkInbox.shared.hold(url) }
        completionHandler(true)
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in HouseholdShareAcceptance.receive(cloudKitShareMetadata) }
    }
}

/// Holds an invitation until the app may act on it. Joining a household changes what the app stores, so like
/// deep links and Handoff it waits behind App Lock (`PendingUnlockAction`'s reasoning) instead of running over
/// the lock screen. The queue lives here so `PendingUnlockAction` needs no CloudKit type.
extension Notification.Name {
    /// Batch 482: posted when an invitation is being accepted, so the app can show Settings › Household (where
    /// the result, joined or why not, appears).
    static let shelfheadOpenHousehold = Notification.Name("shelfhead.openHousehold")
}

@MainActor
enum HouseholdShareAcceptance {
    /// Non-nil while an invitation waits for the app to unlock.
    private(set) static var pending: CKShare.Metadata?

    static func receive(_ metadata: CKShare.Metadata) {
        if AppLockManager.shared.isLocked {
            pending = metadata
        } else {
            accept(metadata)
        }
    }

    /// Call after unlock (and once at launch after the root view mounts). No-op without a waiting invitation.
    static func acceptPendingIfUnlocked() {
        guard let metadata = pending, !AppLockManager.shared.isLocked else { return }
        pending = nil
        accept(metadata)
    }

    private static func accept(_ metadata: CKShare.Metadata) {
        NotificationCenter.default.post(name: .shelfheadOpenHousehold, object: nil)
        Task { await HouseholdStore.shared.acceptShare(metadata) }
    }
}
