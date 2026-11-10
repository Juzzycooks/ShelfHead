import SwiftUI

/// The Sleep Timer page's section (its own page from the Settings root since Critique
/// 2026-10-06, distill; previously part of "Playback & Appearance") — split out of the
/// original monolithic "Playback" section (UI-12, REVIEW_2026-08-12.md). Grouped
/// together because each of these settings governs the same decision: what happens to
/// playback near bedtime, whether triggered automatically (fade-out, smart/scheduled
/// timers) or by gesture (shake).
struct SleepTimerSettingsSection: View {
    @AppStorage(SettingsKeys.sleepFadeOut) private var sleepFadeOut = true
    @AppStorage(SettingsKeys.smartSleepTimer) private var smartSleepTimer = true
    @AppStorage(SettingsKeys.scheduledSleepTimerEnabled) private var scheduledSleepTimerEnabled = false
    @AppStorage(SettingsKeys.scheduledSleepTimerStartHour) private var scheduledSleepTimerStartHour = 22
    @AppStorage(SettingsKeys.scheduledSleepTimerStartMinute) private var scheduledSleepTimerStartMinute = 0
    @AppStorage(SettingsKeys.scheduledSleepTimerEndHour) private var scheduledSleepTimerEndHour = 7
    @AppStorage(SettingsKeys.scheduledSleepTimerEndMinute) private var scheduledSleepTimerEndMinute = 0
    @AppStorage(SettingsKeys.scheduledSleepTimerDurationMinutes) private var scheduledSleepTimerDurationMinutes = 30
    @AppStorage(SettingsKeys.defaultSleepTimerMinutes) private var defaultSleepTimerMinutes = 30
    // HIG audit 2026-09-17 M1: default changed from `.reset` to `.off` — shake is the
    // system's own undo/redo gesture (HIG Gestures, Undo and redo), so repurposing it
    // should be an opt-in choice rather than the out-of-the-box behaviour. Matches
    // `SettingsStore.shakeAction`'s fallback; not a retroactive migration for anyone who
    // already has a value written (see that property's doc comment).
    @AppStorage(SettingsKeys.shakeAction) private var shakeAction = ShakeAction.off.rawValue

    /// Bridges the stored scheduled-sleep-timer start hour/minute to a DatePicker Date.
    private var scheduledSleepStartBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: scheduledSleepTimerStartHour, minute: scheduledSleepTimerStartMinute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                scheduledSleepTimerStartHour = c.hour ?? 22
                scheduledSleepTimerStartMinute = c.minute ?? 0
            }
        )
    }

    /// Bridges the stored scheduled-sleep-timer end hour/minute to a DatePicker Date.
    private var scheduledSleepEndBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: scheduledSleepTimerEndHour, minute: scheduledSleepTimerEndMinute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                scheduledSleepTimerEndHour = c.hour ?? 7
                scheduledSleepTimerEndMinute = c.minute ?? 0
            }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: $sleepFadeOut) {
                settingRow("speaker.wave.1.fill", "Fade out before sleep")
            }
            .settingsRowAnchor(SettingsRow.sleepFadeOut)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $smartSleepTimer) {
                    settingRow("moon.stars.fill", "Smart sleep timer")
                }
                // Critique 2026-10-06 (distill): one line, detail behind the ⓘ.
                SettingsCaption(text: "Stops at a nearby chapter break.",
                                topic: "Smart sleep timer",
                                detail: "If a timer like \u{201C}30 min\u{201D} would end within a few minutes of a chapter break, it stops at the break instead of mid-sentence.")
            }
            .settingsRowAnchor(SettingsRow.smartSleepTimer)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $scheduledSleepTimerEnabled) {
                    settingRow("bed.double.fill", "Scheduled sleep timer")
                }
                .onChange(of: scheduledSleepTimerEnabled) { _, enabled in
                    // Deliberately re-enabling from here means "I want this again,
                    // starting now" — clear any lingering "skip tonight" suppression
                    // rather than have a stale one silently swallow the next session.
                    if enabled { SettingsStore.clearScheduledSleepTimerSuppression() }
                }
                SettingsCaption(text: "Arms a \(scheduledSleepTimerDurationMinutes)-minute timer at bedtime.",
                                topic: "Scheduled sleep timer",
                                detail: "Starting a book during your bedtime window sets the sleep timer for you, so you don\u{2019}t have to remember.")
            }
            .settingsRowAnchor(SettingsRow.scheduledSleepTimer)
            // P-8 (REVIEW_2026-09-14_DESIGN.md): these used to pass `settingRow(...)`
            // straight in as the `DatePicker`/`Picker`'s own `label:` — the icon and
            // title stayed coupled (unlike `PlaybackSettingsSection`'s old "Default
            // Speed" bug), but the control itself had no accessibility-size fallback:
            // at AX3+ the label and the trailing compact date/value both fought for
            // the same line. `SettingsControlRow` moves the control below the label
            // once Dynamic Type crosses into accessibility sizes; below that it's
            // still `LabeledContent`, label leading/control trailing as before.
            if scheduledSleepTimerEnabled {
                SettingsControlRow(icon: "moon.fill", title: "Window start") {
                    DatePicker("Window start", selection: scheduledSleepStartBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                SettingsControlRow(icon: "sunrise.fill", title: "Window end") {
                    DatePicker("Window end", selection: scheduledSleepEndBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                SettingsControlRow(icon: "timer", title: "Timer length") {
                    Picker("Timer length", selection: $scheduledSleepTimerDurationMinutes) {
                        ForEach([15, 20, 30, 45, 60], id: \.self) { mins in
                            Text("\(mins) min").tag(mins)
                        }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                SettingsControlRow(icon: "switch.2", title: "Control Centre timer") {
                    Picker("Control Centre timer", selection: $defaultSleepTimerMinutes) {
                        ForEach([5, 10, 15, 30, 45, 60], id: \.self) { mins in
                            Text("\(mins) min").tag(mins)
                        }
                    }
                    .labelsHidden()
                }
                SettingsCaption(text: "Used by the Sleep Timer control.",
                                topic: "Control Centre timer",
                                detail: "The length the Sleep Timer control in Control Centre sets. Add the control from Control Centre\u{2019}s edit screen.")
            }
            .settingsRowAnchor(SettingsRow.controlCenterTimer)

            VStack(alignment: .leading, spacing: 4) {
                SettingsControlRow(icon: "iphone.radiowaves.left.and.right", title: "Shake gesture") {
                    Picker("Shake gesture", selection: $shakeAction) {
                        ForEach(ShakeAction.allCases) { action in
                            Text(action.label).tag(action.rawValue)
                        }
                    }
                    .labelsHidden()
                }
                SettingsCaption(text: "What shaking your phone does during playback.",
                                topic: "Shake gesture",
                                detail: "\u{201C}Reset sleep timer\u{201D} restarts the countdown. \u{201C}Extend +15 min\u{201D} adds time to a running timer. \u{201C}Off\u{201D} turns the gesture off.")
            }
            .settingsRowAnchor(SettingsRow.shakeGesture)
        } header: {
            RetroSectionHeader(title: "Sleep Timer")
        }
        .listRowBackground(Color.shelfCard)
        // AN-6 (docs/design-review.md, Round 6): animate the Window start/end/Timer
        // length rows sliding in and out when "Scheduled sleep timer" is toggled,
        // instead of the layout jumping instantly. List animates the row
        // insertion/removal itself once the change lands in an animated transaction;
        // `.shelfAnimation` is a no-op (nil animation) under Reduce Motion.
        .shelfAnimation(.default, value: scheduledSleepTimerEnabled)
    }
}
