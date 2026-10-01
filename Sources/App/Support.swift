import SwiftUI

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
