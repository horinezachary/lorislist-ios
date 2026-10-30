import Foundation
import Network

/// Reports when the phone gets a network connection back after being without one, so waiting
/// changes can be sent straight away instead of at the next timer. It is only a hint: whether
/// the server can really be reached is learned from the requests themselves.
final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.horine.lorislist.connectivity")
    private var wasConnected = true
    private var started = false

    /// Called on a background queue.
    var onRestored: (@Sendable () -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            if connected && !self.wasConnected { self.onRestored?() }
            self.wasConnected = connected
        }
        monitor.start(queue: queue)
    }
}
