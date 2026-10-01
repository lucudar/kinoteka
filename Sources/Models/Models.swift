import Foundation

// MARK: - Core item

enum MediaKind: String, Codable, Hashable {
    case movie
    case series
}

struct MediaItem: Codable, Identifiable, Hashable {
    var id: Int
    var title: String
    var originalTitle: String?
    var year: Int?
    var posterURL: String?
    var posterPreviewURL: String?
    var ratingKP: Double?
    var ratingIMDb: Double?
    var kind: MediaKind
    var genres: [String]
    var countries: [String]

    var key: String { "kp:\(id)" }

    var poster: URL? { URL(string: posterPreviewURL ?? posterURL ?? "") }

    var subtitleLine: String {
        var parts: [String] = []
        if let year = year { parts.append(String(year)) }
        if let country = countries.first { parts.append(country) }
        if let genre = genres.first { parts.append(genre) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Flexible decoding helpers (Kinopoisk API mixes types between endpoints)

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == AnyKey {
    func string(_ keys: String...) -> String? {
        for name in keys {
            let key = AnyKey(name)
            if let value = try? decodeIfPresent(String.self, forKey: key), !value.isEmpty { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for name in keys {
            let key = AnyKey(name)
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Double.self, forKey: key),
               value.isFinite, abs(value) < 9.0e15 { return Int(value) }
            if let text = try? decodeIfPresent(String.self, forKey: key), let value = Int(text.prefix(4)) { return value }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for name in keys {
            let key = AnyKey(name)
            if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
            if let text = try? decodeIfPresent(String.self, forKey: key), let value = Double(text) { return value }
        }
        return nil
    }
}

struct KPGenre: Codable, Hashable {
    let genre: String?
}

struct KPCountry: Codable, Hashable {
    let country: String?
}

private let seriesTypes: Set<String> = ["TV_SERIES", "MINI_SERIES", "TV_SHOW"]

/// One element of any Kinopoisk list (collections, filters, search, similars).
struct KPShort: Decodable {
    let item: MediaItem?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.int("kinopoiskId", "filmId") else {
            item = nil
            return
        }
        let title = c.string("nameRu") ?? c.string("nameEn") ?? c.string("nameOriginal") ?? "Без названия"
        var original = c.string("nameOriginal") ?? c.string("nameEn")
        if original == title { original = nil }
        let type = c.string("type") ?? "FILM"
        let genres = (try? c.decodeIfPresent([KPGenre].self, forKey: AnyKey("genres"))) ?? []
        let countries = (try? c.decodeIfPresent([KPCountry].self, forKey: AnyKey("countries"))) ?? []
        item = MediaItem(
            id: id,
            title: title,
            originalTitle: original,
            year: c.int("year", "startYear"),
            posterURL: c.string("posterUrl"),
            posterPreviewURL: c.string("posterUrlPreview"),
            ratingKP: c.double("ratingKinopoisk", "rating"),
            ratingIMDb: c.double("ratingImdb", "ratingImbd"),
            kind: seriesTypes.contains(type) ? .series : .movie,
            genres: genres.compactMap { $0.genre }.filter { !$0.isEmpty },
            countries: countries.compactMap { $0.country }.filter { !$0.isEmpty }
        )
    }
}

struct KPPage: Decodable {
    let totalPages: Int
    let items: [MediaItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        totalPages = max(1, c.int("totalPages", "pagesCount") ?? 1)
        let list: [KPShort] = (try? c.decodeIfPresent([KPShort].self, forKey: AnyKey("items")))
            ?? (try? c.decodeIfPresent([KPShort].self, forKey: AnyKey("films")))
            ?? []
        var seen = Set<Int>()
        items = list.compactMap { $0.item }.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Details

struct KPFilm: Decodable {
    let kinopoiskId: Int
    let imdbId: String?
    let nameRu: String?
    let nameEn: String?
    let nameOriginal: String?
    let posterUrl: String?
    let posterUrlPreview: String?
    let coverUrl: String?
    let ratingKinopoisk: Double?
    let ratingImdb: Double?
    let webUrl: String?
    let year: Int?
    let filmLength: Int?
    let slogan: String?
    let description: String?
    let shortDescription: String?
    let type: String?
    let ratingAgeLimits: String?
    let countries: [KPCountry]?
    let genres: [KPGenre]?
    let startYear: Int?
    let endYear: Int?
    let serial: Bool?
    let completed: Bool?

    var title: String {
        for name in [nameRu, nameEn, nameOriginal] {
            if let name = name, !name.isEmpty { return name }
        }
        return "Без названия"
    }

    var isSeries: Bool { serial == true || seriesTypes.contains(type ?? "") }

    var item: MediaItem {
        var original = nameOriginal ?? nameEn
        if original == title || original?.isEmpty == true { original = nil }
        return MediaItem(
            id: kinopoiskId,
            title: title,
            originalTitle: original,
            year: year ?? startYear,
            posterURL: posterUrl,
            posterPreviewURL: posterUrlPreview,
            ratingKP: ratingKinopoisk,
            ratingIMDb: ratingImdb,
            kind: isSeries ? .series : .movie,
            genres: (genres ?? []).compactMap { $0.genre }.filter { !$0.isEmpty },
            countries: (countries ?? []).compactMap { $0.country }.filter { !$0.isEmpty }
        )
    }

    var yearText: String {
        if isSeries, let start = startYear {
            if let end = endYear, end != start { return "\(start)–\(end)" }
            return completed == false ? "\(start)–…" : String(start)
        }
        if let year = year { return String(year) }
        return ""
    }

    var lengthText: String {
        guard let minutes = filmLength, minutes > 0 else { return "" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) мин" }
        return m == 0 ? "\(h) ч" : "\(h) ч \(m) мин"
    }

    var ageText: String {
        guard let raw = ratingAgeLimits else { return "" }
        let digits = raw.filter { $0.isNumber }
        return digits.isEmpty ? "" : "\(digits)+"
    }
}

struct KPStaff: Decodable {
    let staffId: Int?
    let nameRu: String?
    let nameEn: String?
    let description: String?
    let posterUrl: String?
    let professionText: String?
    let professionKey: String?

    var name: String {
        if let n = nameRu, !n.isEmpty { return n }
        return nameEn ?? ""
    }
}

struct KPSeasons: Decodable {
    let items: [KPSeason]
}

struct KPSeason: Decodable, Identifiable {
    let number: Int
    let episodes: [KPEpisode]
    var id: Int { number }
}

struct KPEpisode: Decodable, Identifiable, Hashable {
    let seasonNumber: Int
    let episodeNumber: Int
    let nameRu: String?
    let nameEn: String?
    let synopsis: String?
    let releaseDate: String?

    var id: String { "\(seasonNumber)-\(episodeNumber)" }

    var title: String {
        if let n = nameRu, !n.isEmpty { return n }
        if let n = nameEn, !n.isEmpty { return n }
        return "Серия \(episodeNumber)"
    }
}

struct KPVideos: Decodable {
    let items: [KPVideo]
}

struct KPVideo: Decodable, Hashable {
    let url: String?
    let name: String?
    let site: String?
}

struct KPFilters: Decodable {
    let genres: [KPFilterValue]
    let countries: [KPFilterValue]
}

struct KPFilterValue: Decodable, Hashable, Identifiable {
    let id: Int?
    let genre: String?
    let country: String?

    var title: String { genre ?? country ?? "" }
}

// MARK: - Catalog filter

struct Decade: Identifiable, Hashable {
    let id: String
    let title: String
    let from: Int
    let to: Int

    static let all: [Decade] = [
        Decade(id: "all", title: "Все годы", from: 1000, to: 3000),
        Decade(id: "2020", title: "2020-е", from: 2020, to: 2029),
        Decade(id: "2010", title: "2010-е", from: 2010, to: 2019),
        Decade(id: "2000", title: "2000-е", from: 2000, to: 2009),
        Decade(id: "1990", title: "1990-е", from: 1990, to: 1999),
        Decade(id: "1980", title: "1980-е", from: 1980, to: 1989),
        Decade(id: "old", title: "До 1980-х", from: 1000, to: 1979)
    ]

    static func byId(_ id: String) -> Decade {
        all.first { $0.id == id } ?? all[0]
    }
}

struct CatalogFilter: Equatable {
    var type: String = "FILM"
    var order: String = "NUM_VOTE"
    var genreId: Int? = nil
    var countryId: Int? = nil
    var decade: String = "all"
    var ratingFrom: Int = 0
    var hideWatched: Bool = false

    var isDefault: Bool {
        order == "NUM_VOTE" && genreId == nil && countryId == nil && decade == "all" && ratingFrom == 0 && !hideWatched
    }

    var query: [(String, String)] {
        let d = Decade.byId(decade)
        var q: [(String, String)] = [
            ("type", type),
            ("order", order),
            ("ratingFrom", String(ratingFrom)),
            ("ratingTo", "10"),
            ("yearFrom", String(d.from)),
            ("yearTo", String(d.to))
        ]
        if let g = genreId { q.append(("genres", String(g))) }
        if let c = countryId { q.append(("countries", String(c))) }
        return q
    }
}

// MARK: - Local library

struct SavedSource: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var link: String
    var added = Date()
    /// Seasons contained in the torrent (from the search result); nil when unknown.
    var seasons: [Int]? = nil
    /// Short description from the search: quality, size, voice-over.
    var info: String? = nil

    func covers(season: Int) -> Bool {
        seasons?.contains(season) ?? true
    }
}

extension SavedSource {
    init(release: TorrentRelease) {
        self.init(title: release.title,
                  link: LinkInspector.markTorrent(release.link),
                  seasons: release.seasons.isEmpty ? nil : release.seasons,
                  info: release.summary.isEmpty ? nil : release.summary)
    }
}

struct ContinueEntry: Codable, Hashable, Identifiable {
    var itemKey: String
    var item: MediaItem?
    var title: String
    var subtitle: String?
    var link: String
    var fileId: Int?
    var position: Double
    var updated: Date
    /// Episode of the file, to find it in another release of the series.
    var season: Int? = nil
    var episode: Int? = nil
    /// Position in milliseconds, to continue in another release (another quality).
    var time: Int32? = nil

    var id: String { itemKey }
}

struct LibraryData: Codable {
    var favorites: [MediaItem] = []
    var watchLater: [MediaItem] = []
    var watched: [MediaItem] = []
    var history: [MediaItem] = []
    var sources: [String: [SavedSource]] = [:]
    var resume: [String: Int32] = [:]
    var continueWatching: [ContinueEntry] = []
    var favoriteChannels: [Channel] = []
    var recentChannels: [Channel] = []
    var recentQueries: [String] = []
    /// Search-result IDs the user marked as broken or unwanted.
    var blockedReleaseIDs: [String] = []

    enum CodingKeys: String, CodingKey {
        case favorites, watchLater, watched, history, sources, resume, continueWatching
        case favoriteChannels, recentChannels, recentQueries, blockedReleaseIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = (try? c.decodeIfPresent([MediaItem].self, forKey: .favorites)) ?? []
        watchLater = (try? c.decodeIfPresent([MediaItem].self, forKey: .watchLater)) ?? []
        watched = (try? c.decodeIfPresent([MediaItem].self, forKey: .watched)) ?? []
        history = (try? c.decodeIfPresent([MediaItem].self, forKey: .history)) ?? []
        sources = (try? c.decodeIfPresent([String: [SavedSource]].self, forKey: .sources)) ?? [:]
        resume = (try? c.decodeIfPresent([String: Int32].self, forKey: .resume)) ?? [:]
        continueWatching = (try? c.decodeIfPresent([ContinueEntry].self, forKey: .continueWatching)) ?? []
        favoriteChannels = (try? c.decodeIfPresent([Channel].self, forKey: .favoriteChannels)) ?? []
        recentChannels = (try? c.decodeIfPresent([Channel].self, forKey: .recentChannels)) ?? []
        recentQueries = (try? c.decodeIfPresent([String].self, forKey: .recentQueries)) ?? []
        blockedReleaseIDs = (try? c.decodeIfPresent([String].self, forKey: .blockedReleaseIDs)) ?? []
    }
}
