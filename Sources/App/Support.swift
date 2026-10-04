import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(red: 0.0, green: 0.58, blue: 0.965)
    static let background = Color(red: 0.063, green: 0.071, blue: 0.086)
    static let card = Color(red: 0.125, green: 0.137, blue: 0.161)
    static let secondary = Color(red: 0.733, green: 0.761, blue: 0.78)
}

enum SettingsKeys {
    static let kpToken = "kpToken"
    static let playlistURL = "playlistURL"
    static let autoNext = "autoNextEpisode"
    static let savePlayerSettings = "savePlayerSettings"
    static let playerRate = "playerRate"
    static let playerAspect = "playerAspect"
    static let backgroundAudio = "backgroundAudio"
    static let searchServer = "torrentSearchServer"
    static let searchApiKey = "torrentSearchApiKey"
    static let preferredQuality = "preferredQuality"
    static let preferredVoice = "preferredVoice"
    static let autoPlayBest = "autoPlayBestRelease"
    static let prepareTorrent = "prepareTorrentInAdvance"
    static let smartQuality = "smartQualityByNetwork"
    static let automaticFallback = "automaticTorrentFallback"
    static let automaticRecovery = "automaticPlaybackRecovery"
    static let preloadNextEpisode = "preloadNextEpisode"
    static let playerGestures = "playerGestures"
    static let playerShowRemaining = "playerShowRemaining"
}

enum TimeFormat {
    static func string(ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

enum RatingStyle {
    static func color(_ value: Double) -> Color {
        if value >= 7 { return Color(red: 0.2, green: 0.65, blue: 0.3) }
        if value >= 5 { return Color(red: 0.45, green: 0.47, blue: 0.5) }
        return Color(red: 0.8, green: 0.25, blue: 0.25)
    }

    static func text(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Dates of Kinopoisk ("2024-05-12") in Russian ("12 мая 2024"). The formatters are
/// expensive to create, so they are made once (long episode lists format many dates).
enum RuDate {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let printer: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmed, raw.count >= 10 else { return nil }
        return parser.date(from: String(raw.prefix(10)))
    }

    static func text(_ raw: String?) -> String? {
        date(raw).map { printer.string(from: $0) }
    }

    /// The date has not come yet (an episode that is not out).
    static func isFuture(_ raw: String?) -> Bool {
        guard let date = date(raw) else { return false }
        return date > Date()
    }
}

extension Sequence {
    /// The first element for every key. Lists from the network, playlists and old backups can
    /// repeat items, and SwiftUI lists need unique identifiers.
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        var result: [Element] = []
        for element in self where seen.insert(key(element)).inserted {
            result.append(element)
        }
        return result
    }
}

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep` for a number of seconds that may come from the network or a calculation:
    /// negative, NaN, infinite and huge values are clamped instead of trapping.
    static func sleep(seconds: Double) async throws {
        let clamped = seconds.isFinite ? min(max(seconds, 0), 86_400) : 0
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

/// Asks iOS for a little time in the background, so a short write is not cut off when the
/// app is suspended.
final class BackgroundTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false

    @MainActor
    static func begin(_ name: String) -> BackgroundTaskToken {
        let token = BackgroundTaskToken()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            token.end()
        }
        token.lock.lock()
        let alreadyEnded = token.ended
        if !alreadyEnded { token.identifier = identifier }
        token.lock.unlock()
        if alreadyEnded, identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        return token
    }

    /// May be called from any thread, more than once.
    func end() {
        lock.lock()
        let identifier = self.identifier
        self.identifier = .invalid
        ended = true
        lock.unlock()
        guard identifier != .invalid else { return }
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
