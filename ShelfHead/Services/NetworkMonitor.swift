import Foundation
import Network

/// Lightweight reachability used to gate Wi-Fi-only downloads.
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.shelfhead.networkmonitor")
    private let lock = NSLock()
    private var _isConnected = true
    private var _isOnWiFi = true

    var isConnected: Bool { lock.withLock { _isConnected } }
    var isOnWiFi: Bool { lock.withLock { _isOnWiFi } }

    /// Callbacks invoked (on the monitor queue, i.e. NOT the main actor) when
    /// connectivity is re-established after being offline. An observer *list* —
    /// multiple consumers can register (previously a single assignable closure
    /// silently overwrote earlier ones).
    ///
    /// ARCH-2: these are typed `@Sendable` deliberately, not just `() -> Void`. A
    /// plain `() -> Void` accepted `AudioPlayerService.swift`'s main-actor-isolated
    /// closure (formed inside a `@MainActor init()`, so it inherited that isolation)
    /// without the compiler ever objecting — and it was then invoked here on
    /// `queue` (`com.shelfhead.networkmonitor`), not the main actor, so
    /// `flushPendingProgress()` (a `@MainActor` method) ran its synchronous prologue on
    /// a background queue every time connectivity was restored. A formal data race
    /// today, and would become a compile error the moment strict concurrency checking
    /// is enabled (see CRIT-3) — `ReachabilityStore`'s own observer already does this
    /// correctly via `Task { @MainActor in }`, which is precisely why that disagreement
    /// stayed invisible instead of surfacing as a warning. Requiring `@Sendable` here
    /// rejects a main-actor-isolated closure at the call site, forcing it into that
    /// `Task { @MainActor in }` shape instead.
    private var restoredObservers: [@Sendable () -> Void] = []

    /// Register a handler for "connectivity restored". Returns nothing; handlers live
    /// for the process lifetime (the app's few consumers are all long-lived singletons).
    /// The handler runs on `queue`, not the main actor — wrap main-actor work in
    /// `Task { @MainActor in ... }` inside it.
    func addConnectivityRestoredObserver(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { restoredObservers.append(handler) }
    }

    private init() {
        // Don't assume "connected" until the monitor has actually told us — if the app
        // launches in Airplane Mode, defaulting to `true` meant the first few
        // connectivity checks (including PlayerViewModel's offline fast-path) reported
        // online, incurring the very timeout the fast-path exists to avoid.
        // `currentPath` reflects the monitor's best-known state immediately, even
        // before `start(queue:)` is called below.
        let initialPath = monitor.currentPath
        _isConnected = initialPath.status == .satisfied
        _isOnWiFi = _isConnected && initialPath.usesInterfaceType(.wifi)

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowConnected = path.status == .satisfied
            var restored = false
            var observers: [@Sendable () -> Void] = []
            self.lock.withLock {
                restored = nowConnected && !self._isConnected
                self._isConnected = nowConnected
                self._isOnWiFi = nowConnected && path.usesInterfaceType(.wifi)
                if restored { observers = self.restoredObservers }
            }
            observers.forEach { $0() }
        }
        monitor.start(queue: queue)
    }
}
