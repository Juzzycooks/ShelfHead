import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Center "Resume ShelfHead" control (N-2, REVIEW_2026-09-14_DESIGN.md)
//
// A single, non-configurable play/pause toggle, reachable from Control Center and the
// Lock Screen, showing the current book's title (or "Resume ShelfHead" when nothing
// has ever been loaded).
//
// `ControlWidget` is iOS 18+ (deployment target stays 17.6 — CLAUDE.md), so every
// declaration here is `@available(iOS 18.0, *)`, gated in `ShelfHeadWidgetBundle` via
// `if #available(iOS 18.0, *)`.
//
// Reuses the existing widget-button machinery in WidgetPlaybackIntents.swift: posting
// Darwin notifications is what the Home Screen widget's buttons already do, including
// relaunching a force-quit app to resume. See ShelfHeadControls.swift for the sibling
// Resume/Sleep Timer/Now Playing controls added alongside this one.

/// What the control shows, read once per `ControlValueProvider.currentValue()` call.
/// App Group `UserDefaults`/file reads only (via `SharedPlayback`) — no network I/O.
@available(iOS 18.0, *)
struct ShelfHeadControlState: Equatable, Sendable {
    var isPlaying: Bool
    /// The loaded book's title (playing OR paused), or "Resume ShelfHead" when nothing
    /// has ever been loaded into the shared snapshot (fresh install, signed out, or a
    /// state the "Play Audiobook" Siri intent's `AudiobookEntity` picker would show
    /// nothing for either).
    var subtitle: String
}

/// Supplies `ShelfHeadControlState` to the control, and the preview value shown while
/// it sits in the "Add a Control" gallery/sheet.
@available(iOS 18.0, *)
struct ShelfHeadControlValueProvider: ControlValueProvider {
    /// Same sample book `PlaybackEntry.galleryPreview()` uses in ShelfHeadWidgets.swift,
    /// for the same reason: a plausible card for someone browsing controls to add,
    /// without touching the App Group.
    var previewValue: ShelfHeadControlState {
        ShelfHeadControlState(isPlaying: true, subtitle: "The Fellowship of the Ring")
    }

    func currentValue() async throws -> ShelfHeadControlState {
        guard let snapshot = SharedPlayback.read() else {
            return ShelfHeadControlState(isPlaying: false, subtitle: String(localized: "Resume ShelfHead"))
        }
        return ShelfHeadControlState(isPlaying: Self.currentKnownIsPlaying(), subtitle: snapshot.title)
    }

    /// Whether the shared snapshot's `isPlaying` flag is still trustworthy right now
    /// (90s staleness threshold, mirroring `PlaybackProvider.timeline(for:in:)`'s own
    /// guard — a stale "playing" snapshot means the app was force-quit, not still
    /// playing). `SleepTimerControlValueProvider` in ShelfHeadControls.swift applies
    /// the same rule to `sleepTimerActive`.
    static func currentKnownIsPlaying() -> Bool {
        guard let snapshot = SharedPlayback.read() else { return false }
        let staleThreshold: TimeInterval = 90
        return snapshot.isPlaying && Date().timeIntervalSince(snapshot.updatedAt) <= staleThreshold
    }
}

// `PlaybackControlToggleIntent` moved to WidgetPlaybackIntents.swift so it compiles
// into the main app target too (see that file's header for why).

/// The Control Center / Lock Screen control itself. Not user-configurable (there's only
/// ever one "current book"), so `StaticControlConfiguration` + `ControlValueProvider`
/// is the right shape here rather than `AppIntentControlConfiguration` (which is for a
/// control whose target — e.g. "which light" — is chosen per-instance in Settings).
@available(iOS 18.0, *)
struct ShelfHeadPlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: SharedPlayback.playbackControlKind,
            provider: ShelfHeadControlValueProvider()
        ) { state in
            ControlWidgetToggle(
                "Play / Pause",
                isOn: state.isPlaying,
                action: PlaybackControlToggleIntent()
            ) { isPlaying in
                Label(state.subtitle, systemImage: isPlaying ? "pause.fill" : "play.fill")
                    // VoiceOver / Action Button hint describing what activating the
                    // control does in each state, matching this target's existing
                    // convention of state-dependent accessibility text (see
                    // `SkipLabels.accessibilityLabel` for the skip buttons' equivalent).
                    // `controlWidgetActionHint` is a View modifier on the toggle's label
                    // content, not on the `ControlWidgetTemplate` (PM compile fix,
                    // Batch 319).
                    .controlWidgetActionHint(isPlaying ? "Pause" : "Play")
            }
            // Same user-selectable accent the Home Screen widget renders with
            // (`WidgetTheme.accentHex`, mirrored into the App Group by `ThemeStore`) —
            // widened from `private` to internal in ShelfHeadWidgets.swift so this file
            // can reuse it instead of re-deriving a second copy.
            .tint(WidgetTheme.color(hex: WidgetTheme.accentHex))
        }
        .displayName("ShelfHead Playback")
        .description("Play or pause your current audiobook, or resume your last one.")
    }
}
