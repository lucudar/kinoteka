import Foundation

// MARK: - Search request (Jackett-compatible API: Jacred, Jackett)

struct TorrentSearchQuery: Hashable, Sendable {
    var title: String
    var originalTitle: String?
    var year: Int?
    var isSeries: Bool
    /// Free text typed by the user instead of the title.
    var custom: String? = nil

    var isCustom: Bool { custom?.nonEmpty != nil }

    var filter: ReleaseFilter {
        ReleaseFilter(title: title, originalTitle: originalTitle, year: year, isSeries: isSeries, strict: !isCustom)
    }

    /// "jac.red/" -> "https://jac.red"; a pasted API address is cut to the server part.
    static func normalizedServer(_ server: String) -> String? {
        var base = server.trimmed
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "https://" + base }
        if let api = base.range(of: "/api/", options: .caseInsensitive) {
            base = String(base[..<api.lowerBound])
        }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), url.host != nil else { return nil }
        return base
    }

    func url(server: String, apiKey: String, useOriginalTitle: Bool = false) -> URL? {
        guard let base = TorrentSearchQuery.normalizedServer(server),
              var comps = URLComponents(string: base + "/api/v2.0/indexers/all/results") else { return nil }
        let text: String
        if let custom = custom?.nonEmpty {
            text = custom
        } else if useOriginalTitle, let original = originalTitle?.nonEmpty {
            text = original
        } else {
            text = title
        }
        var items = [
            URLQueryItem(name: "apikey", value: apiKey.trimmed),
            URLQueryItem(name: "Query", value: text)
        ]
        if !isCustom {
            items.append(URLQueryItem(name: "title", value: title))
            items.append(URLQueryItem(name: "title_original", value: originalTitle ?? ""))
            if let year = year { items.append(URLQueryItem(name: "year", value: String(year))) }
        }
        items.append(URLQueryItem(name: "is_serial", value: isSeries ? "2" : "1"))
        items.append(URLQueryItem(name: "Category[]", value: isSeries ? "5000" : "2000"))
        comps.queryItems = items
        if let query = comps.percentEncodedQuery {
            comps.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url
    }
}

struct ReleaseFilter: Sendable {
    var title: String
    var originalTitle: String?
    var year: Int?
    var isSeries: Bool
    /// Keep only releases whose title and year match (off for custom queries).
    var strict: Bool
}

// MARK: - Lenient JSON decoding

struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Decodes an element or nil, so one broken element does not fail the whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer where K == JSONKey {
    func flexString(_ names: String...) -> String? {
        for name in names {
            let key = JSONKey(name)
            if let value = try? decodeIfPresent(String.self, forKey: key), let text = value.nonEmpty { return text }
            if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        }
        return nil
    }

    func flexInt64(_ names: String...) -> Int64? {
        for name in names {
            let key = JSONKey(name)
            if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite, abs(value) < 9.0e18 {
                return Int64(value)
            }
            if let text = try? decodeIfPresent(String.self, forKey: key), let value = Int64(text.trimmed) { return value }
        }
        return nil
    }

    func flexInt(_ names: String...) -> Int? {
        for name in names {
            let key = JSONKey(name)
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite, abs(value) < 1.0e15 {
                return Int(value)
            }
            if let text = try? decodeIfPresent(String.self, forKey: key), let value = Int(text.trimmed) { return value }
        }
        return nil
    }

    func flexStrings(_ name: String) -> [String] {
        let list = (try? decodeIfPresent([Lenient<String>].self, forKey: JSONKey(name))) ?? nil
        return (list ?? []).compactMap { $0.value?.nonEmpty }
    }

    func flexInts(_ name: String) -> [Int] {
        let list = (try? decodeIfPresent([Lenient<Int>].self, forKey: JSONKey(name))) ?? nil
        return (list ?? []).compactMap { $0.value }
    }
}

/// Extra data Jacred adds to each result (inside "info", or at the top level in /api/v1.0).
struct JacredInfo: Decodable, Sendable {
    var quality: Int?
    var videoType: String?
    var voices: [String] = []
    var seasons: [Int] = []
    var year: Int?
    var types: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        quality = c.flexInt("quality")
        videoType = c.flexString("videotype")
        voices = c.flexStrings("voices")
        seasons = c.flexInts("seasons")
        year = c.flexInt("relased", "released")
        types = c.flexStrings("types")
    }
}

/// Stream description from ffprobe (Jacred), used to list the audio tracks of a release.
struct FFProbeStream: Decodable, Sendable {
    var type: String?
    var codec: String?
    var channels: Int?
    var language: String?
    var title: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        type = c.flexString("codec_type")
        codec = c.flexString("codec_name")
        channels = c.flexInt("channels")
        if let tags = try? c.nestedContainer(keyedBy: JSONKey.self, forKey: JSONKey("tags")) {
            language = tags.flexString("language")
            title = tags.flexString("title")
        }
    }

    var isAudio: Bool { type == "audio" }

    var label: String? {
        if let title = title?.nonEmpty { return title }
        guard let code = language?.lowercased(), !code.isEmpty else { return nil }
        return FFProbeStream.languageNames[code] ?? code.uppercased()
    }

    static let languageNames: [String: String] = [
        "rus": "Русский", "eng": "Английский", "ukr": "Украинский", "jpn": "Японский", "kor": "Корейский",
        "fre": "Французский", "fra": "Французский", "ger": "Немецкий", "deu": "Немецкий", "spa": "Испанский",
        "ita": "Итальянский", "chi": "Китайский", "zho": "Китайский"
    ]
}

/// One result of Jackett / Jacred ("Results" item), also accepts Jacred v1 and Prowlarr field names.
struct JackettItem: Decodable, Sendable {
    var title = ""
    var tracker: String?
    var details: String?
    var size: Int64 = 0
    var publishDate: String?
    var categoryDesc: String?
    var categories: [Int] = []
    var seeders = 0
    var peers = 0
    var magnet: String?
    var link: String?
    var infoHash: String?
    var info = JacredInfo()
    var audioTracks: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        title = c.flexString("Title", "title") ?? ""
        tracker = c.flexString("Tracker", "tracker", "indexer")
        details = c.flexString("Details", "Comments", "url", "infoUrl")
        size = c.flexInt64("Size", "size") ?? 0
        publishDate = c.flexString("PublishDate", "publishDate", "createTime")
        categoryDesc = c.flexString("CategoryDesc")
        categories = c.flexInts("Category")
        seeders = c.flexInt("Seeders", "seeders", "sid") ?? 0
        peers = c.flexInt("Peers", "leechers", "pir") ?? 0
        magnet = c.flexString("MagnetUri", "magnetUrl", "magnet")
        link = c.flexString("Link", "downloadUrl", "link")
        infoHash = c.flexString("InfoHash", "infoHash")
        if let nested = try? c.decodeIfPresent(JacredInfo.self, forKey: JSONKey("info")) {
            info = nested
        } else if let flat = try? JacredInfo(from: decoder) {
            info = flat
        }
        if let streams = try? c.decodeIfPresent([Lenient<FFProbeStream>].self, forKey: JSONKey("ffprobe")) {
            audioTracks = streams.compactMap { $0.value }.filter { $0.isAudio }.compactMap { $0.label }
        }
    }
}

struct JackettSearchResponse: Decodable, Sendable {
    var items: [JackettItem]
    var isJacred: Bool

    init(items: [JackettItem], isJacred: Bool = false) {
        self.items = items
        self.isJacred = isJacred
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: JSONKey.self) {
            let results = (try? c.decodeIfPresent([Lenient<JackettItem>].self, forKey: JSONKey("Results")))
                ?? (try? c.decodeIfPresent([Lenient<JackettItem>].self, forKey: JSONKey("results")))
            guard let list = results ?? nil else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No results"))
            }
            items = list.compactMap { $0.value }
            isJacred = (try? c.decodeIfPresent(Bool.self, forKey: JSONKey("jacred"))) ?? false
        } else {
            let list = try [Lenient<JackettItem>](from: decoder)
            items = list.compactMap { $0.value }
            isJacred = false
        }
    }
}

// MARK: - Results -> releases

/// Formatters are thread-safe for parsing, so they are shared.
enum ReleaseDates {
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let value = text?.nonEmpty else { return nil }
        if let date = iso.date(from: value) ?? isoFraction.date(from: value) { return date }
        return plain.date(from: String(value.prefix(19)))
    }
}

enum ReleaseBuilder {
    private static let seriesTypes: Set<String> = ["serial", "tvshow", "docuserial", "multserial", "anime"]
    private static let movieTypes: Set<String> = ["movie", "multfilm", "documovie"]

    /// true / false when the tracker category says series / movie.
    static func seriesHint(_ item: JackettItem) -> Bool? {
        let types = Set(item.info.types.map { $0.lowercased() })
        if !types.isEmpty {
            if !types.isDisjoint(with: seriesTypes) && types.isDisjoint(with: movieTypes) { return true }
            if !types.isDisjoint(with: movieTypes) && types.isDisjoint(with: seriesTypes) { return false }
        }
        if let desc = item.categoryDesc?.lowercased() {
            if desc.hasPrefix("tv") { return true }
            if desc.hasPrefix("movies") { return false }
        }
        if let main = item.categories.first(where: { $0 >= 1000 && $0 < 10000 }) {
            if (5000..<6000).contains(main) { return true }
            if (2000..<3000).contains(main) { return false }
        }
        return nil
    }

    static func release(from item: JackettItem) -> TorrentRelease? {
        let title = item.title.trimmed
        guard !title.isEmpty else { return nil }
        let magnet = item.magnet?.nonEmpty
        guard let link = magnet ?? item.link?.nonEmpty else { return nil }
        let hash = item.infoHash?.nonEmpty?.lowercased() ?? magnet.flatMap { LinkInspector.infoHash(of: $0) }
        let trackers = (item.tracker ?? "").components(separatedBy: ",").compactMap { $0.nonEmpty }

        var kinds = ReleaseParser.voiceKinds(in: title)
        var studios: [String] = []
        for voice in item.info.voices {
            if voice.lowercased().hasPrefix("дубл") {
                if !kinds.contains(.dub) { kinds.append(.dub) }
            } else if !studios.contains(voice) {
                studios.append(voice)
            }
        }
        kinds.sort()

        var audio: [String] = []
        for track in item.audioTracks where !audio.contains(track) {
            audio.append(track)
        }

        let seasons = item.info.seasons.isEmpty
            ? ReleaseParser.seasons(in: title)
            : Array(Set(item.info.seasons.filter { $0 > 0 })).sorted()
        let year = (item.info.year ?? 0) > 0 ? item.info.year : ReleaseParser.year(in: title)

        return TorrentRelease(
            id: hash ?? link,
            title: title,
            link: link,
            hash: hash,
            size: max(0, item.size),
            seeders: max(0, item.seeders),
            peers: max(0, item.peers),
            trackers: trackers,
            published: ReleaseDates.parse(item.publishDate),
            quality: ReleaseParser.quality(title: title, height: item.info.quality),
            isHDR: ReleaseParser.isHDR(title: title, videoType: item.info.videoType),
            isCamRip: ReleaseParser.isCamRip(title),
            seasons: seasons,
            voiceKinds: kinds,
            studios: studios,
            audioTracks: Array(audio.prefix(8)),
            year: year,
            isSeries: seriesHint(item),
            detailsURL: item.details
        )
    }

    static func accepts(_ release: TorrentRelease, _ filter: ReleaseFilter) -> Bool {
        guard filter.strict else { return true }
        if let isSeries = release.isSeries, isSeries != filter.isSeries { return false }
        let names = [filter.title, filter.originalTitle ?? ""].filter { !TextMatch.normalized($0).isEmpty }
        if !names.isEmpty && !names.contains(where: { TextMatch.containsPhrase(release.title, $0) }) { return false }
        if !filter.isSeries, let wanted = filter.year, let year = release.year, abs(year - wanted) > 1 { return false }
        return true
    }

    /// Converts, filters and merges results (the same torrent from several trackers becomes one).
    static func build(from response: JackettSearchResponse, filter: ReleaseFilter?) -> [TorrentRelease] {
        var merged: [String: TorrentRelease] = [:]
        var order: [String] = []
        for item in response.items {
            guard let release = release(from: item) else { continue }
            if let filter = filter, !accepts(release, filter) { continue }
            if var existing = merged[release.id] {
                existing.seeders = max(existing.seeders, release.seeders)
                existing.peers = max(existing.peers, release.peers)
                for tracker in release.trackers where !existing.trackers.contains(tracker) {
                    existing.trackers.append(tracker)
                }
                merged[release.id] = existing
            } else {
                merged[release.id] = release
                order.append(release.id)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
