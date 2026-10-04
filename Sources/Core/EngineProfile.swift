import Foundation

/// When the torrent traffic is encrypted. Mobile operators often slow down BitTorrent traffic
/// they recognise; an encrypted connection looks like random data to them.
enum EngineEncryptionMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case always
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "В мобильной сети"
        case .always: return "Всегда"
        case .never: return "Не требовать"
        }
    }
}

/// What the tuning of the torrent engine depends on.
struct EngineEnvironment: Hashable, Sendable {
    var connection: ConnectionClass
    var isExpensive = false
    var isConstrained = false
    var supportsIPv6 = false
    /// Free space of the device; nil when unknown (the cache then stays in memory).
    var freeBytes: Int64?
    /// Folder of the disk cache.
    var cachePath: String
    var encryption: EngineEncryptionMode = .automatic
}

/// One value of the TorrServer settings (BTSets), compared with what the engine reports.
enum EngineSettingValue: Hashable, Sendable {
    case bool(Bool)
    case int(Int64)
    case string(String)

    var jsonValue: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .string(let value): return value
        }
    }

    /// `value` comes from JSONSerialization; a missing key is the Go zero value.
    func matches(_ value: Any?) -> Bool {
        switch self {
        case .bool(let expected):
            guard let value = value, !(value is NSNull) else { return !expected }
            if let flag = value as? Bool { return flag == expected }
            if let number = value as? NSNumber { return number.boolValue == expected }
            return false
        case .int(let expected):
            guard let value = value, !(value is NSNull) else { return expected == 0 }
            if let number = value as? Int { return Int64(number) == expected }
            if let number = value as? Int64 { return number == expected }
            if let number = value as? Double { return Int64(exactly: number) == expected }
            if let number = value as? NSNumber { return number.int64Value == expected }
            return false
        case .string(let expected):
            guard let value = value, !(value is NSNull) else { return expected.isEmpty }
            return (value as? String) == expected
        }
    }
}

/// Settings of the embedded TorrServer for the current network and device.
///
/// What makes playback faster than the engine defaults (64 MB in memory, 25 peers):
/// - the pieces are kept on disk, so the buffer ahead of the playback is hundreds of megabytes
///   (the engine prioritises pieces only inside its cache window, so a bigger cache also means
///   more pieces downloaded in parallel from more peers) and the video decoder keeps the memory;
/// - more peer connections on Wi‑Fi;
/// - on a mobile network the traffic is encrypted and TCP only (operators throttle recognised
///   BitTorrent traffic and UDP), and the upload is limited so it does not choke the download.
struct EngineProfile: Hashable, Sendable {
    enum Kind: String, Sendable {
        /// Wi‑Fi or wired network: big disk buffer, many peers, TCP and uTP.
        case fast
        /// Mobile network or a hotspot: smaller buffer, TCP only, encrypted, limited upload.
        case mobile
        /// Low Data Mode: the smallest buffer and nothing read in advance.
        case economy
    }

    var kind: Kind
    var cacheBytes: Int64
    var useDisk: Bool
    var cachePath: String
    var connections: Int
    var utp: Bool
    var upnp: Bool
    var forceEncrypt: Bool
    /// KB/s, 0 = unlimited.
    var uploadLimit: Int
    var ipv6: Bool
    /// Bytes read in advance from the start and from the end of the file a film page will play
    /// (players read the header at the start and the index at the end before the first frame).
    var warmupHead: Int64
    var warmupTail: Int64

    /// Seconds a torrent stays connected after the player stops reading it (TorrServer default: 30).
    /// Long enough to reopen the film or pick another episode without reconnecting to peers.
    static let keepAliveSeconds = 180
    static let memoryCache: Int64 = 64 << 20

    static func make(_ env: EngineEnvironment) -> EngineProfile {
        let mobileNetwork = env.connection == .cellular || env.isExpensive
        let kind: Kind
        if env.isConstrained {
            kind = .economy
        } else if mobileNetwork {
            kind = .mobile
        } else {
            kind = .fast
        }
        let limit: Int64
        switch kind {
        case .fast: limit = Int64.max
        case .mobile: limit = 256 << 20
        case .economy: limit = 128 << 20
        }
        let disk = diskCache(freeBytes: env.freeBytes).map { min($0, limit) }
        let encrypt: Bool
        switch env.encryption {
        case .always: encrypt = true
        case .never: encrypt = false
        case .automatic: encrypt = mobileNetwork
        }
        let homeNetwork = env.connection == .wifi || env.connection == .wired
        return EngineProfile(
            kind: kind,
            cacheBytes: disk ?? memoryCache,
            useDisk: disk != nil,
            cachePath: env.cachePath,
            connections: kind == .fast ? 60 : (kind == .mobile ? 40 : 25),
            utp: kind == .fast,
            upnp: kind == .fast && homeNetwork,
            forceEncrypt: encrypt,
            uploadLimit: kind == .fast ? 0 : (kind == .mobile ? 100 : 32),
            ipv6: env.supportsIPv6,
            warmupHead: kind == .fast ? 8 << 20 : (kind == .mobile ? 4 << 20 : 0),
            warmupTail: kind == .fast ? 4 << 20 : (kind == .mobile ? 2 << 20 : 0)
        )
    }

    /// Disk cache by the free space (the cache is per torrent; nil keeps it in memory).
    static func diskCache(freeBytes: Int64?) -> Int64? {
        guard let free = freeBytes else { return nil }
        let gb: Int64 = 1 << 30
        if free >= 16 * gb { return 2 * gb }
        if free >= 6 * gb { return gb }
        if free >= 3 * gb { return 512 << 20 }
        if free >= 3 * gb / 2 { return 256 << 20 }
        return nil
    }

    /// TorrServer settings (BTSets field names) the profile controls; the others are kept.
    var settings: [String: EngineSettingValue] {
        [
            "CacheSize": .int(cacheBytes),
            "UseDisk": .bool(useDisk),
            "TorrentsSavePath": .string(cachePath),
            "RemoveCacheOnDrop": .bool(true),
            "ReaderReadAHead": .int(95),
            "ResponsiveMode": .bool(true),
            "ConnectionsLimit": .int(Int64(connections)),
            "DisableTCP": .bool(false),
            "DisableUTP": .bool(!utp),
            "DisableUPNP": .bool(!upnp),
            "DisableDHT": .bool(false),
            "DisablePEX": .bool(false),
            "DisableUpload": .bool(false),
            "ForceEncrypt": .bool(forceEncrypt),
            "UploadRateLimit": .int(Int64(uploadLimit)),
            "DownloadRateLimit": .int(0),
            "EnableIPv6": .bool(ipv6),
            "RetrackersMode": .int(1),
            "TorrentDisconnectTimeout": .int(Int64(EngineProfile.keepAliveSeconds)),
            // Discovery of other devices is not needed inside the app; it only adds
            // multicast traffic and work while the phone plays.
            "EnableDLNA": .bool(false),
            "EnableBonjour": .bool(false),
            "EnableLPD": .bool(false),
            "EnableRutorSearch": .bool(false)
        ]
    }

    /// Keys whose values in `current` (the engine settings) differ from the profile.
    func changes(from current: [String: Any]) -> [String] {
        settings.filter { !$0.value.matches(current[$0.key]) }.map(\.key).sorted()
    }

    /// The engine settings with the profile applied.
    func merged(into current: [String: Any]) -> [String: Any] {
        var result = current
        for (key, value) in settings {
            result[key] = value.jsonValue
        }
        return result
    }

    var title: String {
        switch kind {
        case .fast: return "Wi‑Fi"
        case .mobile: return "мобильная сеть"
        case .economy: return "экономия трафика"
        }
    }

    /// "Wi‑Fi · кэш 1 ГБ на диске · до 60 пиров · TCP и uTP".
    var summary: String {
        var parts = [title]
        parts.append("кэш " + EngineProfile.sizeText(cacheBytes) + (useDisk ? " на диске" : " в памяти"))
        parts.append("до \(connections) пиров")
        parts.append(utp ? "TCP и uTP" : "только TCP")
        if forceEncrypt { parts.append("шифрование") }
        if uploadLimit > 0 { parts.append("отдача до \(uploadLimit) КБ/с") }
        if ipv6 { parts.append("IPv6") }
        return parts.joined(separator: " · ")
    }

    static func sizeText(_ bytes: Int64) -> String {
        let gb: Int64 = 1 << 30
        if bytes >= gb {
            let tenths = (bytes * 10 + gb / 2) / gb
            return tenths % 10 == 0 ? "\(tenths / 10) ГБ" : "\(tenths / 10),\(tenths % 10) ГБ"
        }
        return "\(max(0, bytes) >> 20) МБ"
    }

    /// Trackers added to every torrent (TorrServer reads them from trackers.txt), besides the
    /// ones of the release and the engine's list. Russian retrackers first: the rutracker ones
    /// know its releases even when the magnet link has no trackers, and they answer on
    /// mobile networks where foreign trackers can be slowed down.
    static let trackers = [
        "http://retracker.local/announce",
        "http://bt.t-ru.org/ann?magnet",
        "http://bt2.t-ru.org/ann?magnet",
        "http://bt3.t-ru.org/ann?magnet",
        "http://bt4.t-ru.org/ann?magnet",
        "http://retracker01-msk-virt.corbina.net:80/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://explodie.org:6969/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker.dler.org:6969/announce",
        "udp://opentor.net:6969/announce",
        "http://tracker.renfei.net:8080/announce"
    ]
}

/// The file of a torrent a film page will play, to read its start in advance.
struct WarmupTarget: Hashable, Sendable {
    var fileId: Int?
    var season: Int?
    var episode: Int?
    var isSeries: Bool

    /// Chosen the way the player chooses it.
    func file(in all: [TorrentFile]) -> TorrentFile? {
        let list = TorrentFile.playable(all)
        if let id = fileId, let file = list.first(where: { $0.id == id }) { return file }
        if let episode = episode {
            return EpisodeMatcher.find(in: list, season: season, episode: episode)
        }
        if list.count == 1 { return list[0] }
        if !isSeries { return TorrentFile.dominant(list) }
        return list.first
    }
}
