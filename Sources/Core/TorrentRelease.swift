import Foundation

// MARK: - Release model

enum ReleaseQuality: Int, Codable, CaseIterable, Comparable, Identifiable, Sendable {
    case unknown = 0
    case sd = 1
    case hd = 2
    case fullHD = 3
    case uhd = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .uhd: return "4K"
        case .fullHD: return "1080p"
        case .hd: return "720p"
        case .sd: return "SD"
        case .unknown: return "—"
        }
    }

    /// Values offered as the preferred quality in settings.
    static let choices: [ReleaseQuality] = [.uhd, .fullHD, .hd, .sd]

    init(height: Int) {
        if height >= 1800 {
            self = .uhd
        } else if height >= 900 {
            self = .fullHD
        } else if height >= 600 {
            self = .hd
        } else if height > 0 {
            self = .sd
        } else {
            self = .unknown
        }
    }

    static func < (lhs: ReleaseQuality, rhs: ReleaseQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum VoiceKind: Int, Codable, CaseIterable, Comparable, Sendable {
    case dub
    case multi
    case two
    case single
    case author
    case amateur
    case subtitles

    var title: String {
        switch self {
        case .dub: return "Дубляж"
        case .multi: return "Многоголосый"
        case .two: return "Двухголосый"
        case .single: return "Одноголосый"
        case .author: return "Авторский"
        case .amateur: return "Любительский"
        case .subtitles: return "Субтитры"
        }
    }

    static func < (lhs: VoiceKind, rhs: VoiceKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One torrent found by the search (a "раздача").
struct TorrentRelease: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var link: String
    var hash: String?
    var size: Int64
    var seeders: Int
    var peers: Int
    var trackers: [String]
    var published: Date?
    var quality: ReleaseQuality
    var isHDR: Bool
    var isCamRip: Bool
    var seasons: [Int]
    var voiceKinds: [VoiceKind]
    var studios: [String]
    var audioTracks: [String]
    var year: Int?
    var isSeries: Bool?
    var detailsURL: String?

    var voices: [String] { voiceKinds.map { $0.title } + studios }

    var sizeText: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : ""
    }

    var trackerText: String {
        guard let first = trackers.first else { return "" }
        return trackers.count > 1 ? "\(first) +\(trackers.count - 1)" : first
    }

    var seasonsText: String? { ReleaseParser.seasonsText(seasons) }

    var qualityText: String {
        guard quality != .unknown else { return "" }
        return isHDR ? quality.title + " HDR" : quality.title
    }

    /// Short description kept with a saved source: "1080p · 10.7 GB · Дубляж".
    var summary: String {
        var parts: [String] = []
        if !qualityText.isEmpty { parts.append(qualityText) }
        if let seasons = seasonsText { parts.append(seasons) }
        if !sizeText.isEmpty { parts.append(sizeText) }
        if let voice = voices.first { parts.append(voice) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Parsing release titles

enum ReleaseParser {
    static func quality(title: String, height: Int? = nil) -> ReleaseQuality {
        // An explicit resolution wins: "UHD BDRip 1080p" is a 1080p copy of a 4K disc.
        if Rx.matches("(?<![0-9])2160[pi]", in: title) { return .uhd }
        if Rx.matches("(?<![0-9])1080[pi]", in: title) { return .fullHD }
        if Rx.matches("(?<![0-9])720p", in: title) { return .hd }
        if Rx.matches("(?<![0-9a-z])(4k|uhd)(?![0-9a-z])", in: title) { return .uhd }
        if let height = height, height > 0 { return ReleaseQuality(height: height) }
        if Rx.matches("(?<![0-9])(480|576|360)p|rip(?![a-z])|(?<![a-z])(dvd5|dvd9|dvd|hdtv|sd|vhs)(?![a-z])", in: title) { return .sd }
        return .unknown
    }

    static func isHDR(title: String, videoType: String? = nil) -> Bool {
        if videoType?.lowercased() == "hdr" { return true }
        return Rx.matches("(?<![a-z0-9])(hdr(10\\+?)?|dolby[ ._-]?vision|dovi|dv)(?![a-z0-9])", in: title)
    }

    /// Camera or telesync copies ("экранки").
    static func isCamRip(_ title: String) -> Bool {
        if Rx.matches("(?<![a-zа-я])(camrip|cam-rip|hdcam|telesync|hdts|hd-ts|telecine|hdtc|экранка)(?![a-zа-я])", in: title) {
            return true
        }
        return Rx.matches("(?<![A-Za-z0-9])(TS|TC|CAM)(?![A-Za-z0-9])", in: title, caseSensitive: true)
    }

    static func seasons(in title: String) -> [Int] {
        // "1-5 сезоны", "1–3 сезон"
        if let g = Rx.groups("(?<![0-9])(\\d{1,2})\\s*[-–—]\\s*(\\d{1,2})\\s*сезон", in: title) {
            return range(g[0], g[1])
        }
        // "12 сезонов" — a complete series
        if let g = Rx.groups("(?<![0-9])(\\d{1,2})\\s*сезонов", in: title) {
            return range("1", g[0])
        }
        // "4 сезон", "1-й сезон"
        if let g = Rx.groups("(?<![0-9])(\\d{1,2})(?:\\s*-?\\s*й)?\\s*сезон", in: title) {
            return range(g[0], "")
        }
        // "Сезон: 2", "Сезоны 1-3"
        if let g = Rx.groups("сезон[аыи]?\\s*[:№#]?\\s*(\\d{1,2})(?:\\s*[-–—]\\s*(\\d{1,2}))?(?![0-9])", in: title) {
            return range(g[0], g[1])
        }
        // "S01-S03", "S01-03", "S02E05", "S01E01-08"
        let sPattern = "(?<![a-z0-9])s(\\d{1,2})(?:e\\d{1,3}(?:\\s*[-–—]\\s*e?\\d{1,3})?)?(?:\\s*[-–—]\\s*s?(\\d{1,2})(?![0-9e]))?(?![0-9])"
        if let g = Rx.groups(sPattern, in: title) {
            return range(g[0], g[1])
        }
        // "Season 2", "Seasons 1-4"
        if let g = Rx.groups("(?<![a-z])seasons?\\s*[:#]?\\s*(\\d{1,2})(?:\\s*[-–—]\\s*(\\d{1,2}))?(?![0-9])", in: title) {
            return range(g[0], g[1])
        }
        return []
    }

    private static func range(_ from: String, _ to: String) -> [Int] {
        guard let a = Int(from) else { return [] }
        guard let b = Int(to), b != a else { return a > 0 ? [a] : [] }
        let low = max(min(a, b), 1)
        let high = max(a, b)
        guard low <= high else { return [] }
        guard high - low <= 60 else { return [low] }
        return Array(low...high)
    }

    static func seasonsText(_ seasons: [Int]) -> String? {
        let list = Array(Set(seasons)).sorted()
        guard let first = list.first, let last = list.last else { return nil }
        if list.count == 1 { return "\(first) сезон" }
        if last - first + 1 == list.count { return "\(first)–\(last) сезоны" }
        return list.map { String($0) }.joined(separator: ", ") + " сезоны"
    }

    private static let kinozalCodes: [String: VoiceKind] = [
        "ДБ": .dub, "ПМ": .multi, "ПД": .two, "ПО": .single,
        "ЛМ": .amateur, "ЛД": .amateur, "ЛО": .amateur, "АП": .author, "АО": .author, "СТ": .subtitles
    ]
    private static let latinCodes: [String: VoiceKind] = [
        "dub": .dub, "mvo": .multi, "dvo": .two, "avo": .author, "vo": .single, "sub": .subtitles, "subs": .subtitles
    ]
    private static let rutorTokens: [String: VoiceKind] = [
        "D": .dub, "P": .multi, "P2": .two, "P1": .single, "A": .author, "L": .amateur, "L1": .amateur, "L2": .amateur
    ]
    private static let voiceWords: [(String, VoiceKind)] = [
        ("дубляж|дублирован", .dub), ("многоголос", .multi), ("двухголос", .two), ("одноголос", .single),
        ("авторск", .author), ("любительск", .amateur), ("субтитр", .subtitles)
    ]

    /// Kinds of Russian voice-over mentioned in a title, in order of preference.
    static func voiceKinds(in title: String) -> [VoiceKind] {
        var found = Set<VoiceKind>()
        // Kinozal: "ДБ, ПМ, СТ", "2 x ДБ"
        for g in Rx.allGroups("(?<![А-Яа-яЁё])(ДБ|ПМ|ПД|ПО|ЛМ|ЛД|ЛО|АП|АО|СТ)(?![А-Яа-яЁё])", in: title, caseSensitive: true) {
            if let code = g.first, let kind = kinozalCodes[code] { found.insert(kind) }
        }
        // RuTracker: "Dub", "MVO", "DVO", "AVO", "VO", "Sub"
        for g in Rx.allGroups("(?<![A-Za-z])(Dub|DUB|MVO|DVO|AVO|VO|Subs|Sub|SUB)(?![A-Za-z])", in: title, caseSensitive: true) {
            if let code = g.first?.lowercased(), let kind = latinCodes[code] { found.insert(kind) }
        }
        for (pattern, kind) in voiceWords where Rx.matches(pattern, in: title) {
            found.insert(kind)
        }
        // RuTor: "| D, P |", "| L1 |"
        for segment in title.components(separatedBy: "|").dropFirst() {
            for token in segment.components(separatedBy: ",") {
                if let kind = rutorTokens[token.trimmed] { found.insert(kind) }
            }
        }
        return found.sorted()
    }

    /// Release year: "(2021)" or "[2021," first, then the last "/ 2021", then any year.
    static func year(in title: String) -> Int? {
        if let g = Rx.groups("[\\(\\[]\\s*((?:19|20)\\d{2})(?![0-9])", in: title), let year = Int(g[0]) {
            return year
        }
        if let last = Rx.allGroups("/\\s*((?:19|20)\\d{2})(?![0-9])", in: title).last, let year = Int(last[0]) {
            return year
        }
        if let g = Rx.groups("(?<![0-9])((?:19|20)\\d{2})(?![0-9])", in: title), let year = Int(g[0]) {
            return year
        }
        return nil
    }
}

// MARK: - Sorting and the recommended release

enum ReleaseSort: String, CaseIterable, Identifiable, Sendable {
    case seeders
    case quality
    case size
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seeders: return "По сидам"
        case .quality: return "По качеству"
        case .size: return "По размеру"
        case .date: return "По дате"
        }
    }
}

enum ReleaseRanking {
    static func sorted(_ list: [TorrentRelease], by order: ReleaseSort) -> [TorrentRelease] {
        switch order {
        case .seeders:
            return list.sorted { ($0.seeders, $0.quality.rawValue, $0.size) > ($1.seeders, $1.quality.rawValue, $1.size) }
        case .quality:
            return list.sorted {
                ($0.quality.rawValue, $0.isHDR ? 1 : 0, $0.seeders) > ($1.quality.rawValue, $1.isHDR ? 1 : 0, $1.seeders)
            }
        case .size:
            return list.sorted { ($0.size, $0.seeders) > ($1.size, $1.seeders) }
        case .date:
            return list.sorted { ($0.published ?? Date.distantPast, $0.seeders) > ($1.published ?? Date.distantPast, $1.seeders) }
        }
    }

    /// How good a release is for streaming: preferred quality, live seeders, Russian dub,
    /// no camera copies and no huge remuxes (unless 4K is preferred).
    static func score(_ release: TorrentRelease, preferred: ReleaseQuality, season: Int? = nil) -> Double {
        var score = 0.0
        let quality = release.quality == .unknown ? ReleaseQuality.sd.rawValue : release.quality.rawValue
        let distance = abs(quality - preferred.rawValue)
        let qualityPoints: [Double] = [40, 18, 6, 0, 0]
        score += qualityPoints[min(distance, qualityPoints.count - 1)]
        if quality > preferred.rawValue { score -= 3 }

        // Seeders matter until the torrent is clearly alive (~100), then barely.
        score += min(log2(Double(release.seeders) + 1), 7) * 4

        if release.voiceKinds.contains(.dub) {
            score += 10
        } else if release.voiceKinds.contains(.multi) {
            score += 7
        } else if release.voiceKinds.contains(.two) {
            score += 4
        } else if release.voiceKinds.contains(where: { $0 != .subtitles }) {
            score += 2
        }

        if release.isCamRip { score -= 45 }

        // Huge files (remuxes) stream badly over a torrent on a phone; for 4K the limits are higher
        // and the penalty is milder, so a preferred 4K still wins over 1080p.
        let gigabytes = Double(release.size) / 1_073_741_824
        let isUHD = release.quality == .uhd
        let fileLimits: (soft: Double, hard: Double) = isUHD ? (45, 75) : (35, 60)
        let seasonLimits: (soft: Double, hard: Double) = isUHD ? (100, 200) : (60, 120)
        let penalties: (soft: Double, hard: Double) = isUHD ? (5, 10) : (8, 16)
        let amount = release.seasons.isEmpty ? gigabytes : gigabytes / Double(release.seasons.count)
        let limits = release.seasons.isEmpty ? fileLimits : seasonLimits
        if amount > limits.hard {
            score -= penalties.hard
        } else if amount > limits.soft {
            score -= penalties.soft
        }

        if let season = season {
            if release.seasons == [season] {
                score += 8
            } else if release.seasons.contains(season) {
                score += 6
            } else if !release.seasons.isEmpty {
                score -= 100
            }
        }
        return score
    }

    /// The release to start automatically ("Смотреть"), among those with seeders.
    static func best(_ list: [TorrentRelease], preferred: ReleaseQuality, season: Int? = nil) -> TorrentRelease? {
        let scored = list.filter { $0.seeders > 0 }.map { (release: $0, score: score($0, preferred: preferred, season: season)) }
        // Equal scores (well seeded releases): more seeders start faster.
        return scored.max { ($0.score, $0.release.seeders) < ($1.score, $1.release.seeders) }?.release
    }

    /// Releases that can play the season (all of them for a film): torrents of other seasons are left out.
    static func matching(_ list: [TorrentRelease], season: Int?) -> [TorrentRelease] {
        guard let season = season else { return list }
        return list.filter { $0.seasons.isEmpty || $0.seasons.contains(season) }
    }

    /// Qualities that have a live release for the season, best first: the "Качество" choices.
    /// Camera copies are not offered.
    static func qualities(_ list: [TorrentRelease], season: Int? = nil) -> [ReleaseQuality] {
        let present = Set(matching(list, season: season).filter { $0.seeders > 0 && !$0.isCamRip }.map { $0.quality })
        return ReleaseQuality.choices.filter { present.contains($0) }
    }

    /// The best live release of exactly this quality (not a camera copy).
    static func best(_ list: [TorrentRelease], quality: ReleaseQuality, season: Int? = nil) -> TorrentRelease? {
        let same = matching(list, season: season).filter { $0.quality == quality && !$0.isCamRip }
        return best(same, preferred: quality, season: season)
    }

    /// One release per available quality (best first), with `current` kept for its own quality.
    static func perQuality(_ list: [TorrentRelease], season: Int? = nil, current: TorrentRelease? = nil) -> [TorrentRelease] {
        qualities(list, season: season).compactMap { quality in
            if let current = current, current.quality == quality { return current }
            return best(list, quality: quality, season: season)
        }
    }
}
