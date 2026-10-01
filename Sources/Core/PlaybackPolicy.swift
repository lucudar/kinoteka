import Foundation

enum ConnectionClass: String, Codable, Sendable {
    case wifi
    case cellular
    case wired
    case other
    case offline
}

enum PlaybackPolicy {
    /// "Авто по сети": cellular playback is capped at 720p, an unknown
    /// connection at 1080p, while Wi‑Fi and wired networks keep the user's choice.
    static func effectiveQuality(_ configured: ReleaseQuality,
                                 connection: ConnectionClass,
                                 smart: Bool) -> ReleaseQuality {
        guard smart else { return configured }
        switch connection {
        case .cellular:
            return min(configured, .hd)
        case .other:
            return min(configured, .fullHD)
        case .wifi, .wired, .offline:
            return configured
        }
    }

    static func lowerQuality(than quality: ReleaseQuality) -> ReleaseQuality {
        switch quality {
        case .uhd: return .fullHD
        case .fullHD: return .hd
        case .hd: return .sd
        case .sd, .unknown: return .sd
        }
    }
}