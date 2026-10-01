import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var connection: ConnectionClass = .other
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "kinoteka.network-monitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connection: ConnectionClass
            if path.status != .satisfied {
                connection = .offline
            } else if path.usesInterfaceType(.wifi) {
                connection = .wifi
            } else if path.usesInterfaceType(.cellular) {
                connection = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                connection = .wired
            } else {
                connection = .other
            }
            Task { @MainActor [weak self] in
                self?.connection = connection
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    var title: String {
        switch connection {
        case .wifi: return isConstrained ? "Wi‑Fi, экономия данных" : "Wi‑Fi"
        case .cellular: return "Мобильная сеть"
        case .wired: return "Проводная сеть"
        case .other: return "Другая сеть"
        case .offline: return "Нет сети"
        }
    }
}