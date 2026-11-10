import Foundation

/// P3-6 (third-pass review, 14 Aug 2026): the skip-back/skip-forward glyph and
/// VoiceOver label logic used to be duplicated across four surfaces, three of which
/// hardcoded 15/30 seconds regardless of the user's actual
/// `SettingsStore.skipBackwardInterval`/`skipForwardInterval` — only the widget
/// (`ShelfHeadWidgets.swift`'s own private `skipSymbolName`/`skipAccessibilityLabel`,
/// added for WATCH-3) got this right. The main iOS player (`PlayerView.swift`, the
/// highest-traffic of the four surfaces) showed a hardcoded "gobackward.15"/
/// "goforward.30" glyph and matching fixed VoiceOver label no matter what the user had
/// configured; the Watch app's `PlaybackControlsView.swift` hardcoded
/// "goforward.15"/"Forward 15 seconds" even though `store.forward()` itself already
/// resolves the real synced interval — wrong even at the 30 s default.
///
/// One shared, pure implementation instead: this file is added directly (not
/// hand-duplicated) to the app, widget, and watch app targets' Sources build phases,
/// the same pattern already used for `SharedPlayback.swift` (app + widget) and
/// `WatchModels.swift` (app + watch) — see those files' own header comments for why a
/// hand-duplicated copy is exactly the setup that invites silent drift.
///
/// **Explicitly `nonisolated` (fix 9, REVIEW-2026-09-09.md).** Being in three targets'
/// Sources phases is precisely why: the app compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, the Watch app with `MainActor`, and the
/// widget extension with neither set — so these two pure functions were implicitly
/// `@MainActor` in one target and nonisolated in the other two, from the same source.
/// Both are pure string/`Int` computation over their arguments with no state at all, so
/// nonisolated is the honest contract, and pinning it means a future non-main caller
/// (a widget timeline provider, a Watch complication) can't be blocked by an isolation
/// this file never meant to have. See `AuthStore`'s header for the build break the
/// unannotated version of this hazard actually caused.
nonisolated enum SkipLabels {
    /// SF Symbols only ships "gobackward.N"/"goforward.N" variants for a fixed set of
    /// second counts — not every value the interval settings can actually be set to.
    /// Snaps to the closest symbol Apple actually ships rather than falling back to a
    /// generic icon, so the glyph at least reads as "about this many seconds" even
    /// when it can't be exact; the accessibility label below always states the real
    /// configured value regardless of which glyph got picked.
    private static let supportedSymbolSeconds: [Int] = [5, 10, 15, 30, 45, 60, 75, 90]

    static func symbolName(backward: Bool, seconds: Double?) -> String {
        let requested = Int((seconds ?? (backward ? 15 : 30)).rounded())
        let nearest = supportedSymbolSeconds.min(by: { abs($0 - requested) < abs($1 - requested) }) ?? (backward ? 15 : 30)
        return (backward ? "gobackward." : "goforward.") + String(nearest)
    }

    static func accessibilityLabel(backward: Bool, seconds: Double?) -> String {
        let value = Int((seconds ?? (backward ? 15 : 30)).rounded())
        return backward
            ? String(localized: "Skip back \(value) seconds", comment: "Accessibility label for the skip-back button. %lld is the number of seconds.")
            : String(localized: "Skip forward \(value) seconds", comment: "Accessibility label for the skip-forward button. %lld is the number of seconds.")
    }
}
