import Foundation
import WidgetKit

/// What the Watch complication (`ShelfHeadWatchWidgets`) shows: the book that's playing or was last
/// played. The Watch app writes it into the App Group container as a small JSON file and the widget
/// extension reads it. The extension can't import this target, so `ShelfHeadWatchWidgets.swift`
/// declares the same shape; keep the two in sync by hand (a test pins the JSON keys).
///
/// **Needs the App Group capability on "ShelfHead Watch".** `ShelfHeadWatchWidgetsExtension` already
/// has `group.com.shelfhead.app`. Until "ShelfHead Watch" has it too, `containerURL` is nil here and
/// every call below does nothing, so the complication just stays a launcher.
struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    var title: String
    var author: String
    /// 0...1 through the book.
    var progress: Double
    var isPlaying: Bool
    var updatedAt: Date

    static let appGroup = "group.com.shelfhead.app"
    static let fileName = "watch-now-playing.json"
    static let widgetKind = "ShelfHeadWatchLauncher"

    /// Batch 490 (REVIEW 2026-11-11 W14): the last word after Stop or the end of a book,
    /// so the complication drops its "playing" glyph but keeps the book and its place.
    /// `nil` without a title (nothing worth showing).
    static func stopped(title: String, author: String, currentTime: Double, duration: Double,
                        at date: Date) -> WatchComplicationSnapshot? {
        guard !title.isEmpty else { return nil }
        return WatchComplicationSnapshot(title: title, author: author,
                                         progress: progress(currentTime: currentTime, duration: duration),
                                         isPlaying: false, updatedAt: date)
    }

    /// Clamped 0...1, and 0 for a book with no known length.
    static func progress(currentTime: Double, duration: Double) -> Double {
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}

/// Batch 362: where a complication tap lands. With a book showing, the complication sets
/// `widgetURL(WatchDeepLink.nowPlayingURL)` (`ShelfHeadWatchWidgets.swift` spells the same URL;
/// it can't import this target) and `WatchRootView` opens Now Playing; the plain launcher sets
/// none and just opens the app. Same `shelfhead://nowplaying` spelling as the phone's deep link.
enum WatchDeepLink: Equatable, Sendable {
    case nowPlaying

    nonisolated static let nowPlayingURL = URL(string: "shelfhead://nowplaying")!

    nonisolated init?(url: URL) {
        guard url.scheme?.lowercased() == "shelfhead" else { return nil }
        switch url.host?.lowercased() {
        case "nowplaying": self = .nowPlaying
        default: return nil
        }
    }
}

@MainActor
enum WatchComplicationStore {
    private static var lastWritten: WatchComplicationSnapshot?

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WatchComplicationSnapshot.appGroup)?
            .appendingPathComponent(WatchComplicationSnapshot.fileName)
    }

    /// Writes `snapshot` (or removes the file for nil) and asks WidgetKit to refresh, but only when
    /// what the complication shows has changed (title, play state or progress to the nearest percent).
    static func publish(_ snapshot: WatchComplicationSnapshot?) {
        guard let url = fileURL else { return }
        if let a = snapshot, let b = lastWritten,
           a.title == b.title, a.isPlaying == b.isPlaying, Int(a.progress * 100) == Int(b.progress * 100) { return }
        lastWritten = snapshot
        if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationSnapshot.widgetKind)
    }
}
