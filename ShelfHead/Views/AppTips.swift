import TipKit

/// Stage 6 (REDESIGN_PROPOSAL_2026-08-26.md §10): three TipKit tips, each shown once,
/// each dismissible, no in-app onboarding flow to maintain. §10's own reasoning for why
/// this — not a first-run walkthrough — is the right amount of discoverability: this
/// app's actual first run is a server URL and credentials, not a screen a walkthrough
/// carousel would help with, and B-side already has a real labelled row (no tip needed,
/// would be redundant with Batch 218's own fix).
///
/// `Tips.configure(...)` is called once from `ShelfHeadApp.init()`. Each tip's
/// `@Parameter` is donated to from wherever its trigger actually happens; see each
/// property's own call site for the donation. TipKit is iOS 17+, which is within this
/// app's iOS 17.6+ deployment target, so no `@available` gate is needed here.
///
/// **[device check]**: TipKit's actual on-screen timing/frequency behavior (e.g.
/// `.displayFrequency`, how `popoverTip` decides *when* within a session to actually
/// pop up once its rule is satisfied) can't be verified without a simulator or device —
/// the rules below are written to match the proposal's intent, but the felt experience
/// (does it feel naggy, does it appear at a good moment) needs an on-device pass.
enum AppTips {
    /// Call once, at app launch, before any tip could plausibly be attached to a view.
    static func configure() {
        try? Tips.configure([
            // Code review fix (26 August 2026): TipKit hygiene — `.immediate` means no
            // cooldown between any of this app's three tips, so a session that happens
            // to satisfy more than one rule in quick succession (e.g. a long drive that
            // crosses the fine-scrub and Driving Mode thresholds close together) could
            // surface them back-to-back. `.daily` is TipKit's safer default: still lets
            // each tip show the first time its own rule is satisfied, just caps how
            // often *any* tip in the group can appear.
            .displayFrequency(.daily),
            .datastoreLocation(.applicationDefault)
        ])
    }
}

/// Shown after the user's third completed fine-scrub (see `TapeScrubber`'s `.onEnded`
/// donation) — arrives once fine-scrubbing is already something they've stumbled into
/// and done more than once, not on the first screen they meet it.
struct FineScrubTip: Tip {
    @Parameter
    static var scrubCount: Int = 0

    var title: Text {
        Text("Drag down to fine-tune")
    }
    var message: Text? {
        Text("While scrubbing, drag your finger down for slower, more precise control.")
    }
    var image: Image? {
        Image(systemName: "hand.draw")
    }
    var rules: [Rule] {
        #Rule(Self.$scrubCount) { $0 >= 3 }
    }
}

/// Shown the second time the full player is opened (see `PlayerView`'s donation on
/// appear) — the first open is for getting oriented; by the second, "tap the cover"
/// is worth surfacing.
struct CassetteFlipTip: Tip {
    @Parameter
    static var playerOpenCount: Int = 0

    var title: Text {
        Text("Tap the cover to flip it")
    }
    var message: Text? {
        Text("Flip to the cassette view for a tape-deck look at what's playing.")
    }
    var image: Image? {
        Image(systemName: "arrow.2.squarepath")
    }
    var rules: [Rule] {
        #Rule(Self.$playerOpenCount) { $0 >= 2 }
    }
}

/// Shown once cumulative full-player playback time (see `PlayerView`'s donation, which
/// accumulates real elapsed time only while the full player is open and actually
/// playing) passes ~20 minutes — long enough that a commute or a drive is a reasonable
/// guess, which is exactly when Driving Mode is worth knowing about.
///
/// Code review fix (26 August 2026): `minutesPlayedLifetime` is a *persisted* `@Parameter`
/// — it was previously named `minutesPlayedThisSession` and both its own doc comment and
/// `PlayerView`'s donation-site comment called it "this session," but it's never reset
/// except by the Settings "Reset Tips" button, so it actually accumulates across the
/// app's entire lifetime. Renamed to match what it actually is. Also added
/// `drivingModeOpened`, tracked alongside the existing `invalidate(reason:)` call at the
/// real trigger point (opening Driving Mode) — the counter's own loop in `PlayerView`
/// has no way to know the tip was already retired and would otherwise keep incrementing
/// (and writing to TipKit's datastore) for up to another ~15 minutes of playback past
/// the moment the tip stopped being showable.
struct DrivingModeTip: Tip {
    @Parameter
    static var minutesPlayedLifetime: Int = 0
    @Parameter
    static var drivingModeOpened: Bool = false

    var title: Text {
        Text("Driving Mode")
    }
    var message: Text? {
        Text("Big buttons, one glance — in here for long sessions on the move.")
    }
    var image: Image? {
        Image(systemName: "car.fill")
    }
    var rules: [Rule] {
        #Rule(Self.$minutesPlayedLifetime) { $0 >= 20 }
        #Rule(Self.$drivingModeOpened) { $0 == false }
    }
}
