import Foundation

// Widget-target copy of SharedPlayback (kept in sync with ShelfHead/Shared/SharedPlayback.swift).
// The widget only READS the snapshot from the shared App Group, so an identical
// duplicate is safe. Keep `appGroup` identical in both copies.
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
        var coverData: Data?   // small JPEG of the cover, for the widget to render

        var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func write(_ snapshot: Snapshot?) {
        guard let defaults else { return }
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func read() -> Snapshot? {
        guard let data = defaults?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        return snapshot
    }
}
