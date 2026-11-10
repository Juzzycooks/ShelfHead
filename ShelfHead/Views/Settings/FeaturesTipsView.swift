import SwiftUI
import TipKit

/// Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10, §7c): the cheap, no-flow-to-maintain
/// half of this app's discoverability answer — a short static list of things the app
/// does that you'd otherwise have to stumble into, plus a way to see the three TipKit
/// tips (`AppTips.swift`) again. Deliberately not a tour or a carousel: just a list,
/// reached from Settings > About, for the person who wants to go looking rather than
/// wait to be told.
struct FeaturesTipsView: View {
    var bottomInset: CGFloat = 0
    /// Critique 2026-10-06 (clarify): the `SettingsRow` a search result opened, if any.
    var focusRow: String? = nil
    @State private var didResetTips = false

    private struct Feature: Identifiable {
        /// A `SettingsRow` id: stable, so search can scroll to it (was a fresh `UUID()`).
        let id: String
        let icon: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        /// Critique 2026-10-06 (clarify): the Settings page that configures this feature,
        /// when there is one, so the row opens it instead of only describing it.
        var settingsPage: SettingsPage? = nil
        var settingsRow: String? = nil
    }

    private let features: [Feature] = [
        Feature(id: SettingsRow.featureBSide, icon: "shuffle", title: "B-Side",
                detail: "Play a random book you haven’t started — from Home, or the shuffle row in Library."),
        Feature(id: SettingsRow.featureCassette, icon: "arrow.2.squarepath", title: "Cassette view",
                detail: "Tap the cover in the full player to flip to a tape-deck view of what’s playing."),
        Feature(id: SettingsRow.featureFineScrub, icon: "hand.draw", title: "Fine-scrub",
                detail: "While dragging the scrubber, drag down for slower, more precise seeking."),
        Feature(id: SettingsRow.featureDrivingMode, icon: "car.fill", title: "Driving Mode",
                detail: "Big buttons, one glance — in the full player’s ⋯ menu."),
        Feature(id: SettingsRow.featureSleepShake, icon: "moon.zzz.fill", title: "Sleep timer, shake to extend",
                detail: "With a sleep timer running, shake your phone to extend it.",
                settingsPage: .sleepTimer, settingsRow: SettingsRow.shakeGesture),
        Feature(id: SettingsRow.featureWidget, icon: "apps.iphone.badge.plus", title: "Home Screen widget",
                detail: "Add the ShelfHead widget for at-a-glance progress and quick controls."),
        Feature(id: SettingsRow.featureWatch, icon: "applewatch", title: "Watch app",
                detail: "Control playback, browse chapters, and see bookmarks from your wrist."),
    ]

    @ViewBuilder
    private func featureLabel(_ feature: Feature) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.icon)
                // VD-7 (docs/design-review.md, Round 4): leads the row's title
                // text (default `.body` styling), so scale with it — `minWidth`
                // below (was a fixed `width`) lets the leading column grow with
                // it instead of clipping the glyph at AX sizes.
                .scaledFont(16, relativeTo: .body)
                // Critique 2026-10-06 (distill): muted, like every other Settings row
                // glyph; the accent is for action or live state (One Light Rule).
                .foregroundStyle(Color.shelfMuted)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .foregroundStyle(Color.shelfCream)
                Typo.supporting(Text(feature.detail))
                    .foregroundStyle(Color.shelfMuted)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        SettingsAnchoredList(focusRow: focusRow) {
            Section {
                ForEach(features) { feature in
                    Group {
                        if let page = feature.settingsPage {
                            NavigationLink {
                                SettingsDestinationView(page: page, bottomInset: bottomInset,
                                                        focusRow: feature.settingsRow)
                            } label: {
                                featureLabel(feature)
                            }
                            .accessibilityHint("Opens \(page.title) settings")
                        } else {
                            featureLabel(feature)
                        }
                    }
                    .settingsRowAnchor(feature.id)
                }
            } header: {
                RetroSectionHeader(title: "Features")
            }
            .listRowBackground(Color.shelfCard)

            Section {
                Button {
                    // Stage 6: honest about what this actually does — TipKit's own
                    // `resetDatastore()` is documented to run *before* `Tips.configure()`
                    // (called once at launch, in `ShelfHeadApp.init()`), so calling it
                    // mid-session doesn't retroactively un-dismiss a tip already shown
                    // this launch. What this button can do right now: zero each tip's
                    // own trigger counter, so the *next* time its trigger condition is
                    // met from scratch, it's eligible again; `resetDatastore()` is also
                    // called so a fresh launch starts clean. **[device check]** — the
                    // exact boundary of what "reappears immediately" vs. "reappears next
                    // launch" looks like in practice needs an on-device TipKit session
                    // to confirm; the subtitle below is written to not overpromise.
                    FineScrubTip.scrubCount = 0
                    CassetteFlipTip.playerOpenCount = 0
                    DrivingModeTip.minutesPlayedLifetime = 0
                    // Code review fix (26 August 2026): added alongside `drivingModeOpened`
                    // itself — resetting the counter but leaving this `true` would leave
                    // `DrivingModeTip`'s own rule permanently unsatisfiable after "Show
                    // tips again."
                    DrivingModeTip.drivingModeOpened = false
                    try? Tips.resetDatastore()
                    didResetTips = true
                    Haptics.success()
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                            .frame(width: 24)
                        Text(didResetTips ? "Tips reset" : "Show tips again")
                    }
                }
                .disabled(didResetTips)
            } header: {
                RetroSectionHeader(title: "Tips")
            } footer: {
                // Critique 2026-10-06 (distill): Typo.supporting, like every other
                // Settings footer, and shorter.
                Typo.supporting(Text("Each tip can appear again when its moment comes around. One already shown this launch may need a relaunch."))
                    .foregroundStyle(Color.shelfMuted)
            }
            .listRowBackground(Color.shelfCard)
        }
        .background(Color.shelfBackground.ignoresSafeArea())
        .navigationTitle("Features & Tips")
        .navigationBarTitleDisplayMode(.inline)
        .reexpandsTabBarOnAppear()
    }
}

#Preview {
    NavigationStack {
        FeaturesTipsView()
    }
}
