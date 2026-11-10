import Foundation
import UserNotifications

// MARK: - Settings

extension SettingsKeys {
    /// Batch 454: recommendation ids this device has dismissed (delete for me only), and ids already notified.
    static let householdDismissedRecommendations = "settings_householdDismissedRecs"
    static let householdNotifiedRecommendations = "settings_householdNotifiedRecs"
}

// MARK: - Pure rules

/// Batch 454: what is in your recommendation inbox, and which arrivals deserve a notification.
/// Pure; pinned by `HouseholdSocialTests`.
nonisolated enum HouseholdInboxLogic {
    /// Recommendations to `myMemberId` from someone else, not dismissed on this device, newest first.
    static func inbox(snapshot: HouseholdSnapshot, myMemberId: String?, dismissed: Set<String>) -> [HouseholdRecommendation] {
        guard let myMemberId else { return [] }
        return snapshot.recommendations(for: myMemberId)
            .filter { $0.fromMemberId != myMemberId && !dismissed.contains($0.id) }
    }

    /// Drops dismissed ids whose recommendation no longer exists, so the set can't grow forever.
    static func pruned(_ dismissed: Set<String>, existing: Set<String>) -> Set<String> {
        dismissed.intersection(existing)
    }

    /// Recommendations to me that weren't in the snapshot before this fetch, haven't been notified, and are
    /// recent (so joining a household doesn't announce its whole history).
    static func newArrivals(snapshot: HouseholdSnapshot, myMemberId: String?, knownBefore: Set<String>,
                            notified: Set<String>, now: Date, maxAge: TimeInterval = 24 * 3600) -> [HouseholdRecommendation] {
        guard let myMemberId else { return [] }
        return snapshot.recommendations(for: myMemberId).filter {
            $0.fromMemberId != myMemberId
                && !knownBefore.contains($0.id)
                && !notified.contains($0.id)
                && now.timeIntervalSince($0.createdAt) <= maxAge
        }
    }
}

// MARK: - Dismissed set (local)

/// Batch 454: the inbox's local state. Swipe-to-dismiss only hides a recommendation on this device; the
/// record stays for the sender and for other devices.
@MainActor
@Observable
final class HouseholdInbox {
    static let shared = HouseholdInbox()

    private(set) var dismissed: Set<String>

    @ObservationIgnored private var notified: Set<String>

    private init() {
        let defaults = UserDefaults.standard
        dismissed = Set(defaults.stringArray(forKey: SettingsKeys.householdDismissedRecommendations) ?? [])
        notified = Set(defaults.stringArray(forKey: SettingsKeys.householdNotifiedRecommendations) ?? [])
    }

    /// The inbox as the Household page and the Home shelf show it.
    var items: [HouseholdRecommendation] {
        let store = HouseholdStore.shared
        return HouseholdInboxLogic.inbox(snapshot: store.snapshot, myMemberId: store.myMemberId, dismissed: dismissed)
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        UserDefaults.standard.set(Array(dismissed), forKey: SettingsKeys.householdDismissedRecommendations)
    }

    /// Called by `HouseholdStore.fetchedRecords` after it merges server changes.
    func handleFetched(snapshot: HouseholdSnapshot, myMemberId: String?, knownBefore: Set<String>) {
        let pruned = HouseholdInboxLogic.pruned(dismissed, existing: Set(snapshot.recommendations.keys))
        if pruned != dismissed {
            dismissed = pruned
            UserDefaults.standard.set(Array(pruned), forKey: SettingsKeys.householdDismissedRecommendations)
        }
        // Batch 481: the notified set is pruned the same way, so it can't grow forever either.
        let prunedNotified = HouseholdInboxLogic.pruned(notified, existing: Set(snapshot.recommendations.keys))
        if prunedNotified != notified {
            notified = prunedNotified
            UserDefaults.standard.set(Array(prunedNotified), forKey: SettingsKeys.householdNotifiedRecommendations)
        }
        let arrivals = HouseholdInboxLogic.newArrivals(snapshot: snapshot, myMemberId: myMemberId,
                                                       knownBefore: knownBefore, notified: notified, now: Date())
        guard !arrivals.isEmpty else { return }
        // Remember them first: enabling notifications later must not announce old arrivals.
        notified.formUnion(arrivals.map(\.id))
        UserDefaults.standard.set(Array(notified), forKey: SettingsKeys.householdNotifiedRecommendations)
        HouseholdNotifier.notify(arrivals, members: snapshot.members)
    }
}

// MARK: - Local notification

/// Batch 454: a local notification when a recommendation arrives. Only if notifications are already
/// authorised: this never asks for permission (the daily reminder and download-complete settings own that).
@MainActor
enum HouseholdNotifier {
    static func notify(_ recommendations: [HouseholdRecommendation], members: [String: HouseholdMember]) {
        Task {
            guard await NotificationManager.isAuthorized() else { return }
            for rec in recommendations {
                let sender = members[rec.fromMemberId]?.displayName ?? String(localized: "Someone", comment: "Household: stands in for a member's name")
                let content = UNMutableNotificationContent()
                content.title = String(localized: "New recommendation", comment: "Household notification title")
                content.body = String(localized: "\(sender) recommends \(rec.title).",
                                      comment: "Household notification body. First %@ is a member's name, second is a book title.")
                content.sound = .default
                let request = UNNotificationRequest(identifier: "shelfhead.household.rec.\(rec.id)",
                                                    content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
}
