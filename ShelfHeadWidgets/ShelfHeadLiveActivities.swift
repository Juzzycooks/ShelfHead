import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// Batch 406: the two Live Activities — the sleep timer countdown and the aggregate
// downloads progress — on the Lock Screen and in the Dynamic Island. The app starts,
// updates and ends them (`LiveActivityController`); their data shapes live in
// `Shared/SharedPlayback.swift`, which this target also compiles.
//
// HIG "Live Activities" decisions:
// - Glanceable: one figure each (time left, percent) with one short label; tapping opens
//   the app where the detail is.
// - The sleep activity is about the timer, never transport controls: the system already
//   shows Now Playing for the audio, so play/pause/skip here would just duplicate it.
//   Its one interactive element is "Turn Off" ("prefer limiting it to a single element").
//   The downloads activity has none.
// - Minimal presentation: the icon. The HIG prefers live information there, but a
//   countdown or percentage doesn't fit the minimal width legibly at larger text sizes;
//   the compact trailing slot carries the figure instead. Named here as a deliberate
//   departure.
// - Accent: VU Amber (the user's chosen accent) is the "live" signal — the countdown, the
//   progress fill, the key line — per DESIGN.md's One Light Rule. Finished uses Finished
//   Teal (Teal-Means-Done), a failure an orange glyph beside plain text (Fill-or-Text).
//   The Lock Screen keeps the system background (HIG: use custom backgrounds sparingly;
//   the default also suits StandBy and the Always-On display).

/// Live Activity colours. `WidgetTheme` (ShelfHeadWidgets.swift) supplies the accent and
/// the contrast nudge; the light/dark resolution here deliberately follows the *system*
/// appearance via the trait collection, not the in-app appearance override the Home
/// Screen widget honours, because the Lock Screen and Dynamic Island backgrounds behind
/// these always follow the system.
private enum LiveTheme {
    static func dynamic(light: String, dark: String) -> Color {
        Color(UIColor { traits in
            UIColor(WidgetTheme.color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Fills: progress bar, key line.
    static var accentFill: Color { WidgetTheme.color(hex: WidgetTheme.accentHex) }
    /// Accent as text/glyph on the Lock Screen (4.5:1 against the app's light/dark grounds).
    static var accentText: Color {
        let hexes = WidgetTheme.amberTextHex
        return dynamic(light: hexes.light, dark: hexes.dark)
    }
    /// Accent as text/glyph on the Dynamic Island's always-black background.
    static var islandAccent: Color {
        WidgetTheme.color(hex: WidgetTheme.adjustedHexForContrast(WidgetTheme.accentHex, backgroundHex: "000000"))
    }
    /// Finished Teal and Burnt Orange, the DESIGN.md light/dark pairs.
    static var done: Color { dynamic(light: "1C8E82", dark: "2FB6A8") }
    static var warning: Color { dynamic(light: "C9531F", dark: "E0612F") }
    static var islandDone: Color { WidgetTheme.color(hex: "2FB6A8") }
    static var islandWarning: Color { WidgetTheme.color(hex: "E0612F") }
}

/// Lock Screen presentations are capped at 160 pt tall; past this size the text would
/// clip rather than wrap. Everything below it still scales with Dynamic Type.
private let liveActivityTypeCap = DynamicTypeSize.accessibility1

// MARK: - Sleep timer

private extension SleepTimerActivityState {
    var kindLabel: LocalizedStringKey {
        switch kind {
        case .countdown: return "Sleep timer"
        case .chapter: return "Sleep at chapter end"
        case .endOfBook: return "Sleep at book end"
        }
    }
}

/// Counts down by itself to `endDate` (`Text(timerInterval:countsDown:)`, no updates
/// needed from the app); while paused, a frozen figure instead.
private struct SleepCountdown: View {
    let state: SleepTimerActivityState
    let isStale: Bool

    var body: some View {
        if isStale {
            // The app should have ended this by now; it likely isn't running.
            Text("Ended")
        } else if let end = state.endDate, !state.isPaused {
            // `min` keeps the range valid if this renders a moment after the end.
            Text(timerInterval: min(Date.now, end)...end, countsDown: true)
        } else {
            Text(Duration.seconds(state.pausedRemaining),
                 format: .time(pattern: state.pausedRemaining >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
    }
}

private struct SleepTurnOffButton: View {
    var compact = false
    var minHeight: CGFloat = 44
    var body: some View {
        Button(intent: SleepTimerOffIntent()) {
            Group {
                if compact {
                    Image(systemName: "xmark")
                } else {
                    Label("Turn Off", systemImage: "xmark")
                }
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("Turn off sleep timer"))
    }
}

private struct SleepExtendButton: View {
    var minHeight: CGFloat = 44
    var body: some View {
        Button(intent: SleepTimerExtendIntent()) {
            Text("+15 min")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("Add 15 minutes to sleep timer"))
    }
}

/// "+15 min" and "Turn Off" side by side; at large Dynamic Type the labelled pair
/// falls back to an icon-only Turn Off, then to a stacked pair, so both stay reachable.
private struct SleepActionButtons: View {
    var minHeight: CGFloat = 44
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                SleepExtendButton(minHeight: minHeight)
                SleepTurnOffButton(minHeight: minHeight)
            }
            HStack(spacing: 8) {
                SleepExtendButton(minHeight: minHeight)
                SleepTurnOffButton(compact: true, minHeight: minHeight)
            }
            VStack(spacing: 4) {
                SleepExtendButton(minHeight: minHeight)
                SleepTurnOffButton(compact: true, minHeight: minHeight)
            }
        }
    }
}

private struct SleepLockScreenView: View {
    let context: ActivityViewContext<SleepTimerActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    .foregroundStyle(LiveTheme.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.kindLabel)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .lineLimit(1)
                    if !state.bookTitle.isEmpty {
                        Text(verbatim: state.bookTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                SleepCountdown(state: state, isStale: context.isStale)
                    .font(.title2.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(state.isPaused || context.isStale
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(LiveTheme.accentText))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            HStack {
                if state.isPaused {
                    Text("Paused")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SleepActionButtons()
                    .tint(LiveTheme.accentText)
            }
        }
        .padding(14)   // HIG: the standard Lock Screen Live Activity margin
        .dynamicTypeSize(...liveActivityTypeCap)
    }
}

struct SleepTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepTimerActivityAttributes.self) { context in
            SleepLockScreenView(context: context)
                .activitySystemActionForegroundColor(LiveTheme.accentText)
                .widgetURL(URL(string: "shelfhead://nowplaying"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.kindLabel)
                            .font(.caption.weight(.semibold))
                            .fontDesign(.rounded)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(LiveTheme.islandAccent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepCountdown(state: state, isStale: context.isStale)
                        .font(.title3.weight(.semibold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                        .foregroundStyle(state.isPaused || context.isStale
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(LiveTheme.islandAccent))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Group {
                            if state.isPaused {
                                Text("Paused")
                            } else {
                                Text(verbatim: state.bookTitle)
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer()
                        SleepActionButtons(minHeight: 36)
                            .tint(LiveTheme.islandAccent)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(LiveTheme.islandAccent)
                    .accessibilityLabel(Text("Sleep timer"))
            } compactTrailing: {
                if state.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Paused"))
                } else {
                    SleepCountdown(state: state, isStale: context.isStale)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LiveTheme.islandAccent)
                        .multilineTextAlignment(.trailing)
                        // `Text(timerInterval:)` is horizontally greedy in a widget
                        // (SwiftUI documentation); pin it to the digits it can show.
                        .frame(width: state.pausedRemaining >= 3600 ? 54 : 40, alignment: .trailing)
                }
            } minimal: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(LiveTheme.islandAccent)
                    .accessibilityLabel(Text("Sleep timer"))
            }
            .keylineTint(LiveTheme.accentFill)
            .widgetURL(URL(string: "shelfhead://nowplaying"))
        }
    }
}

// MARK: - Downloads

private extension DownloadsActivityState {
    var symbolName: String {
        switch phase {
        case .downloading: return "arrow.down.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var headline: Text {
        switch phase {
        case .downloading:
            return activeCount == 1 ? Text("Downloading") : Text("Downloading \(activeCount) books")
        case .finished:
            return finishedCount == 1 ? Text("Downloaded") : Text("Downloaded \(finishedCount) books")
        case .failed:
            return failedCount == 1 ? Text("Download failed") : Text("\(failedCount) downloads failed")
        }
    }

    /// The line under the headline: the book's name when there's one, a failure count
    /// beside a finished run, or nothing.
    func detail(isStale: Bool) -> Text? {
        if phase == .downloading && isStale { return Text("Open ShelfHead to refresh") }
        if let singleTitle, !singleTitle.isEmpty { return Text(verbatim: singleTitle) }
        if phase == .finished && failedCount > 0 { return Text("\(failedCount) failed") }
        return nil
    }

    var percentText: Text {
        Text(fraction, format: .percent.precision(.fractionLength(0)))
    }
}

private struct DownloadsLockScreenView: View {
    let context: ActivityViewContext<DownloadsActivityAttributes>

    private var symbolColor: Color {
        switch context.state.phase {
        case .downloading: return LiveTheme.accentText
        case .finished: return LiveTheme.done
        case .failed: return LiveTheme.warning
        }
    }

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                state.headline
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.phase == .downloading {
                    state.percentText
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(context.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }
            }
            if state.phase == .downloading {
                ProgressView(value: state.fraction)
                    .tint(LiveTheme.accentFill)
                    .accessibilityHidden(true)   // the percentage above already says it
            }
            if let detail = state.detail(isStale: context.isStale) {
                detail
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(14)
        .dynamicTypeSize(...liveActivityTypeCap)
    }
}

struct DownloadsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadsActivityAttributes.self) { context in
            DownloadsLockScreenView(context: context)
                .activitySystemActionForegroundColor(LiveTheme.accentText)
                .widgetURL(URL(string: "shelfhead://downloads"))
        } dynamicIsland: { context in
            let state = context.state
            let symbolColor: Color = {
                switch state.phase {
                case .downloading: return LiveTheme.islandAccent
                case .finished: return LiveTheme.islandDone
                case .failed: return LiveTheme.islandWarning
                }
            }()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbolName)
                        .font(.title3)
                        .foregroundStyle(symbolColor)
                        .padding(.leading, 4)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .downloading {
                        state.percentText
                            .font(.title3.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    state.headline
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.rounded)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if state.phase == .downloading {
                            ProgressView(value: state.fraction)
                                .tint(LiveTheme.accentFill)
                                .accessibilityHidden(true)
                        }
                        if let detail = state.detail(isStale: context.isStale) {
                            detail
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(symbolColor)
                    .accessibilityLabel(state.headline)
            } compactTrailing: {
                if state.phase == .downloading {
                    state.percentText
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(LiveTheme.islandAccent)
                }
            } minimal: {
                Image(systemName: state.symbolName)
                    .foregroundStyle(symbolColor)
                    .accessibilityLabel(state.headline)
            }
            .keylineTint(LiveTheme.accentFill)
            .widgetURL(URL(string: "shelfhead://downloads"))
        }
    }
}
