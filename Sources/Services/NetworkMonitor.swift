import Foundation
import Network
import Combine
import SystemConfiguration

/// The current network for code outside the main actor (the torrent engine is tuned on its queue).
struct NetworkSnapshot: Equatable, Sendable {
    var connection: ConnectionClass
    var isExpensive: Bool
    var isConstrained: Bool
    var supportsIPv6: Bool
    var usesVPN: Bool
}

final class NetworkState: @unchecked Sendable {
    static let shared = NetworkState()

    private let lock = NSLock()
    private var value: NetworkSnapshot?

    var current: NetworkSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update(_ snapshot: NetworkSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    /// Waits a moment for the first update after the launch (not on the main thread),
    /// otherwise answers from the reachability flags.
    func wait(timeout: TimeInterval) -> NetworkSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = current { return value }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return current ?? NetworkState.reachabilitySnapshot()
    }

    static func reachabilitySnapshot() -> NetworkSnapshot {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var flags = SCNetworkReachabilityFlags()
        let known = withUnsafePointer(to: &address) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw -> Bool in
                guard let reachability = SCNetworkReachabilityCreateWithAddress(nil, raw) else { return false }
                return SCNetworkReachabilityGetFlags(reachability, &flags)
            }
        }
        let connection: ConnectionClass
        if !known {
            connection = .other
        } else if !flags.contains(.reachable) {
            connection = .offline
        } else if flags.contains(.isWWAN) {
            connection = .cellular
        } else {
            connection = .wifi
        }
        return NetworkSnapshot(connection: connection, isExpensive: connection == .cellular,
                               isConstrained: false, supportsIPv6: false, usesVPN: false)
    }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var connection: ConnectionClass = .other
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var supportsIPv6 = false
    @Published private(set) var usesVPN = false

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
            // A VPN tunnel (utun, ipsec) is an interface of the "other" type.
            let snapshot = NetworkSnapshot(connection: connection,
                                           isExpensive: path.isExpensive,
                                           isConstrained: path.isConstrained,
                                           supportsIPv6: path.supportsIPv6,
                                           usesVPN: path.status == .satisfied && path.usesInterfaceType(.other))
            NetworkState.shared.update(snapshot)
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let changed = self.connection != snapshot.connection || self.usesVPN != snapshot.usesVPN
                self.connection = snapshot.connection
                self.isExpensive = snapshot.isExpensive
                self.isConstrained = snapshot.isConstrained
                self.supportsIPv6 = snapshot.supportsIPv6
                self.usesVPN = snapshot.usesVPN
                if changed {
                    AppDiagnostics.shared.log("network", "Сеть: \(self.title)\(snapshot.supportsIPv6 ? ", IPv6" : "")")
                }
            }
        }
        monitor.start(queue: queue)
    }

    var title: String {
        let base: String
        switch connection {
        case .wifi: base = isConstrained ? "Wi‑Fi, экономия данных" : "Wi‑Fi"
        case .cellular: base = isConstrained ? "Мобильная сеть, экономия данных" : "Мобильная сеть"
        case .wired: base = "Проводная сеть"
        case .other: base = "Другая сеть"
        case .offline: return "Нет сети"
        }
        return usesVPN ? base + " · VPN" : base
    }
}
