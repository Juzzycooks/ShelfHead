import AppIntents
import Foundation

// MARK: - Widget-button intents
//
// These three types are invoked ONLY from `Button(intent:)` inside
// `ShelfHeadWidgets.swift` (the medium/large tiles' play-pause and skip controls, plus
// the accessory families) — never from Siri, the Shortcuts app or Spotlight. Every one
// of them therefore sets `isDiscoverable` to `false`.
//
// This file also holds the Control Center intents (`PlaybackControlToggleIntent`,
// `ResumeLastBookControlIntent`, `SleepTimerControlToggleIntent`,
// `OpenNowPlayingControlIntent`) for the same reason: `AudioPlaybackIntent` only gets
// to relaunch a force-quit app when the app target itself compiles the intent type.
//
// Why (REVIEW-2026-09-09.md, MEDIUM "The app target also compiles the widget's
// intents, producing duplicate Shortcuts actions"): this file is a member of BOTH the
// widget extension's and the main app's Sources phase, so the app's App Intents
// metadata publishes these alongside `ShelfHead/Services/PlaybackIntents.swift`'s own
// `SkipAheadIntent` ("Skip Forward") and `SkipBackIntent` ("Skip Back"). The user saw
// two identically-titled Skip Forward actions, two Skip Backs, and a Play / Pause with
// no app-side counterpart, and Siri had two candidates for a single phrase. The clean
// fix is dropping this file's main-app target membership, but that is a
// `project.pbxproj` restructure, which CLAUDE.md says to ask about first — so this is
// the code-only equivalent.
//
// `isDiscoverable = false` hides an intent from Shortcuts/Siri/Spotlight discovery
// only; it does not affect programmatic invocation, so `Button(intent:)` in the widget
// keeps working exactly as before, as does `AudioPlaybackIntent`'s ability to relaunch
// the app in the background to service a tap. The app-side intents in
// `PlaybackIntents.swift` deliberately do NOT set this and stay discoverable — they are
// the ones `ShelfHeadShortcuts` exposes phrases for.

/// Tapped from the widget's play/pause button. Posts a Darwin notification that the
/// running app observes (see AudioPlayerService) and toggles playback.
///
/// Conforming to `AudioPlaybackIntent` (not just plain `AppIntent`) matters: the system
/// treats these as "controls background audio" intents, so it's allowed to relaunch the
/// app in the background to service the request — the same mechanism Remote Command
/// Center commands rely on. Without this, when the app had been fully terminated (not
/// just backgrounded), the Darwin notification was posted into the void — nothing was
/// running to receive it — and the button silently did nothing, which is the M6 bug this
/// fixes. With plain `AppIntent`, the only way to guarantee the action happens is
/// `openAppWhenRun = true`, which would force the app to the foreground on every tap
/// even when it's already alive in the background — a worse regression than the bug.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var description = IntentDescription("Toggle audiobook playback.")

    /// Widget-button only — see the note above this section.
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.togglePlayback")
        return .result()
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward in the current book.")

    /// Widget-button only. Without this, the app target's copy of this type collides
    /// with `SkipAheadIntent` ("Skip Forward") in Shortcuts and Siri.
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.skipForward")
        return .result()
    }
}

struct SkipBackwardIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Back"
    static var description = IntentDescription("Skip back in the current book.")

    /// Widget-button only. Without this, the app target's copy of this type collides
    /// with `SkipBackIntent` ("Skip Back") in Shortcuts and Siri.
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.skipBackward")
        return .result()
    }
}

/// The large widget's chapter row. Same shape as `SkipForwardIntent`/`SkipBackwardIntent`
/// above, just a different Darwin channel — `AudioPlayerService.setupWidgetControlBridge()`
/// routes these to `PlaybackCoordinator.nextChapterFromWidget()`/`previousChapterFromWidget()`.
struct NextChapterIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Next Chapter"
    static var description = IntentDescription("Skip to the next chapter.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.nextChapter")
        return .result()
    }
}

struct PreviousChapterIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Previous Chapter"
    static var description = IntentDescription("Skip to the previous chapter.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.previousChapter")
        return .result()
    }
}

// MARK: - Control Center intents (N-2 follow-up)

/// Control Center's Play / Pause toggle (`ShelfHeadPlaybackControl`). `SetValueIntent`
/// hands us the state the person asked for, so this posts a dedicated "set" channel
/// (`setPlaying`/`setPaused`, routed to `PlaybackCoordinator.playFromWidget()`/
/// `pauseFromWidget()`) rather than the flip-only `togglePlayback`. Also
/// `AudioPlaybackIntent`, so a force-quit app is relaunched to service it.
@available(iOS 18.0, *)
struct PlaybackControlToggleIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Play / Pause"
    static var description = IntentDescription("Play or pause your current audiobook.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Playing")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling(value ? "com.shelfhead.setPlaying" : "com.shelfhead.setPaused")
        return .result()
    }
}

/// Control Center's "Resume Last Book" button. Restores the last-played book from the
/// shared snapshot (or the server's most recent in-progress one) and starts playing —
/// never pauses.
@available(iOS 18.0, *)
struct ResumeLastBookControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Resume Last Book"
    static var description = IntentDescription("Resume your most recent audiobook.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        await postDarwinAndAwaitHandling("com.shelfhead.setPlaying")
        return .result()
    }
}

/// Control Center's Sleep Timer toggle. Arms/disarms the default-length timer.
@available(iOS 18.0, *)
struct SleepTimerControlToggleIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Sleep Timer"
    static var description = IntentDescription("Start or stop the sleep timer.")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "On")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        // Nothing loaded means nothing to arm — return immediately rather than eating
        // the 5s handling wait for a no-op.
        guard SharedPlayback.read() != nil else { return .result() }
        await postDarwinAndAwaitHandling(value ? "com.shelfhead.setSleepTimerOn" : "com.shelfhead.setSleepTimerOff")
        return .result()
    }
}

/// Batch 406: the sleep timer Live Activity's one button (Lock Screen and expanded
/// Dynamic Island). Reuses the Control Center toggle's existing "off" Darwin channel, so
/// the app routes it through the same `PlaybackCoordinator.setSleepTimerFromWidget
/// (enabled: false)`; turning the timer off is what ends the activity
/// (`LiveActivityController` observes `sleepTimerOption`).
///
/// `LiveActivityIntent`, not `AudioPlaybackIntent`: it's the protocol ActivityKit
/// documents for a Live Activity's buttons, and it likewise runs `perform()` in the app's
/// process (launching it without opening it), which is where the Darwin observer lives.
/// iOS 17, unlike the Control Center intents' iOS 18 `SetValueIntent`, so it works
/// across the whole deployment range.
struct SleepTimerOffIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Turn Off Sleep Timer"
    static var description = IntentDescription("Turn off the sleep timer.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        guard SharedPlayback.read() != nil else { return .result() }
        await postDarwinAndAwaitHandling("com.shelfhead.setSleepTimerOff")
        return .result()
    }
}

/// The sleep timer Live Activity's "+15 min" button. Same shape as `SleepTimerOffIntent`;
/// the app side (`AudioPlayerService.setupWidgetControlBridge()`) calls
/// `extendSleepTimer(by: 15 * 60)`, which handles countdown and chapter-based timers.
struct SleepTimerExtendIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add 15 Minutes to Sleep Timer"
    static var description = IntentDescription("Add 15 minutes to the sleep timer.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        guard SharedPlayback.read() != nil else { return .result() }
        await postDarwinAndAwaitHandling("com.shelfhead.extendSleepTimer15")
        return .result()
    }
}

// MARK: - Control Center skip and bookmark intents (Batch 490, REVIEW 2026-11-11 F17)

/// Decision for the Control Center skip buttons. The Home Screen widget's skip path
/// deliberately resumes playback when the app has to be relaunched (`PlaybackCoordinator
/// .skipAction(... allowColdStart: true)`), which is right for a widget's play/skip tile
/// but would start sound from a Control Centre skip the listener may have pressed while
/// nothing was playing. So the controls only post while the snapshot says a book is
/// playing and fresh (same 90s rule as the Play/Pause control); otherwise they do nothing.
enum ControlSkipGuard {
    static func shouldPostSkip(snapshot: SharedPlayback.Snapshot?, now: Date = Date()) -> Bool {
        guard let snapshot else { return false }
        return snapshot.isPlaying && now.timeIntervalSince(snapshot.updatedAt) <= 90
    }
}

/// Control Center "Skip Back". Reuses the existing `com.shelfhead.skipBackward` channel.
@available(iOS 18.0, *)
struct SkipBackControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Back"
    static var description = IntentDescription("Skip back in the current book.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        guard ControlSkipGuard.shouldPostSkip(snapshot: SharedPlayback.read()) else { return .result() }
        await postDarwinAndAwaitHandling("com.shelfhead.skipBackward")
        return .result()
    }
}

/// Control Center "Skip Forward". Reuses the existing `com.shelfhead.skipForward` channel.
@available(iOS 18.0, *)
struct SkipForwardControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward in the current book.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        guard ControlSkipGuard.shouldPostSkip(snapshot: SharedPlayback.read()) else { return .result() }
        await postDarwinAndAwaitHandling("com.shelfhead.skipForward")
        return .result()
    }
}

/// Control Center "Add Bookmark". Posts `com.shelfhead.addBookmark`; the app adds a bookmark
/// at the current position only if a book is loaded (never starts playback).
@available(iOS 18.0, *)
struct AddBookmarkControlIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Add Bookmark"
    static var description = IntentDescription("Bookmark the current position in your book.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        guard SharedPlayback.read() != nil else { return .result() }
        await postDarwinAndAwaitHandling("com.shelfhead.addBookmark")
        return .result()
    }
}

/// Control Center's "Open Now Playing" button. This one legitimately foregrounds the
/// app, so plain `AppIntent` + `openAppWhenRun` (not `AudioPlaybackIntent`) is correct.
@available(iOS 18.0, *)
struct OpenNowPlayingControlIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Now Playing"
    static var description = IntentDescription("Jump to the ShelfHead player.")
    static var isDiscoverable: Bool { false }
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "shelfhead://nowplaying")!))
    }
}

private func postDarwin(_ name: String) {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString),
        nil, nil, true
    )
}

/// Posts the Darwin notification, then briefly waits for confirmation that the app
/// actually handled it before letting `perform()` return.
///
/// Why this matters: conforming to `AudioPlaybackIntent` gets `perform()` run in the
/// main app's process — launching it from fully terminated if needed — but the system
/// only keeps that process alive for as long as `perform()` hasn't returned yet. Posting
/// the Darwin notification is instantaneous; actually handling it on a cold start (wait
/// for the player view model, restore the last book from the shared snapshot, start a
/// playback session over the network, wait for the AVPlayerItem to become ready) can
/// take a couple of seconds. Returning immediately after posting gave the system no
/// reason to keep the freshly-launched process alive that long, so on a cold start the
/// resume could get silently cut short mid-flight — which matched the "still doesn't
/// resume" symptom even after the app-side restore logic was fixed. Polling the shared
/// snapshot for a fresh `updatedAt` (written once `AudioPlayerService` actually starts
/// updating Now Playing info) keeps this intent's execution open long enough for that to
/// land, with a bounded timeout so a genuinely stuck app can't hang the widget tap.
///
/// Poll finely (25ms), not coarsely: the sleep happens *before* the first check, so a
/// coarse interval means every tap waits at least one full interval before `perform()`
/// can return — even the overwhelmingly common case (app already alive in the
/// background, notification handled in single-digit milliseconds). A 500ms poll made
/// every single play/pause/skip tap feel sluggish. 25ms × 100 keeps a 2.5s ceiling for a
/// genuine cold start while letting a warm tap return in ~25ms — the loop already exits
/// the moment the snapshot's `updatedAt` moves, so this ceiling is a worst-case-only
/// wait, not the common path.
///
/// HIG audit 2026-09-17 L15: this was 200 iterations (a 5s ceiling — Control Center
/// controls that block that long read as hung). The "couple of seconds" cold-start
/// reasoning above is qualitative, not a measured figure, so there's no cited number
/// that requires a full 5s budget; halved to 100 iterations / 2.5s. If a real cold
/// start is ever measured to need longer than 2.5s, that measurement belongs in the
/// paragraph above before raising this back.
/// Widened from `private` to internal (N-2, REVIEW_2026-09-14_DESIGN.md): the new
/// Control Center control's `PlaybackControlToggleIntent` (in
/// `ShelfHeadPlaybackControl.swift`) reuses this exact helper — same Darwin
/// notification, same "wait for the snapshot to actually move" behavior — rather than
/// re-implementing the cold-start-relaunch handling a second time. Still not visible
/// outside this file's two target memberships (widget extension + main app), since
/// nothing here changed except which files in those targets may call it.
func postDarwinAndAwaitHandling(_ name: String) async {
    let requestedAt = Date()
    postDarwin(name)
    for _ in 0..<100 {
        try? await Task.sleep(nanoseconds: 25_000_000)   // 25ms
        if let snap = SharedPlayback.read(), snap.updatedAt > requestedAt {
            return
        }
    }
}
