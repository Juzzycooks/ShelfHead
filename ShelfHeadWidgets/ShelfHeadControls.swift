import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Additional Control Center controls (N-2 follow-up)
//
// Resume Last Book / Sleep Timer / Open Now Playing. See ShelfHeadPlaybackControl.swift
// for the original play/pause control and the shared availability/staleness patterns
// these follow.

@available(iOS 18.0, *)
struct ShelfHeadResumeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.shelfhead.app.resumeControl") {
            ControlWidgetButton(action: ResumeLastBookControlIntent()) {
                // PS-4 (docs/visual-design-review.md, Round V1): the control already
                // renders inside a system circle, so a `.circle.fill` glyph drew a
                // disc-in-a-disc heavier than its siblings. Plain glyph instead.
                Label("Resume Last Book", systemImage: "play.fill")
            }
            .tint(WidgetTheme.color(hex: WidgetTheme.accentHex))
        }
        .displayName("Resume Last Book")
        .description("Pick up your most recent audiobook where you left off.")
    }
}

@available(iOS 18.0, *)
struct SleepTimerControlState: Equatable, Sendable {
    var isActive: Bool
    var defaultMinutes: Int
}

/// Same 90s staleness rule as `ShelfHeadControlValueProvider.currentKnownIsPlaying()` —
/// an armed timer whose snapshot hasn't moved in 90s almost certainly belongs to a
/// force-quit app.
@available(iOS 18.0, *)
struct SleepTimerControlValueProvider: ControlValueProvider {
    var previewValue: SleepTimerControlState {
        SleepTimerControlState(isActive: false, defaultMinutes: 30)
    }

    func currentValue() async throws -> SleepTimerControlState {
        let snapshot = SharedPlayback.read()
        let defaultMinutes = snapshot?.sleepTimerDefaultMinutes ?? 30
        var isActive = false
        if let snapshot {
            // Polish pass (WG-4): the app only refreshes the snapshot while it is playing, so a
            // PAUSED session with an armed timer has an old `updatedAt` through no fault of
            // the app being gone. Apply the force-quit staleness rule only to a snapshot that
            // still claims it is playing.
            let isStale = Date().timeIntervalSince(snapshot.updatedAt) > 90
            isActive = (snapshot.sleepTimerActive ?? false) && !(snapshot.isPlaying && isStale)
        }
        return SleepTimerControlState(isActive: isActive, defaultMinutes: defaultMinutes)
    }
}

@available(iOS 18.0, *)
struct ShelfHeadSleepTimerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedPlayback.sleepTimerControlKind,
            provider: SleepTimerControlValueProvider()
        ) { state in
            ControlWidgetToggle(
                "Sleep Timer",
                isOn: state.isActive,
                action: SleepTimerControlToggleIntent()
            ) { isOn in
                Label(isOn ? "On" : "\(state.defaultMinutes) min",
                      systemImage: isOn ? "moon.zzz.fill" : "moon.zzz")
                    .controlWidgetActionHint(isOn ? "Turn Off" : "Start \(state.defaultMinutes) min")
            }
            .tint(WidgetTheme.color(hex: WidgetTheme.accentHex))
        }
        .displayName("Sleep Timer")
        .description("Start or stop a sleep timer at your default length.")
    }
}

@available(iOS 18.0, *)
struct ShelfHeadOpenNowPlayingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.shelfhead.app.openNowPlayingControl") {
            ControlWidgetButton(action: OpenNowPlayingControlIntent()) {
                // PS-4 (docs/visual-design-review.md, Round V1): same double-ring issue
                // as the Resume control above — plain glyph inside the system circle.
                Label("Now Playing", systemImage: "waveform")
            }
            .tint(WidgetTheme.color(hex: WidgetTheme.accentHex))
        }
        .displayName("Open Now Playing")
        .description("Jump straight to the ShelfHead player.")
    }
}
