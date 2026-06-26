import Foundation

// ADD THIS FILE TO: main app target AND the widget extension target.
// It shares the current playback snapshot via an App Group so the widget can render it.
//
// Replace the suite name with your real App Group id (e.g. "group.com.shelfhead.app").

enum SharedPlayback {
    static let appGroup = "group.com.shelfhead.app"
    private static let key = "currentPlayback"

    struct Snapshot: Codable {
        var itemId: String
        var title: String
        var author: String
        var currentTime: Double
        var duration: Double
        var isPlaying: Bool
        var updatedAt: Date

        var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// Call from the main app whenever playback state changes.
    static func write(_ snapshot: Snapshot?) {
        guard let defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Read from the widget timeline provider.
    static func read() -> Snapshot? {
        guard let data = defaults?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return snapshot
    }
}
