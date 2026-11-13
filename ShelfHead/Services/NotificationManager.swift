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
        // Batch 495 (REVIEW 2026-11-11 Y1): no `.badge`; the app never sets one.
        if let granted = try? await center.requestAuthorization(options: [.alert, .sound]) {
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
        // Batch 495 (REVIEW 2026-11-11 Y1): tap opens Now Playing; the Resume action plays.
        content.categoryIdentifier = NotificationRoute.Category.dailyReminder.rawValue

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
    /// Batch 495 (REVIEW 2026-11-11 Y1): `itemId` rides in `userInfo`, so a tap opens the book and
    /// the Play action plays it.
    static func notifyDownloadComplete(title: String, itemId: String) {
        guard SettingsStore.notifyDownloadCompleteEnabled else { return }
        Task {
            guard await isAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Download complete", comment: "Download-complete notification title")
            content.body = String(localized: "\(title) is ready for offline listening.", comment: "Download-complete notification body. %@ is the audiobook title.")
            content.sound = .default
            content.categoryIdentifier = NotificationRoute.Category.downloadComplete.rawValue
            content.userInfo = NotificationRoute.Payload(itemId: itemId).userInfo
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
        // Batch 495 (REVIEW 2026-11-11 Y1): asking for a reminder is asking for the notification,
        // so the Settings switch (System & Privacy › Notifications) comes back on if it was off.
        if !SettingsStore.releaseReminderNotificationsEnabled {
            UserDefaults.standard.set(true, forKey: SettingsKeys.releaseReminderNotifications)
        }
        var comps = calendar.dateComponents([.year, .month, .day], from: releaseDate)
        comps.hour = 9
        comps.minute = 0
        guard let fire = calendar.date(from: comps), fire > Date() else { return .releaseDayPassed }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Out today", comment: "Release-day notification title")
        content.body = String(localized: "\(title) (\(seriesName), \(sequenceLabel)) is out today.", comment: "Release-day notification body. Book title, series name, then a label like 'Book 5'.")
        content.sound = .default
        // Batch 495 (REVIEW 2026-11-11 Y1): a tap searches Library for the series (the radar
        // entry itself has no link of its own).
        content.categoryIdentifier = NotificationRoute.Category.releaseReminder.rawValue
        content.userInfo = NotificationRoute.Payload(seriesName: seriesName).userInfo
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

    /// Batch 495 (REVIEW 2026-11-11 Y1): the Release-day reminders switch turned off removes every
    /// pending one.
    static func cancelAllReleaseReminders() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(releaseReminderId(asin: "")) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Categories (Batch 495, REVIEW 2026-11-11 Y1)

    /// Registered at launch (`NotificationResponder.install()`). Both actions bring the app to
    /// the foreground: starting a non-mixable `.playback` session from the background isn't
    /// allowed, and the foreground path also keeps App Lock in front of playback.
    static var categories: Set<UNNotificationCategory> {
        let resume = UNNotificationAction(identifier: NotificationRoute.resumeAction,
                                          title: String(localized: "Resume", comment: "Daily reminder notification action: resume the last book"),
                                          options: [.foreground])
        let play = UNNotificationAction(identifier: NotificationRoute.playAction,
                                        title: String(localized: "Play", comment: "Download-complete notification action: play the downloaded book"),
                                        options: [.foreground])
        return [
            UNNotificationCategory(identifier: NotificationRoute.Category.dailyReminder.rawValue,
                                   actions: [resume], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationRoute.Category.downloadComplete.rawValue,
                                   actions: [play], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationRoute.Category.releaseReminder.rawValue,
                                   actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationRoute.Category.householdRecommendation.rawValue,
                                   actions: [], intentIdentifiers: []),
        ]
    }
}

// MARK: - Settings (Batch 495, REVIEW 2026-11-11 Y1)

extension SettingsKeys {
    /// Release-day reminders from Release Radar. Default on (today's behaviour: a reminder you set fires).
    static let releaseReminderNotifications = "settings_releaseReminderNotifications"
}

extension SettingsStore {
    static var releaseReminderNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.releaseReminderNotifications) as? Bool ?? true
    }
}

// MARK: - Routing (Batch 495, REVIEW 2026-11-11 Y1)

/// What a tapped notification (or one of its actions) opens, as a `shelfhead://` link. The link is
/// handed to `IncomingLinkInbox`, so it takes the one deep-link path (`MainTabView.handleDeepLink`)
/// and waits behind sign-in, the profile picker and App Lock like any other link. Pure; pinned by
/// `Batch495NotificationsRouteTests`.
nonisolated enum NotificationRoute {
    enum Category: String, CaseIterable, Sendable {
        case dailyReminder = "shelfhead.category.dailyReminder"
        case downloadComplete = "shelfhead.category.downloadComplete"
        case releaseReminder = "shelfhead.category.releaseReminder"
        case householdRecommendation = "shelfhead.category.householdRecommendation"
    }

    static let resumeAction = "shelfhead.action.resume"
    static let playAction = "shelfhead.action.play"

    /// The few strings a notification carries in `userInfo`.
    struct Payload: Equatable, Sendable {
        static let itemIdKey = "itemId"
        static let seriesNameKey = "seriesName"
        static let serverFingerprintKey = "serverFingerprint"

        var itemId: String?
        var seriesName: String?
        var serverFingerprint: String?

        init(itemId: String? = nil, seriesName: String? = nil, serverFingerprint: String? = nil) {
            self.itemId = itemId
            self.seriesName = seriesName
            self.serverFingerprint = serverFingerprint
        }

        init(userInfo: [AnyHashable: Any]) {
            func string(_ key: String) -> String? {
                guard let value = userInfo[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            self.init(itemId: string(Self.itemIdKey), seriesName: string(Self.seriesNameKey),
                      serverFingerprint: string(Self.serverFingerprintKey))
        }

        var userInfo: [String: String] {
            var info: [String: String] = [:]
            if let itemId { info[Self.itemIdKey] = itemId }
            if let seriesName { info[Self.seriesNameKey] = seriesName }
            if let serverFingerprint { info[Self.serverFingerprintKey] = serverFingerprint }
            return info
        }
    }

    /// The link for a response, or nil to just open the app where it was (a dismissal, an unknown
    /// category or action, or a release reminder with nothing to search for).
    /// `currentServerFingerprint` is the signed-in server's, so a recommendation for a book on
    /// another server opens the Household page instead of a book that can't be found here.
    static func url(categoryIdentifier: String, actionIdentifier: String, payload: Payload,
                    currentServerFingerprint: String) -> URL? {
        guard let category = Category(rawValue: categoryIdentifier) else { return nil }
        let isDefault = actionIdentifier == UNNotificationDefaultActionIdentifier
        switch category {
        case .dailyReminder:
            if actionIdentifier == resumeAction { return URL(string: "shelfhead://resume") }
            return isDefault ? URL(string: "shelfhead://nowplaying") : nil
        case .downloadComplete:
            let play = actionIdentifier == playAction
            guard play || isDefault else { return nil }
            guard let id = payload.itemId else { return URL(string: "shelfhead://downloads") }
            return link(host: "book", id: id, query: play ? [URLQueryItem(name: "play", value: "1")] : nil)
        case .releaseReminder:
            guard isDefault, let series = payload.seriesName else { return nil }
            // Batch 497 (Y1): the series page when the library has it (`MainTabView` resolves the
            // name; no match, no library or no server falls back to `shelfhead://search?q=`).
            return link(host: "series", id: nil, query: [URLQueryItem(name: "name", value: series)])
        case .householdRecommendation:
            guard isDefault else { return nil }
            if let id = payload.itemId, let fingerprint = payload.serverFingerprint,
               !currentServerFingerprint.isEmpty, fingerprint == currentServerFingerprint {
                return link(host: "book", id: id, query: nil)
            }
            return URL(string: "shelfhead://household")
        }
    }

    /// Whether a notification that arrives with ShelfHead open shows as a banner. The daily
    /// reminder doesn't (you're already in the app); it still goes to Notification Centre.
    static func showsBannerInForeground(categoryIdentifier: String) -> Bool {
        Category(rawValue: categoryIdentifier) != .dailyReminder
    }

    private static func link(host: String, id: String?, query: [URLQueryItem]?) -> URL? {
        var components = URLComponents()
        components.scheme = "shelfhead"
        components.host = host
        if let id { components.path = "/" + id }
        components.queryItems = query
        return components.url
    }
}

/// Batch 495 (REVIEW 2026-11-11 Y1): the `UNUserNotificationCenter` delegate. Installed from
/// `AppDelegate.application(_:willFinishLaunchingWithOptions:)`, because Apple's docs require the
/// delegate to be set before launch finishes or a cold-start tap is missed
/// (UNUserNotificationCenterDelegate, "You must assign your delegate object … before your app
/// finishes launching"). Not main-actor isolated: the system may call it on any queue, so it reads
/// the response there and hops to the main actor with plain strings only.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationResponder()

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self   // `delegate` is weak; `shared` keeps this alive.
        center.setNotificationCategories(NotificationManager.categories)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        let action = response.actionIdentifier
        let payload = NotificationRoute.Payload(userInfo: content.userInfo)
        await MainActor.run {
            let fingerprint = ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL)
            guard let url = NotificationRoute.url(categoryIdentifier: category, actionIdentifier: action,
                                                  payload: payload, currentServerFingerprint: fingerprint) else { return }
            IncomingLinkInbox.shared.hold(url)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        NotificationRoute.showsBannerInForeground(categoryIdentifier: notification.request.content.categoryIdentifier)
            ? [.banner, .list, .sound] : [.list]
    }
}
