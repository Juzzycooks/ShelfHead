import WidgetKit
import SwiftUI
import ActivityKit

// ADD THIS FILE TO: the widget extension target only.
// Live Activity (Lock Screen + Dynamic Island) for the current book.

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // Lock Screen / banner presentation
            VStack(alignment: .leading, spacing: 6) {
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Text(context.state.chapterTitle ?? context.attributes.author)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressView(value: context.state.progress).tint(.orange)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress).tint(.orange)
                }
            } compactLeading: {
                Image(systemName: "headphones")
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%").font(.caption2)
            } minimal: {
                Image(systemName: "headphones")
            }
        }
    }
}
