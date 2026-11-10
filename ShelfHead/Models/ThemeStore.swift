import SwiftUI
import WidgetKit

/// Single observable source of truth for the appearance + accent-color settings.
///
/// Before this, `appearanceRaw`/`accentHex` were each declared as a separate
/// `@AppStorage` property in three different places (`ShelfHeadApp`, `MainTabView`,
/// `SettingsView`) — three independent reads of the same two UserDefaults keys, kept
/// in sync only by all three happening to observe the same key names. `ThemeStore`
/// replaces that duplication with one `@Observable` object, injected into the
/// environment once at the app root.
///
/// Note on the `.id()` calls still present in `ContentView.swift`'s `MainTabView`:
/// many views read `Color.shelfAmber` / `AppTheme.accentColor` etc. as plain static
/// computed properties (backed directly by `UserDefaults`, not the SwiftUI
/// environment), so SwiftUI has no dependency to track on those reads and won't
/// re-render them on its own when the accent changes. `ThemeStore` fixes the
/// *duplication*, but doesn't by itself remove the need for `.id()` to force those
/// subtrees to rebuild — that would require threading `ThemeStore` through every
/// accent-dependent color call site across the app (many views), which is out of
/// scope for this pass (a static-review-only change, with no compiler available here
/// to verify a refactor that size). Worth revisiting as a follow-up.
// CRIT-3 step 2 (REVIEW_2026-08-12.md): this and 3 other `@Observable` singletons
// (FavoritesStore, AppLockManager, PlaybackHistoryStore) are de-facto main-actor
// state — read/written exclusively from SwiftUI views, which are always on the main
// actor — with no annotation actually saying so. `@MainActor` above fixes that.
//
// THE CANONICAL ACCOUNT (this comment is what the other three files point back to),
// arrived at after three real-compiler rounds of getting it wrong:
//
// Round 1 (wrong): copied the `nonisolated static let shared` / `nonisolated init()`
// pattern from `DownloadManager`/`AudioPlayerService`, reasoning that a `static let`
// on a `@MainActor` class needs an explicitly `nonisolated` path to construct the
// instance. This compiles for those two services because their `init()`s never
// directly assign their own `@Observable`-tracked properties. It does NOT compile
// here, or in `FavoritesStore`/`PlaybackHistoryStore`/`AppLockManager`, all of which
// assign their own properties from inside `init()`.
//
// Round 2 (also wrong): when that failed, the theory became "a `nonisolated init()`
// may only perform an isolation-exempt *first-ever* assignment of a stored property,
// and that exemption stops applying the moment the property has an in-line default
// value at its declaration (since the default already counts as initialization)."
// This looked plausible and even seemed to fix things by removing in-line defaults —
// but the real compiler proved it wrong too: the errors came back unchanged.
//
// Round 3 (correct): the actual rule is that `@Observable`'s macro expansion turns
// EVERY `var` property into a computed property backed by `ObservationRegistrar`
// `access`/`withMutation` calls. Assigning such a property is therefore always a
// main-actor-isolated *accessor call* — never a trivial stored-property write — no
// matter whether the property has an in-line default. Swift's usual exemption ("a
// nonisolated init() may safely perform the first assignment of a stored property")
// only ever applied to true stored properties in the first place, so it was never
// available here at all, regardless of defaults.
//
// The actual fix: since every real caller of `.shared` on these four classes is
// already main-actor (SwiftUI views — none of them, unlike `DownloadManager`/
// `AudioPlayerService`, has a genuine background-thread caller via
// `URLSessionDelegate` or `NotificationCenter`), just don't mark `shared`/`init()`
// `nonisolated` at all. Leaving both as ordinary `@MainActor`-inherited members means
// `init()`'s body runs in the same isolation domain as the property accessors it
// calls — there's no cross-isolation problem to work around in the first place, and
// properties can freely keep their in-line defaults.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var appearanceRaw: String {
        didSet {
            UserDefaults.standard.set(appearanceRaw, forKey: SettingsKeys.appearance)
            // Mirror into the App Group so the widget can match the app's theme
            // instead of always rendering dark, regardless of this setting (M10).
            sharedDefaults?.set(appearanceRaw, forKey: SettingsKeys.appearance)
            // PL-8 (docs/design-review.md, Round 5): the mirrored value only matters
            // once the widget/controls re-read it, which doesn't happen on its own.
            // Skipped when the new value is the same as the old one (e.g. a binding
            // re-publishing the current selection) — didSet still fires either way.
            if appearanceRaw != oldValue { scheduleWidgetReload() }
        }
    }
    var accentHex: String {
        didSet {
            UserDefaults.standard.set(accentHex, forKey: SettingsKeys.accentColor)
            sharedDefaults?.set(accentHex, forKey: SettingsKeys.accentColor)
            recomputeCachedAccentColors()
            // PL-8 (docs/design-review.md, Round 5): see appearanceRaw's didSet above.
            if accentHex != oldValue { scheduleWidgetReload() }
        }
    }

    // MARK: - Widget / Control Center reload (PL-8, docs/design-review.md, Round 5)
    //
    // Neither WidgetKit nor Control Center notice an App Group write on their own —
    // without this, a changed accent/appearance only reaches the Home Screen widget
    // or the four Control Center controls (ShelfHeadControls.swift,
    // ShelfHeadPlaybackControl.swift — all four read `WidgetTheme.accentHex` and
    // `.tint()` to it) the next time something else (playback, library refresh)
    // happens to reload them.
    //
    // This is a pure trailing-edge debounce, not the leading+trailing throttle
    // `AudioPlayerService.reloadWidgetsThrottled()` uses: that one is tuned for a
    // value (playback position) that changes continuously and where an
    // occasional mid-burst reload is still useful. Here only the *last* colour in
    // a burst (dragging through a picker, swiping swatches) is ever shown, so
    // every change simply cancels whatever reload was pending and reschedules —
    // at most one reload fires per pause in changes.
    private var widgetReloadTask: Task<Void, Never>?

    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        // No `self` capture: the reload calls are static singletons, and ThemeStore is
        // itself a process-lifetime singleton.
        widgetReloadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            // `ControlCenter.shared.reloadAllControls()` reloads every control kind
            // the app has configured in one call, so it covers all four (the two
            // `SharedPlayback` kinds plus the resume/open-Now-Playing kinds) without
            // naming them here. iOS/iPadOS 18.0+ (confirmed via scripts/appledoc.sh
            // against developer.apple.com/documentation/widgetkit/controlcenter/
            // reloadallcontrols()), so it's gated for the iOS 17.6 deployment floor;
            // below iOS 18 the controls just pick up the new value next time their
            // own state-driven reload runs (AudioPlayerService.publishControlState).
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadAllControls()
            }
        }
    }

    // MARK: - Cached accent colors (UI-8, REVIEW_2026-08-12.md)
    //
    // `AppTheme.accentColor`/`onAccentColor`/`accentTextColor`/`accentDarkColor` (the
    // `Color.shelfAmber`/`onAccent`/`shelfAmberText`/`shelfAmberDark` family) used to
    // recompute themselves from scratch — a `UserDefaults` read plus a `Scanner`-based
    // hex parse, or worse, the full iterative contrast search for the text variant — on
    // *every single access*, of which there are 211 across the app. `ThemeStore` is
    // already the one place that knows exactly when `accentHex` actually changes (this
    // `didSet`), so it's the natural single owner of the derived `Color` values: compute
    // once here, and every one of those 211 call sites just reads the cached result.

    private(set) var cachedAccentColor: Color
    private(set) var cachedOnAccentColor: Color
    private(set) var cachedAccentTextColor: Color
    private(set) var cachedAccentDarkColor: Color
    /// Critique 2026-10-06 (colorize): accent text tuned for `shelfSurface`/`shelfCard`.
    private(set) var cachedAccentTextOnSurface: Color

    // F1 (REVIEW_2026-09-04_UI.md): the secondary/emphasis pair now follows the accent
    // (see `AppTheme.hueHarmonizedHex`), which makes them derived values with exactly
    // the same recompute-on-change lifetime as the four above — and the same reason to
    // be cached. `computeSecondaryAccentTextColor` in particular runs the iterative
    // contrast search twice, which is not something to repeat per call site.
    private(set) var cachedSecondaryAccent: Color
    private(set) var cachedSecondaryAccentText: Color
    private(set) var cachedEmphasis: Color
    private(set) var cachedEmphasisInk: Color

    private func recomputeCachedAccentColors() {
        cachedAccentColor = AppTheme.computeAccentColor(hex: accentHex)
        cachedOnAccentColor = AppTheme.computeOnAccentColor(hex: accentHex)
        cachedAccentTextColor = AppTheme.computeAccentTextColor(hex: accentHex)
        cachedAccentDarkColor = AppTheme.computeAccentDarkColor(hex: accentHex)
        cachedAccentTextOnSurface = AppTheme.computeAccentTextOnSurfaceColor(hex: accentHex)
        cachedSecondaryAccent = AppTheme.computeSecondaryAccentColor(accentHex: accentHex)
        cachedSecondaryAccentText = AppTheme.computeSecondaryAccentTextColor(accentHex: accentHex)
        cachedEmphasis = AppTheme.computeEmphasisColor(accentHex: accentHex)
        cachedEmphasisInk = AppTheme.computeEmphasisInkColor(accentHex: accentHex)
    }

    // Left `nonisolated` (harmless, not strictly required now that `init()` below is
    // plain `@MainActor` too): pure construction of a `UserDefaults` handle, no
    // actor-isolated state touched.
    private nonisolated var sharedDefaults: UserDefaults? { UserDefaults(suiteName: SharedPlayback.appGroup) }

    private init() {
        appearanceRaw = UserDefaults.standard.string(forKey: SettingsKeys.appearance) ?? AppAppearance.dark.rawValue
        let initialAccentHex = UserDefaults.standard.string(forKey: SettingsKeys.accentColor) ?? AppTheme.defaultAccentHex
        // Seed the four caches directly, from a local `let` rather than reading
        // `self.accentHex` (which isn't assigned yet at this point in `init`), and
        // *before* `accentHex` itself is assigned below. Property observers on a
        // class's own stored property are only guaranteed to fire once every stored
        // property has an initial value ("phase 1" of two-phase init) — assigning
        // `accentHex` last, after these four already have values, means this compiles
        // and behaves correctly whether or not `didSet` also happens to fire on that
        // final assignment (if it does, `recomputeCachedAccentColors()` just redundantly
        // recomputes the same values this already set — harmless, and only ever once,
        // at launch).
        cachedAccentColor = AppTheme.computeAccentColor(hex: initialAccentHex)
        cachedOnAccentColor = AppTheme.computeOnAccentColor(hex: initialAccentHex)
        cachedAccentTextColor = AppTheme.computeAccentTextColor(hex: initialAccentHex)
        cachedAccentDarkColor = AppTheme.computeAccentDarkColor(hex: initialAccentHex)
        cachedAccentTextOnSurface = AppTheme.computeAccentTextOnSurfaceColor(hex: initialAccentHex)
        cachedSecondaryAccent = AppTheme.computeSecondaryAccentColor(accentHex: initialAccentHex)
        cachedSecondaryAccentText = AppTheme.computeSecondaryAccentTextColor(accentHex: initialAccentHex)
        cachedEmphasis = AppTheme.computeEmphasisColor(accentHex: initialAccentHex)
        cachedEmphasisInk = AppTheme.computeEmphasisInkColor(accentHex: initialAccentHex)
        accentHex = initialAccentHex
        // Seed the App Group on init too — not just on next change — so a widget added
        // right after first launch (before the user has touched Settings) still matches.
        sharedDefaults?.set(appearanceRaw, forKey: SettingsKeys.appearance)
        sharedDefaults?.set(accentHex, forKey: SettingsKeys.accentColor)
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: appearanceRaw) ?? .dark }
        set { appearanceRaw = newValue.rawValue }
    }
}
