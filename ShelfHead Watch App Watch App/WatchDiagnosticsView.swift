import SwiftUI

/// P-9 item 1 (REVIEW_2026-09-14_DESIGN.md, "the Watch app is two different apps").
///
/// `WatchModeSettingsView` used to sit in `SettingsView`'s own "Watch Mode" section,
/// one tap from the root, asking every user to choose between Automatic, Always
/// Companion and Always Standalone. That is a question about the app's internal
/// architecture — which of two playback/networking stacks should run — dressed up as a
/// product setting, and the two non-Automatic answers exist because of a specific
/// on-device bug report (28 August 2026; see `WatchStore.ModePreference`), not because
/// anyone wants to manage it day to day.
///
/// Automatic is now the only mode presented as a choice. The override is not deleted —
/// `WatchStore.ModePreference` and its `UserDefaults` persistence are untouched, and
/// the picker still works exactly as before — it's moved behind this screen, which
/// says plainly that it's for troubleshooting.
///
/// This screen is also where the app's own "what is it actually doing right now"
/// readout lives, so someone sent here by a support answer can see the inputs
/// (`mode`, reachability, session) before reaching for the override. Connection status
/// deliberately stays duplicated on `SettingsView` as well: "is what I'm seeing
/// current" is safety-relevant information, not diagnostics, and shouldn't have been
/// moved two taps away.
struct WatchDiagnosticsView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        List {
            Section("Right Now") {
                WatchRow(
                    systemImage: modeSystemImage,
                    title: activeModeTitle,
                    subtitle: activeModeSubtitle)

                WatchRow(
                    // `iphone.slash` rather than an `iphone.gen3.slash` to match the
                    // `iphone.gen3` above: the gen-suffixed symbols don't all ship a
                    // `.slash` variant, and a missing SF Symbol renders as nothing at
                    // all with no build error. PL-15 (docs/design-review.md, Round 5):
                    // confirmed, not guessed. The SF Symbols availability data on this
                    // Mac (CoreGlyphs `name_availability.plist`) lists `iphone.slash` in
                    // the 2020 set, which maps to watchOS 7.0; this target's minimum is
                    // watchOS 10.0. `iphone.gen3` is in the 2022.1 set (watchOS 9.1).
                    systemImage: store.isReachable ? "iphone.gen3" : "iphone.slash",
                    title: store.isReachable ? "iPhone Reachable" : "iPhone Not Reachable",
                    subtitle: store.isStateStale ? "Playback state may be out of date" : "Playback state is fresh",
                    // Critique 2026-10-06 (colorize): neutral when reachable (was green).
                    tintColor: store.isReachable ? nil : WatchTheme.secondaryText)

                WatchRow(
                    systemImage: "key",
                    title: "This Watch's Session",
                    subtitle: sessionSubtitle,
                    tintColor: store.authState == .sessionExpired ? WatchTheme.danger : nil)
            }

            // Critique 2026-10-06 (shape → harden): the "Watch Mode" override that sat
            // here under "Troubleshooting" is now Settings > Play On, in plain words. This
            // screen keeps the readout.
        }
        // Batch 490 (REVIEW 2026-11-11 W14): default list style; the No-Carousel Rule
        // (DESIGN.md) missed this screen in Batch 412.
        .navigationTitle("Diagnostics")
    }

    private var modeSystemImage: String {
        store.mode == .standalone ? "applewatch" : "iphone"
    }

    private var activeModeTitle: LocalizedStringResource {
        store.mode == .standalone ? "Playing on This Watch" : "Controlling iPhone"
    }

    /// Says *why* the app landed in the mode it's in, which is the whole reason this
    /// row is worth having: the answer is different depending on whether the override
    /// is involved.
    private var activeModeSubtitle: LocalizedStringResource {
        // Critique 2026-10-06 (shape → harden): a book loaded on this Watch holds it
        // here whatever Play On says (`WatchStore.nextMode`), so say that first.
        if store.mode == .standalone && store.standalone.isLoaded {
            return "A book is loaded on this Watch"
        }
        switch store.modePreference {
        case .automatic:
            return store.mode == .standalone ? "Your iPhone isn\u{2019}t nearby" : "Your iPhone is nearby"
        case .alwaysCompanion:
            return "Play On is set to iPhone"
        case .alwaysStandalone:
            return store.mode == .standalone ? "Play On is set to This Watch" : "Play On is set to This Watch, but it isn\u{2019}t signed in"
        }
    }

    private var sessionSubtitle: LocalizedStringResource {
        switch store.authState {
        case .checking: return "Checking…"
        case .noSession: return "Not signed in on this Watch"
        case .active: return store.sessionKind == .shared ? "Signed in (borrowed from iPhone)" : "Signed in"
        case .sessionExpired: return "Expired"
        }
    }
}

#Preview {
    NavigationStack { WatchDiagnosticsView() }
        .environment(WatchStore.shared)
}
