import XCTest
@testable import ShelfHead

/// Batch 321: cover for `TabBarMinimizeCoordinator`, the one-property state machine
/// behind "the iOS 26 tab bar minimises on scroll-down everywhere, and comes back when
/// a screen appears."
///
/// What's pinned here is the decision, not the effect: whether `suspended` is `true`
/// (so `MainTabView.modernTabs` passes `.tabBarMinimizeBehavior(.never)`) or `false`
/// (`.onScrollDown`), and how it behaves across repeated and overlapping calls. Whether
/// flipping that value actually re-expands the bar is a UIKit/SwiftUI behaviour this
/// project can only confirm on device — that half stays a **[device check]**, the same
/// split `SmartFilterShelfTests` draws between a seed's decision and its UserDefaults
/// round trip.
///
/// Every test drives its own instance with an injected `window` rather than
/// `TabBarMinimizeCoordinator.shared`, so nothing here depends on the 100ms production
/// window (or on test ordering against a shared singleton). The synchronous assertions
/// don't sleep at all; the two that must observe the restore wait on a generous
/// multiple of a deliberately tiny window rather than racing it.
@MainActor
final class TabBarMinimizeCoordinatorTests: XCTestCase {

    /// Short enough that the restore lands well inside any wait below, long enough that
    /// it is still a real suspend-then-restore rather than a same-tick no-op.
    private let window: Duration = .milliseconds(5)

    /// Comfortably past `window`, so a slow CI machine doesn't turn a passing restore
    /// into a flake. Cheap: it's a handful of milliseconds even at 40x.
    private func waitPastWindow() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - The suspend decision (no timing involved)

    /// A freshly built coordinator must not be suspended — otherwise the TabView would
    /// start life on `.never` and the very first scroll-down wouldn't minimise anything.
    func testStartsUnsuspended() {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        XCTAssertFalse(coordinator.suspended)
    }

    /// The load-bearing half of the whole mechanism, and the part with no timing in it:
    /// `reexpand()` must flip `suspended` synchronously, in the same turn of the runloop
    /// the caller is on. If this were deferred, the screen that just appeared could
    /// render (and be scrolled) before `.never` was ever handed to the TabView.
    func testReexpandSuspendsSynchronously() {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        coordinator.reexpand()
        XCTAssertTrue(coordinator.suspended)
    }

    /// A burst — a tab switch plus the destination screen's own
    /// `reexpandsTabBarOnAppear()` landing in the same frame — must stay suspended
    /// throughout rather than the second call finding the flag already set and the first
    /// call's pending restore clearing it early.
    func testRepeatedReexpandStaysSuspended() {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        coordinator.reexpand()
        coordinator.reexpand()
        coordinator.reexpand()
        XCTAssertTrue(coordinator.suspended)
    }

    // MARK: - The restore

    /// `.never` is a momentary state, never a resting one: once the window elapses the
    /// coordinator must hand control back to `.onScrollDown`, or the app would be left
    /// in exactly the "tab bar never minimises" state Batch 320 shipped and this batch
    /// is undoing.
    func testRestoresAfterWindow() async {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        coordinator.reexpand()
        await waitPastWindow()
        XCTAssertFalse(coordinator.suspended)
    }

    /// The restore has to survive being re-armed: an earlier call's timer is cancelled
    /// by a later one, so if cancellation were mishandled (the old task clearing the
    /// flag, or the new one never being created) the coordinator would either restore
    /// too early or stick on `.never` forever.
    func testRestoresAfterAReArmedWindow() async {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        coordinator.reexpand()
        coordinator.reexpand()
        XCTAssertTrue(coordinator.suspended)
        await waitPastWindow()
        XCTAssertFalse(coordinator.suspended)
    }

    /// Re-arming after a completed cycle works the same as the first time — the state
    /// machine has no "already used" latch. This is the every-push-and-pop case: a
    /// screen appearing hours into a session must suspend exactly as it does on the
    /// first one.
    func testReexpandWorksAgainAfterRestoring() async {
        let coordinator = TabBarMinimizeCoordinator(window: window)
        coordinator.reexpand()
        await waitPastWindow()
        XCTAssertFalse(coordinator.suspended)

        coordinator.reexpand()
        XCTAssertTrue(coordinator.suspended)
        await waitPastWindow()
        XCTAssertFalse(coordinator.suspended)
    }

    /// The app only ever uses `shared`, which takes the defaulted window — pinned so a
    /// future edit can't quietly stretch the production value into a range where a real
    /// scroll-down gesture could start inside it and be swallowed by `.never`.
    func testSharedInstanceUsesTheProductionWindow() {
        XCTAssertEqual(TabBarMinimizeCoordinator.shared.window, .milliseconds(100))
    }
}
