import Foundation

/// Hosts that stopped answering or became too slow (a mobile network slowing foreign hosting
/// down): while marked, requests go to the backup source at once instead of waiting for a timeout
/// again. A mark wears off by itself, so the host is tried again later.
final class HostHealth: @unchecked Sendable {
    static let shared = HostHealth()

    private struct Mark {
        var until: Date
        var reason: String
    }

    private let lock = NSLock()
    private var marks: [String: Mark] = [:]

    func isDown(_ host: String, now: Date = Date()) -> Bool {
        reason(host, now: now) != nil
    }

    /// Why the host is skipped, while it is.
    func reason(_ host: String, now: Date = Date()) -> String? {
        let key = host.lowercased()
        lock.lock()
        defer { lock.unlock() }
        guard let mark = marks[key] else { return nil }
        if mark.until > now { return mark.reason }
        marks[key] = nil
        return nil
    }

    /// True when the host was not marked before (worth a line in the log).
    @discardableResult
    func markDown(_ host: String, for seconds: TimeInterval, reason: String, now: Date = Date()) -> Bool {
        let key = host.lowercased()
        let until = now.addingTimeInterval(max(0, seconds))
        lock.lock()
        defer { lock.unlock() }
        let wasDown = (marks[key]?.until ?? .distantPast) > now
        // A longer mark is not shortened by a shorter one.
        if let old = marks[key], old.until > until { return !wasDown }
        marks[key] = Mark(until: until, reason: reason)
        return !wasDown
    }

    func markUp(_ host: String) {
        let key = host.lowercased()
        lock.lock()
        marks[key] = nil
        lock.unlock()
    }

    /// Errors meaning the host does not answer (not "the device is offline" or "cancelled").
    static func isHostFailure(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
             .secureConnectionFailed, .badServerResponse, .cannotLoadFromNetwork, .resourceUnavailable,
             .cannotParseResponse, .zeroByteResource:
            return true
        default:
            return false
        }
    }
}
