import Foundation
import ActivityKit

// ADD THIS FILE TO: main app target AND the widget extension target.
// Defines the Live Activity attributes for the currently-playing book.

struct NowPlayingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var currentTime: Double
        var duration: Double
        var isPlaying: Bool
        var chapterTitle: String?

        var progress: Double { duration > 0 ? min(currentTime / duration, 1) : 0 }
    }

    var title: String
    var author: String
    var itemId: String
}
