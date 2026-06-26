import WidgetKit
import SwiftUI

// ADD THIS FILE TO: the widget extension target only.
// Home Screen / Lock Screen widget showing the current book and progress.

struct PlaybackEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedPlayback.Snapshot?
}

struct PlaybackProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaybackEntry {
        PlaybackEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaybackEntry) -> Void) {
        completion(PlaybackEntry(date: Date(), snapshot: SharedPlayback.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaybackEntry>) -> Void) {
        let entry = PlaybackEntry(date: Date(), snapshot: SharedPlayback.read())
        // Refresh periodically; the app also reloads timelines on playback changes.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 15))))
    }
}

struct ShelfHeadWidgetView: View {
    var entry: PlaybackEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text("NOW PLAYING").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Text(snapshot.title).font(.headline).lineLimit(2)
                Text(snapshot.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                ProgressView(value: snapshot.progress).tint(.orange)
            }
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "headphones").font(.title)
                Text("Nothing playing").font(.caption).foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ShelfHeadWidget: Widget {
    let kind = "ShelfHeadWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaybackProvider()) { entry in
            ShelfHeadWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Your current audiobook and progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct ShelfHeadWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShelfHeadWidget()
        NowPlayingLiveActivity()
    }
}
