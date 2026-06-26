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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock {
                self._isConnected = path.status == .satisfied
                self._isOnWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            }
        }
        monitor.start(queue: queue)
    }
}
