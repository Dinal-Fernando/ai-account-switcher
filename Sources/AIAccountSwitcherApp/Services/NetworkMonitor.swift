import Foundation
import Network

/// Reports connectivity so the monitor can mark readings offline instead of burning backoff on failures.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.aiswitch.network")

    init(onChange: @escaping (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
