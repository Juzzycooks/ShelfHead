import Foundation
import UserNotifications

/// Thin wrapper over local notifications. Two opt-in uses:
///   • a repeating daily "time to listen" reminder at a user-chosen time, and
///   • a one-shot "download complete" notification.
/// Local notifications need no special entitlement (unlike remote push).
enum NotificationManager {
    static let dailyReminderId = "shelfhead.dailyReminder"

    /// Prompt for permission (no-op if already decided). Returns whether we're authorized.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        if let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) {
            return granted
        }
        return false
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // MARK: - Daily reminder

    static func scheduleDailyReminder(hour: Int, minute: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [dailyReminderId])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to listen", comment: "Daily reminder notification title")
        content.body = String(localized: "Pick up where you left off in ShelfHead.", comment: "Daily reminder notification body")
        content.sound = .default

        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: dailyReminderId, content: content, trigger: trigger))
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [dailyReminderId])
    }

    // MARK: - Download complete

    /// Fire a "download complete" notification if the user enabled it and we're authorized.
    static func notifyDownloadComplete(title: String) {
        guard SettingsStore.notifyDownloadCompleteEnabled else { return }
        Task {
            guard await isAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Download complete", comment: "Download-complete notification title")
            content.body = String(localized: "\(title) is ready for offline listening.", comment: "Download-complete notification body. %@ is the audiobook title.")
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "shelfhead.download.\(UUID().uuidString)",
                content: content,
                trigger: nil   // deliver now
            )
            // In an async context the `add(_:)` async-throwing overload is chosen.
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Release radar (Batch 442)

    static func releaseReminderId(asin: String) -> String { "shelfhead.releaseRadar.\(asin)" }

    /// Batch 447: why a release reminder was or wasn't set, so the Release Radar sheet can say so
    /// (before, a denied permission just left the button on "Remind me" with no explanation).
    enum ReleaseReminderResult: Equatable {
        case scheduled
        case notificationsOff
        case releaseDayPassed
        case failed
    }

    /// Schedule a one-shot local notification at 09:00 on `releaseDate` (a start-of-day `Date`).
    @discardableResult
    static func scheduleReleaseReminder(asin: String, title: String, seriesName: String, sequenceLabel: String,
                                        releaseDate: Date, calendar: Calendar = .current) async -> ReleaseReminderResult {
        guard await requestAuthorization() else { return .notificationsOff }
        var comps = calendar.dateComponents([.year, .month, .day], from: releaseDate)
        comps.hour = 9
        comps.minute = 0
        guard let fire = calendar.date(from: comps), fire > Date() else { return .releaseDayPassed }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Out today", comment: "Release-day notification title")
        content.body = String(localized: "\(title) (\(seriesName), \(sequenceLabel)) is out today.", comment: "Release-day notification body. Book title, series name, then a label like 'Book 5'.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: releaseReminderId(asin: asin), content: content, trigger: trigger)
        return (try? await UNUserNotificationCenter.current().add(request)) != nil ? .scheduled : .failed
    }

    static func cancelReleaseReminder(asin: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [releaseReminderId(asin: asin)])
    }

    static func hasReleaseReminder(asin: String) async -> Bool {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .contains { $0.identifier == releaseReminderId(asin: asin) }
    }
}
