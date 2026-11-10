import WidgetKit
import SwiftUI

/// L14 (docs/design-review.md): a watch face complication / Smart Stack widget for ShelfHead.
///
/// Shows the book that's playing (or was last played) when the Watch app has written one, and
/// otherwise a plain launcher. The Watch app writes `WatchComplicationSnapshot` as JSON into the
/// App Group container (`group.com.shelfhead.app`, which this extension is entitled to); the same
/// group must be enabled on the "ShelfHead Watch" target or nothing is ever written and this stays
/// a launcher. Tapping opens the app, at Now Playing when a book is showing.

/// Same shape and JSON keys as `WatchComplicationSnapshot` in the Watch app (a different target,
/// so it can't be imported). Keep the two in sync by hand.
struct NowPlayingSnapshot: Codable, Equatable {
    var title: String
    var author: String
    var progress: Double
    var isPlaying: Bool
    var updatedAt: Date

    static let appGroup = "group.com.shelfhead.app"
    static let fileName = "watch-now-playing.json"

    static func read() -> NowPlayingSnapshot? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
                .appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data) else { return nil }
        // Review 6 Low (complication): a snapshot older than a day is stale, show the launcher.
        return Date().timeIntervalSince(snapshot.updatedAt) > 24 * 3600 ? nil : snapshot
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
    let nowPlaying: NowPlayingSnapshot?
}

struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry(date: .now, nowPlaying: nil) }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now, nowPlaying: context.isPreview ? nil : NowPlayingSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        // The app asks for a reload whenever the book or play state changes; the fallback refresh
        // only catches a missed one.
        let entry = LauncherEntry(date: .now, nowPlaying: NowPlayingSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }
}

struct ShelfHeadWatchWidgetsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LauncherEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if let now = entry.nowPlaying {
                    Gauge(value: min(1, max(0, now.progress))) {
                        Image(systemName: "headphones")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .widgetAccentable()
                } else {
                    Image(systemName: "headphones")
                        .font(.title3.weight(.semibold))
                        .widgetAccentable()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.nowPlaying.map { String(localized: "\($0.title), \(Int($0.progress * 100)) percent", comment: "VoiceOver label for a watch complication. %1$@ is the book title, %2$lld is the progress percentage.") } ?? String(localized: "Open ShelfHead"))
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: entry.nowPlaying?.isPlaying == true ? "waveform" : "headphones")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.nowPlaying?.title ?? "ShelfHead")
                        .font(.headline).lineLimit(2).widgetAccentable()
                    Text(entry.nowPlaying.map { String(localized: "\(Int($0.progress * 100))% · \($0.author)", comment: "Watch complication subtitle. %1$lld is the progress percentage, %2$@ is the author.") } ?? String(localized: "Continue listening"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        case .accessoryCorner:
            Image(systemName: "headphones")
                .font(.title3.weight(.semibold))
                .widgetAccentable()
                .widgetLabel(entry.nowPlaying?.title ?? "ShelfHead")
                .accessibilityLabel(entry.nowPlaying?.title ?? String(localized: "Open ShelfHead"))
        default:
            Label(entry.nowPlaying?.title ?? "ShelfHead", systemImage: "headphones")
        }
    }
}

struct ShelfHeadWatchWidgets: Widget {
    let kind: String = "ShelfHeadWatchLauncher"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LauncherProvider()) { entry in
            ShelfHeadWatchWidgetsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // With a book showing, a tap opens Now Playing (`WatchDeepLink` in the Watch
                // app parses this; keep the spelling in sync by hand). Without one, no URL:
                // the tap just opens the app.
                .widgetURL(entry.nowPlaying == nil ? nil : URL(string: "shelfhead://nowplaying"))
        }
        .configurationDisplayName("ShelfHead")
        .description("Your current book, and a shortcut into ShelfHead.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    ShelfHeadWatchWidgets()
} timeline: {
    LauncherEntry(date: .now, nowPlaying: NowPlayingSnapshot(title: "The Time Machine", author: "H. G. Wells", progress: 0.42, isPlaying: true, updatedAt: .now))
}

#Preview("Circular", as: .accessoryCircular) {
    ShelfHeadWatchWidgets()
} timeline: {
    LauncherEntry(date: .now, nowPlaying: NowPlayingSnapshot(title: "The Time Machine", author: "H. G. Wells", progress: 0.42, isPlaying: true, updatedAt: .now))
}
