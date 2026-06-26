import WidgetKit
import SwiftUI
import UIKit
import AppIntents

// Home-Screen widget showing the current book, styled to match the app's
// retro tape-deck theme. The widget target can't see the app's Color palette,
// so the colors are defined locally here.

private enum Retro {
    static let amber   = Color(red: 232/255, green: 168/255, blue: 56/255)
    static let cream   = Color(red: 244/255, green: 233/255, blue: 214/255)
    static let bg      = Color(red: 22/255,  green: 17/255,  blue: 12/255)
    static let card    = Color(red: 36/255,  green: 27/255,  blue: 18/255)
    static let surface = Color(red: 50/255,  green: 38/255,  blue: 26/255)
    static let muted   = Color(red: 168/255, green: 145/255, blue: 119/255)
    static let shell   = Color(red: 58/255,  green: 43/255,  blue: 28/255)
}

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
        let now = Date()
        guard let snapshot = SharedPlayback.read() else {
            completion(Timeline(entries: [PlaybackEntry(date: now, snapshot: nil)],
                                policy: .after(now.addingTimeInterval(60 * 15))))
            return
        }

        // While playing, generate future entries that advance the position (≈1×) so the
        // widget's progress ticks forward on its own, in step with the lock screen,
        // instead of freezing until the app next writes a snapshot.
        var entries: [PlaybackEntry] = []
        if snapshot.isPlaying {
            for offset in stride(from: 0, through: 60 * 30, by: 30) {
                var s = snapshot
                s.currentTime = min(snapshot.currentTime + Double(offset), snapshot.duration)
                entries.append(PlaybackEntry(date: now.addingTimeInterval(Double(offset)), snapshot: s))
            }
        } else {
            entries = [PlaybackEntry(date: now, snapshot: snapshot)]
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 30))))
    }
}

// MARK: - Cassette-styled cover

private struct WidgetCassette: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().aspectRatio(contentMode: .fill)
            } else {
                Retro.surface.overlay(
                    Image(systemName: "book.closed.fill").foregroundStyle(Retro.muted)
                )
            }
            HStack(spacing: 5) {
                hub
                Rectangle().fill(Retro.cream.opacity(0.25)).frame(height: 2)
                hub
            }
            .padding(.horizontal, 7)
            .frame(height: max(16, size * 0.26))
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.5))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Retro.cream.opacity(0.16), lineWidth: 1))
    }

    private var hub: some View {
        Circle()
            .fill(Retro.surface)
            .overlay(Circle().strokeBorder(Retro.cream.opacity(0.5), lineWidth: 1.5))
            .overlay(Circle().fill(Retro.cream.opacity(0.8)).frame(width: 3, height: 3))
            .frame(width: max(10, size * 0.15), height: max(10, size * 0.15))
    }
}

// MARK: - Shared bits

private func timeString(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private struct ProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Retro.cream.opacity(0.14))
                Capsule().fill(Retro.amber).frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct PlayButton: View {
    let isPlaying: Bool
    let diameter: CGFloat
    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                Circle().fill(Retro.amber)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundStyle(Retro.bg)
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Layouts

struct ShelfHeadWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: PlaybackEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                if family == .systemSmall { small(snapshot) } else { medium(snapshot) }
            } else {
                emptyState
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Retro.card, Retro.bg], startPoint: .top, endPoint: .bottom)
        }
    }

    // Square
    private func small(_ s: SharedPlayback.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                WidgetCassette(data: s.coverData, size: 62)
                Spacer()
                PlayButton(isPlaying: s.isPlaying, diameter: 38)
            }
            Text(s.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Retro.cream)
                .lineLimit(2)
            Spacer(minLength: 0)
            ProgressBar(progress: s.progress)
            Text("-\(timeString(s.duration - s.currentTime))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Retro.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    // Wide — tape-deck strip
    private func medium(_ s: SharedPlayback.Snapshot) -> some View {
        HStack(spacing: 14) {
            WidgetCassette(data: s.coverData, size: 84)

            VStack(alignment: .leading, spacing: 5) {
                Text("NOW PLAYING")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(Retro.amber.opacity(0.85))
                Text(s.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Retro.cream)
                    .lineLimit(2)
                Text(s.author)
                    .font(.system(size: 11))
                    .foregroundStyle(Retro.muted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                ProgressBar(progress: s.progress)
                HStack {
                    Text(timeString(s.currentTime))
                    Spacer()
                    Text("-\(timeString(s.duration - s.currentTime))")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Retro.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                PlayButton(isPlaying: s.isPlaying, diameter: 46)
                Button(intent: SkipForwardIntent()) {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Retro.cream.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "recordingtape")
                .font(.system(size: 26))
                .foregroundStyle(Retro.amber)
            Text("No tape loaded")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Retro.cream)
            Text("Start a book in ShelfHead")
                .font(.system(size: 10))
                .foregroundStyle(Retro.muted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ShelfHeadWidget: Widget {
    let kind = "ShelfHeadWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaybackProvider()) { entry in
            ShelfHeadWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Your current audiobook, tape-deck style.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()   // fill edge-to-edge instead of the default inset border
    }
}

@main
struct ShelfHeadWidgetBundle: WidgetBundle {
    var body: some Widget {
        ShelfHeadWidget()
    }
}
