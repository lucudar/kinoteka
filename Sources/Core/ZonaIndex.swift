import Foundation

// MARK: - Zona's index

/// Zona's own search index (Apache Solr): the catalog of films and series under their
/// Kinopoisk ids and the torrents found for each of them, with seeders, resolution and
/// voice-over already read from the files. Zona's apps ask it directly, without a key.
///
/// It is hosted in Russia, like Zona's posters, so it answers on Russian networks without a
/// VPN, while foreign hosting (jac.red, the Kinopoisk API) is often slowed down there until a
/// big answer stalls. Torrents are found by the id of the film rather than by its title, so the
/// list needs no guessing about which releases belong to it.
enum ZonaIndex {
    static let host = "zsolr3.zonasearch.com"
    static let base = "https://\(host)/solr"
    static let imageBase = "https://img2.zonapic.com/images"

    /// Releases asked at once, the most seeded first (a popular series has several hundred).
    static let releaseRows = 150
    /// Catalog lists come in pages of this size, like the Kinopoisk API.
    static let pageSize = 20

    static let torrentFields = [
        "hash", "torrent_download_link", "resolution", "size_bytes", "translate_info", "languages_parser",
        "subtitles_parser", "seeds", "peers", "episodes", "loading_success_count", "loading_fail_count",
        "advertisement"
    ]
    static let movieFields = [
        "id", "name_rus", "name_original", "name_eng", "year", "serial", "serial_end_year", "serial_ended",
        "country", "genre_name", "rating_kinopoisk", "rating_imdb", "runtime", "backdrop_id"
    ]
    static let movieDetailFields = movieFields + ["description", "persons", "rels", "episodes"]

    /// Never listed: adult films (genre 20 in Zona).
    static let safeFilter = "adult:false AND NOT genreId:20"
    /// Titles with torrents that Zona's players could start.
    static let playableFilter = "playable:true"
    /// Torrents Zona's players can start: magnet links, no trailers. ("advertisement" is only
    /// stored, not searchable: a filter on it finds nothing, so it is checked in the answer.)
    static let releaseFilter = "magnet:true AND playable:true AND trailer:false"

    /// Zona's genre ids by the Russian names Kinopoisk uses as well.
    static let genreIds: [String: Int] = [
        "ужасы": 1, "фантастика": 2, "боевик": 3, "триллер": 4, "фэнтези": 5, "комедия": 6, "мелодрама": 7,
        "драма": 8, "мюзикл": 9, "приключения": 10, "семейный": 11, "документальный": 12, "вестерн": 13,
        "мультфильм": 14, "короткометражка": 15, "криминал": 16, "детектив": 17, "фильм-нуар": 18,
        "военный": 19, "музыка": 21, "биография": 22, "история": 23, "спорт": 24, "реальное тв": 25,
        "ток-шоу": 26, "игра": 27, "новости": 28, "детский": 456, "концерт": 1747, "аниме": 1750
    ]

    // MARK: Requests

    /// One request to a core of the index ("torrent", "movie").
    static func select(_ core: String, query: String, filters: [String] = [], sort: String? = nil,
                       start: Int = 0, rows: Int, fields: [String]) -> URL? {
        guard var comps = URLComponents(string: "\(base)/\(core)/select") else { return nil }
        var items = [URLQueryItem(name: "wt", value: "json"), URLQueryItem(name: "q", value: query)]
        for filter in filters {
            items.append(URLQueryItem(name: "fq", value: filter))
        }
        if let sort = sort {
            items.append(URLQueryItem(name: "sort", value: sort))
        }
        items.append(URLQueryItem(name: "start", value: String(max(0, start))))
        items.append(URLQueryItem(name: "rows", value: String(max(0, rows))))
        if !fields.isEmpty {
            items.append(URLQueryItem(name: "fl", value: fields.joined(separator: ",")))
        }
        comps.queryItems = items
        // "+" is a space in a query string: a literal one ("NOW+120DAYS") must be encoded.
        if let encoded = comps.percentEncodedQuery {
            comps.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url
    }

    /// The torrents of a film or series, the most seeded first.
    static func releasesURL(kinopoiskId id: Int, rows: Int = releaseRows) -> URL? {
        guard id > 0 else { return nil }
        return select("torrent", query: "kinopoisk_id:\(id)", filters: [releaseFilter], sort: "seeds desc",
                      rows: rows, fields: torrentFields)
    }

    /// Everything about one title (description, people, related titles, episodes).
    static func movieURL(id: Int) -> URL? {
        guard id > 0 else { return nil }
        return select("movie", query: "id:\(id)", rows: 1, fields: movieDetailFields)
    }

    /// Several titles by their ids (the order is restored by the caller).
    static func moviesURL(ids: [Int]) -> URL? {
        let list = Array(ids.filter { $0 > 0 }.prefix(40))
        guard !list.isEmpty else { return nil }
        let query = "id:(" + list.map(String.init).joined(separator: " OR ") + ")"
        return select("movie", query: query, filters: [safeFilter], rows: list.count, fields: movieFields)
    }

    /// The titles of a person (actor, director…), the newest first: the index lists the people of
    /// every title by their Kinopoisk ids.
    static func personURL(id: Int, rows: Int = 80) -> URL? {
        guard id > 0 else { return nil }
        return select("movie", query: "personId:\(id)", filters: [safeFilter], sort: "year desc",
                      rows: rows, fields: movieFields + ["persons"])
    }

    /// A list of titles: a home collection, the catalog or a search.
    struct ListQuery: Equatable, Sendable {
        var query: String
        var filters: [String] = []
        var sort: String
        /// Lists such as "250 лучших" end after this many pages.
        var maxPages = 25
    }

    static func listURL(_ list: ListQuery, page: Int, rows: Int = pageSize) -> URL? {
        let page = max(1, page)
        return select("movie", query: list.query, filters: [safeFilter] + list.filters, sort: list.sort,
                      start: (page - 1) * rows, rows: rows, fields: movieFields)
    }

    static func totalPages(found: Int, list: ListQuery, rows: Int = pageSize) -> Int {
        let pages = (max(0, found) + rows - 1) / max(1, rows)
        return max(1, min(pages, list.maxPages))
    }

    /// The home collections of the Kinopoisk API ("TOP_POPULAR_ALL"…) made from the index.
    /// Zona's popularity is how many people watch a title now.
    static func collection(_ type: String) -> ListQuery {
        let playable = [playableFilter]
        switch type {
        case "TOP_POPULAR_MOVIES":
            return ListQuery(query: "serial:false", filters: playable, sort: "popularity desc")
        case "POPULAR_SERIES", "TOP_POPULAR_SERIES":
            return ListQuery(query: "serial:true", filters: playable, sort: "popularity desc")
        case "CLOSES_RELEASES":
            return ListQuery(query: "release_date_rus:[NOW/DAY TO NOW/DAY+120DAYS]", sort: "popularity desc", maxPages: 10)
        case "TOP_250_MOVIES":
            return ListQuery(query: "serial:false AND rating_kinopoisk_count:[100000 TO *]", filters: playable,
                             sort: "rating_kinopoisk desc,rating_kinopoisk_count desc", maxPages: 13)
        case "TOP_250_TV_SHOWS":
            return ListQuery(query: "serial:true AND rating_kinopoisk_count:[30000 TO *]", filters: playable,
                             sort: "rating_kinopoisk desc,rating_kinopoisk_count desc", maxPages: 13)
        case "FAMILY":
            return ListQuery(query: "genreId:11", filters: playable, sort: "popularity desc")
        case "KIDS_ANIMATION_THEME":
            return ListQuery(query: "genreId:14", filters: playable, sort: "popularity desc")
        case "LOVE_THEME":
            return ListQuery(query: "genreId:7", filters: playable, sort: "popularity desc")
        case "COMICS_THEME":
            return ListQuery(query: "description:комикс*", filters: playable, sort: "popularity desc")
        default:
            return ListQuery(query: "*:*", filters: playable, sort: "popularity desc")
        }
    }

    /// The catalog with the filters of the Kinopoisk API (type, genre and country by name,
    /// years, rating, order).
    static func catalog(series: Bool?, genre: String?, country: String?, years: ClosedRange<Int>?,
                        ratingFrom: Int, order: String) -> ListQuery {
        var clauses: [String] = []
        if let series = series { clauses.append("serial:\(series)") }
        if let genre = genre?.trimmed.lowercased(), !genre.isEmpty {
            // A genre the index does not know finds nothing rather than everything.
            clauses.append("genreId:\(genreIds[genre] ?? -1)")
        }
        if let country = country?.nonEmpty {
            let name = country.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "\\", with: " ")
            clauses.append("country:\"\(name.trimmed)\"")
        }
        if let years = years, years.lowerBound > 1800 || years.upperBound < 2100 {
            clauses.append("year:[\(years.lowerBound) TO \(years.upperBound)]")
        }
        if ratingFrom > 0 { clauses.append("rating_kinopoisk:[\(ratingFrom) TO *]") }
        var filters = [playableFilter]
        let sort: String
        switch order {
        case "RATING":
            sort = "rating_kinopoisk desc,rating_kinopoisk_count desc"
            filters.append("rating_kinopoisk_count:[1000 TO *]")
        case "YEAR":
            sort = "year desc,popularity desc"
        default:
            sort = "rating_kinopoisk_count desc"
        }
        return ListQuery(query: clauses.isEmpty ? "*:*" : clauses.joined(separator: " AND "), filters: filters, sort: sort)
    }

    /// Titles containing every typed word; the last word may be unfinished ("дюн" finds "Дюна").
    static func search(_ text: String) -> ListQuery? {
        let list = Array(words(text).prefix(8))
        guard let last = list.last else { return nil }
        var terms = list.dropLast().map { variants($0) }
        terms.append(last.count >= 2 ? "(\(variants(last)) OR \(last.replacingOccurrences(of: "ё", with: "е"))*)" : variants(last))
        let joined = terms.joined(separator: " AND ")
        let query = ["name_rus", "name_original", "name_eng"].map { "\($0):(\(joined))" }.joined(separator: " OR ")
        return ListQuery(query: query, sort: "popularity desc,rating_kinopoisk_count desc", maxPages: 10)
    }

    /// Lowercased letters and digits of a typed title, without Solr syntax.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// "ёлки" is written both ways in titles.
    private static func variants(_ word: String) -> String {
        let plain = word.replacingOccurrences(of: "ё", with: "е")
        return plain == word ? word : "(\(word) OR \(plain))"
    }

    // MARK: Images

    /// Zona's poster of a title (240×360), hosted in Russia.
    static func posterURL(kinopoiskId id: Int) -> String {
        "\(imageBase)/film_240/\(id / 1000)/\(id).jpg"
    }

    /// The large poster (up to 2000×3000); not every title has one.
    static func bigPosterURL(kinopoiskId id: Int) -> String {
        "\(imageBase)/film_big/\(id / 1000)/\(id).jpg"
    }

    /// A wide picture from the film (1280×720).
    static func backdropURL(_ id: Int) -> String {
        "\(imageBase)/backdrop_1280/\(id / 1000)/\(id).jpg"
    }

    /// Zona's copies of a poster of the Kinopoisk API, for when kinopoiskapiunofficial.tech (hosted
    /// abroad) does not give the picture: the large one for a large poster (then the small one, as
    /// not every title has it), the small one for a preview.
    static func posterFallbacks(for url: URL) -> [URL] {
        guard let host = url.host?.lowercased(), host.hasSuffix("kinopoiskapiunofficial.tech"),
              let g = Rx.groups("^/images/posters/(kp|kp_small|kp_big)/(\\d+)\\.jpg$", in: url.path),
              g.count == 2, let id = Int(g[1]), id > 0 else { return [] }
        let small = posterURL(kinopoiskId: id)
        let list = g[0] == "kp_small" ? [small] : [bigPosterURL(kinopoiskId: id), small]
        return list.compactMap { URL(string: $0) }
    }

    // MARK: Values

    /// "ru ru en" → ["ru", "en"].
    static func codes(_ text: String?) -> [String] {
        var result: [String] = []
        for code in (text ?? "").lowercased().components(separatedBy: CharacterSet.letters.inverted) where !code.isEmpty {
            if !result.contains(code) { result.append(code) }
        }
        return result
    }

    /// "фантастика, боевик" → ["фантастика", "боевик"].
    static func list(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: ",").compactMap { $0.nonEmpty }
    }
}

// MARK: - Answers

extension KeyedDecodingContainer where K == JSONKey {
    func flexDouble(_ names: String...) -> Double? {
        for name in names {
            let key = JSONKey(name)
            if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return value }
            if let text = try? decodeIfPresent(String.self, forKey: key),
               let value = Double(text.trimmed.replacingOccurrences(of: ",", with: ".")), value.isFinite {
                return value
            }
        }
        return nil
    }

    func flexBool(_ names: String...) -> Bool? {
        for name in names {
            let key = JSONKey(name)
            if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
            if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
            if let text = try? decodeIfPresent(String.self, forKey: key)?.lowercased() {
                if text == "true" || text == "1" { return true }
                if text == "false" || text == "0" { return false }
            }
        }
        return nil
    }
}

/// An answer of the index: {"response": {"numFound": 136, "docs": [...]}}.
struct ZonaPage<Doc: Decodable>: Decodable {
    var found: Int
    var docs: [Doc]

    init(found: Int, docs: [Doc]) {
        self.found = found
        self.docs = docs
    }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: JSONKey.self)
        let response = try root.nestedContainer(keyedBy: JSONKey.self, forKey: JSONKey("response"))
        let list = (try? response.decodeIfPresent([Lenient<Doc>].self, forKey: JSONKey("docs"))) ?? nil
        docs = (list ?? []).compactMap { $0.value }
        found = response.flexInt("numFound") ?? docs.count
    }
}

/// "S01E01 S01E02" (torrents) or "S01E01;S01E02" (titles).
struct ZonaEpisode: Hashable, Comparable, Sendable {
    var season: Int
    var episode: Int

    static func list(_ text: String) -> [ZonaEpisode] {
        var seen = Set<ZonaEpisode>()
        for g in Rx.allGroups("(?<![a-z0-9])s(\\d{1,3})e(\\d{1,4})(?![0-9])", in: text) {
            guard let season = Int(g[0]), let episode = Int(g[1]), episode > 0 else { continue }
            seen.insert(ZonaEpisode(season: season, episode: episode))
        }
        return seen.sorted()
    }

    static func < (lhs: ZonaEpisode, rhs: ZonaEpisode) -> Bool {
        (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
    }
}

/// One torrent of the index.
struct ZonaTorrent: Decodable, Sendable {
    var hash: String?
    var link: String?
    /// "1920x800".
    var resolution: String?
    var size: Int64 = 0
    /// "профессиональный многоголосый закадровый lostfilm".
    var translation: String?
    /// Audio languages read from the files: ["ru", "en"].
    var languages: [String] = []
    var subtitles: [String] = []
    var seeds = 0
    var peers = 0
    var episodes: [ZonaEpisode] = []
    /// How many times Zona's players started and failed to start the torrent.
    var starts = 0
    var failures = 0
    /// Advertising put into a torrent of the film.
    var isAdvertisement = false

    init(hash: String? = nil, link: String? = nil, resolution: String? = nil, size: Int64 = 0,
         translation: String? = nil, languages: [String] = [], subtitles: [String] = [], seeds: Int = 0,
         peers: Int = 0, episodes: [ZonaEpisode] = [], starts: Int = 0, failures: Int = 0) {
        self.hash = hash
        self.link = link
        self.resolution = resolution
        self.size = size
        self.translation = translation
        self.languages = languages
        self.subtitles = subtitles
        self.seeds = seeds
        self.peers = peers
        self.episodes = episodes
        self.starts = starts
        self.failures = failures
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        hash = c.flexString("hash")
        link = c.flexString("torrent_download_link")
        resolution = c.flexString("resolution")
        size = max(0, c.flexInt64("size_bytes") ?? 0)
        translation = c.flexString("translate_info")
        languages = ZonaIndex.codes(c.flexString("languages_parser"))
        subtitles = ZonaIndex.codes(c.flexString("subtitles_parser"))
        seeds = max(0, c.flexInt("seeds") ?? 0)
        peers = max(0, c.flexInt("peers") ?? 0)
        let episodeText = c.flexString("episodes") ?? c.flexStrings("episodes").joined(separator: " ")
        episodes = ZonaEpisode.list(episodeText)
        starts = max(0, c.flexInt("loading_success_count") ?? 0)
        failures = max(0, c.flexInt("loading_fail_count") ?? 0)
        isAdvertisement = c.flexBool("advertisement") ?? false
    }
}

/// A person of a title: {"i": 415350, "r": 1, "o": 0, "name": "Дени Вильнёв", "name_eng": "Denis Villeneuve"}.
struct ZonaPerson: Decodable, Hashable, Sendable {
    enum Role: Int, Sendable {
        case director = 1
        case producer = 2
        case writer = 3
        case actor = 4
    }

    var id: Int
    var name: String
    var nameEn: String?
    var role: Role?
    var order: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        id = c.flexInt("i") ?? 0
        nameEn = c.flexString("name_eng")
        name = c.flexString("name") ?? nameEn ?? ""
        role = c.flexInt("r").flatMap(Role.init(rawValue:))
        order = c.flexInt("o") ?? 0
    }

    /// The people of a title, directors first, then actors, writers and producers, each in order.
    static func list(json: String?) -> [ZonaPerson] {
        guard let data = json?.nonEmpty?.data(using: .utf8),
              let list = try? JSONDecoder().decode([Lenient<ZonaPerson>].self, from: data) else { return [] }
        let rank: [Role: Int] = [.director: 0, .actor: 1, .writer: 2, .producer: 3]
        var seen = Set<String>()
        return list.compactMap { $0.value }
            .filter { $0.id > 0 && !$0.name.isEmpty && $0.role != nil }
            .sorted { (rank[$0.role!] ?? 9, $0.order) < (rank[$1.role!] ?? 9, $1.order) }
            .filter { seen.insert("\($0.id)-\($0.role!.rawValue)").inserted }
    }
}

/// A link between two titles: {"rmi": 4540126, "mi": 409424, "r": 1, "p": 0}.
/// r 0 is "similar" (in the order p), the others are sequels, prequels and remakes.
private struct ZonaRelation: Decodable {
    var movie: Int
    var related: Int
    var kind: Int
    var position: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        movie = c.flexInt("mi") ?? 0
        related = c.flexInt("rmi") ?? 0
        kind = c.flexInt("r") ?? 0
        position = c.flexInt("p") ?? 0
    }
}

/// One title of the index.
struct ZonaMovie: Decodable, Sendable {
    var id: Int
    var nameRu: String?
    var nameOriginal: String?
    var nameEn: String?
    var year: Int?
    var isSeries = false
    var endYear: Int?
    var ended: Bool?
    var countries: [String] = []
    var genres: [String] = []
    var ratingKP: Double?
    var ratingIMDb: Double?
    var description: String?
    /// Minutes.
    var runtime: Int?
    var backdropId: Int?
    var persons: [ZonaPerson] = []
    /// Sequels, prequels and remakes first, then similar titles.
    var related: [Int] = []
    var episodes: [ZonaEpisode] = []

    init(id: Int, nameRu: String? = nil, nameOriginal: String? = nil, year: Int? = nil, isSeries: Bool = false) {
        self.id = id
        self.nameRu = nameRu
        self.nameOriginal = nameOriginal
        self.year = year
        self.isSeries = isSeries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: JSONKey.self)
        guard let id = c.flexInt("id"), id > 0 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No id"))
        }
        self.id = id
        nameRu = c.flexString("name_rus")
        nameOriginal = c.flexString("name_original")
        nameEn = c.flexString("name_eng")
        year = c.flexInt("year").flatMap { $0 > 0 ? $0 : nil }
        isSeries = c.flexBool("serial") ?? false
        endYear = c.flexInt("serial_end_year").flatMap { $0 > 0 ? $0 : nil }
        ended = c.flexBool("serial_ended")
        countries = ZonaIndex.list(c.flexString("country"))
        genres = ZonaIndex.list(c.flexString("genre_name"))
        ratingKP = c.flexDouble("rating_kinopoisk").flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
        ratingIMDb = c.flexDouble("rating_imdb").flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
        description = c.flexString("description")
        runtime = c.flexInt("runtime").flatMap { $0 > 0 ? $0 : nil }
        backdropId = c.flexInt("backdrop_id").flatMap { $0 > 0 ? $0 : nil }
        persons = ZonaPerson.list(json: c.flexString("persons"))
        related = ZonaMovie.related(json: c.flexString("rels"), of: id)
        episodes = ZonaEpisode.list(c.flexString("episodes") ?? "")
    }

    var title: String {
        nameRu?.nonEmpty ?? nameOriginal?.nonEmpty ?? nameEn?.nonEmpty ?? "Без названия"
    }

    /// A few titles of the index have no name at all: they are not listed.
    var hasName: Bool {
        nameRu?.nonEmpty != nil || nameOriginal?.nonEmpty != nil || nameEn?.nonEmpty != nil
    }

    var originalTitle: String? {
        let original = nameOriginal?.nonEmpty ?? nameEn?.nonEmpty
        return original == title ? nil : original
    }

    var posterURL: String { ZonaIndex.posterURL(kinopoiskId: id) }

    var backdropURL: String? { backdropId.map(ZonaIndex.backdropURL) }

    /// Seasons with their episodes, in order (season 0 is "specials").
    var seasons: [(number: Int, episodes: [Int])] {
        var map: [Int: [Int]] = [:]
        for item in episodes { map[item.season, default: []].append(item.episode) }
        return map.keys.sorted().map { (number: $0, episodes: Array(Set(map[$0] ?? [])).sorted()) }
    }

    private static func related(json: String?, of id: Int) -> [Int] {
        guard let data = json?.nonEmpty?.data(using: .utf8),
              let list = try? JSONDecoder().decode([Lenient<ZonaRelation>].self, from: data) else { return [] }
        let relations = list.compactMap { $0.value }
        let linked = relations.filter { $0.kind != 0 }
            .map { $0.related == id ? $0.movie : $0.related }
        let similar = relations.filter { $0.kind == 0 && $0.movie == id }
            .sorted { $0.position < $1.position }
            .map { $0.related }
        var seen: Set<Int> = [id, 0]
        return (linked + similar).filter { seen.insert($0).inserted }
    }
}

// MARK: - Torrents → releases

/// Voice-over studios named in Zona's description of the audio ("…закадровый lostfilm") under
/// the names Jacred gives them, so the "Озвучка" choices of both sources match.
enum ZonaVoices {
    private struct Studio {
        let pattern: String
        let name: String
        /// Also looked for in the torrent's name (a release-group tag that is never a film title).
        let inTitle: Bool
    }

    private static let studios: [Studio] = [
        Studio(pattern: "lost ?film|лостфильм", name: "LostFilm", inTitle: true),
        Studio(pattern: "new ?studio|ньюстудио", name: "NewStudio", inTitle: true),
        Studio(pattern: "кубик в кубе|kubik ?v ?kube|(?<![a-z])kvk(?![a-z])", name: "Кубик в Кубе", inTitle: true),
        Studio(pattern: "alex ?film", name: "AlexFilm", inTitle: true),
        Studio(pattern: "jaskier", name: "Jaskier", inTitle: true),
        Studio(pattern: "hd ?rezka|резка", name: "HDRezka", inTitle: true),
        Studio(pattern: "amedia|амедиа", name: "Amedia", inTitle: true),
        Studio(pattern: "tv ?shows", name: "TVShows", inTitle: true),
        Studio(pattern: "cold ?film", name: "ColdFilm", inTitle: true),
        Studio(pattern: "baibako|байбако", name: "BaibaKo", inTitle: true),
        Studio(pattern: "nova ?media", name: "Novamedia", inTitle: true),
        Studio(pattern: "nova ?film", name: "NovaFilm", inTitle: true),
        Studio(pattern: "idea ?film", name: "IdeaFilm", inTitle: true),
        Studio(pattern: "red ?head ?sound", name: "Red Head Sound", inTitle: true),
        Studio(pattern: "gears ?media", name: "Gears Media", inTitle: true),
        Studio(pattern: "pazl ?voice", name: "Pazl Voice", inTitle: true),
        Studio(pattern: "кураж[- ]?бамбей|kurazh", name: "Кураж-Бамбей", inTitle: true),
        Studio(pattern: "ultradox", name: "Ultradox", inTitle: true),
        Studio(pattern: "пифагор|pifagor", name: "Пифагор", inTitle: false),
        Studio(pattern: "sdi ?media", name: "SDI Media", inTitle: false),
        Studio(pattern: "невафильм|nevafilm", name: "Невафильм", inTitle: false),
        Studio(pattern: "кравец", name: "Кравец", inTitle: false),
        Studio(pattern: "сербин|serbin", name: "Сербин", inTitle: false),
        Studio(pattern: "пучков|гоблин|goblin", name: "Пучков", inTitle: false),
        Studio(pattern: "гаврилов|gavrilov", name: "Гаврилов", inTitle: false),
        Studio(pattern: "володарск|volodarsk", name: "Володарский", inTitle: false),
        Studio(pattern: "живов|zhivov", name: "Живов", inTitle: false),
        Studio(pattern: "михал[её]в|mikhalev", name: "Михалёв", inTitle: false),
        Studio(pattern: "яроцк", name: "Яроцкий", inTitle: false),
        Studio(pattern: "есарев", name: "Есарев", inTitle: false),
        Studio(pattern: "визгунов", name: "Визгунов", inTitle: false),
        Studio(pattern: "дохалов", name: "Дохалов", inTitle: false),
        Studio(pattern: "дольск", name: "Дольский", inTitle: false),
        Studio(pattern: "fox ?crime", name: "Fox Crime", inTitle: false),
        Studio(pattern: "fox ?life", name: "Fox Life", inTitle: false),
        Studio(pattern: "рен ?тв|ren ?tv", name: "РенТВ", inTitle: false),
        Studio(pattern: "tv1000", name: "TV1000", inTitle: false)
    ]

    static func studios(translation: String, title: String) -> [String] {
        var found: [String] = []
        for studio in studios {
            let pattern = "(?<![a-zа-яё])(?:\(studio.pattern))"
            if Rx.matches(pattern, in: translation) || (studio.inTitle && Rx.matches(pattern, in: title)) {
                found.append(studio.name)
            }
        }
        return found
    }
}

enum ZonaReleases {
    /// Shown as the "tracker" of a release found in the index.
    static let source = "Zona"

    private static let languageNames: [String: String] = [
        "ru": "Русский", "en": "Английский", "uk": "Украинский", "ja": "Японский", "ko": "Корейский",
        "fr": "Французский", "de": "Немецкий", "es": "Испанский", "it": "Итальянский", "zh": "Китайский",
        "tr": "Турецкий", "pl": "Польский", "pt": "Португальский", "hi": "Хинди", "kk": "Казахский"
    ]

    static func release(from doc: ZonaTorrent) -> TorrentRelease? {
        guard !doc.isAdvertisement, let link = doc.link?.nonEmpty, link.lowercased().hasPrefix("magnet:") else { return nil }
        let given = doc.hash.flatMap { LinkInspector.isInfoHash($0) ? $0.lowercased() : nil }
        guard let hash = given ?? LinkInspector.infoHash(of: link) else { return nil }
        let title = displayName(link: link) ?? "Раздача \(hash.prefix(8))"
        let translation = doc.translation ?? ""

        var kinds = Set(ReleaseParser.voiceKinds(in: title))
        kinds.formUnion(ReleaseParser.voiceKinds(in: translation))
        if doc.subtitles.contains("ru") { kinds.insert(.subtitles) }

        let seasons = doc.episodes.isEmpty
            ? ReleaseParser.seasons(in: title)
            : Array(Set(doc.episodes.map { $0.season }.filter { $0 > 0 })).sorted()
        let audio = doc.languages.map { languageNames[$0] ?? $0.uppercased() }

        return TorrentRelease(
            id: hash,
            title: title,
            link: link,
            hash: hash,
            size: max(0, doc.size),
            seeders: max(0, doc.seeds),
            peers: max(0, doc.peers),
            trackers: [source],
            published: nil,
            quality: ReleaseParser.quality(title: title, height: equivalentHeight(doc.resolution)),
            isHDR: ReleaseParser.isHDR(title: title),
            isCamRip: ReleaseParser.isCamRip(title),
            seasons: seasons,
            voiceKinds: kinds.sorted(),
            studios: ZonaVoices.studios(translation: translation, title: title),
            audioTracks: Array(audio.prefix(8)),
            year: ReleaseParser.year(in: title),
            isSeries: doc.episodes.isEmpty ? nil : true,
            detailsURL: nil,
            languages: doc.languages.isEmpty ? nil : doc.languages,
            knownStarts: doc.starts,
            knownFailures: doc.failures
        )
    }

    /// Releases of the answer, one per torrent.
    static func build(from docs: [ZonaTorrent]) -> [TorrentRelease] {
        var seen = Set<String>()
        return docs.compactMap(release(from:)).filter { seen.insert($0.id).inserted }
    }

    /// The torrent's name from the "dn" of its magnet link, without the file extension.
    static func displayName(link: String) -> String? {
        guard let start = link.firstIndex(of: "?") else { return nil }
        for part in link[link.index(after: start)...].split(separator: "&") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2, pieces[0].lowercased() == "dn" else { continue }
            let raw = String(pieces[1]).replacingOccurrences(of: "+", with: " ")
            var name = (raw.removingPercentEncoding ?? raw).trimmed
            if let g = Rx.groups("^(.+)\\.(mkv|avi|mp4|m4v|mov|wmv)$", in: name) { name = g[0].trimmed }
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The height a 16:9 picture of the same width would have: 1920×800 is a 1080p copy.
    static func equivalentHeight(_ resolution: String?) -> Int? {
        guard let text = resolution, let g = Rx.groups("(\\d{3,4})\\s*[x×*]\\s*(\\d{3,4})", in: text),
              let width = Int(g[0]), let height = Int(g[1]), width > 0, height > 0 else { return nil }
        return max(height, width * 9 / 16)
    }
}

// MARK: - Merging sources

enum ReleaseMerge {
    /// Releases of the index together with the ones found by title: the same torrent (by its
    /// hash) becomes one release that keeps the more descriptive tracker title, the larger
    /// seeder count and the voice-overs and languages of both.
    static func merge(_ zona: [TorrentRelease], _ other: [TorrentRelease]) -> [TorrentRelease] {
        var result = zona
        var index: [String: Int] = [:]
        for (position, release) in result.enumerated() where index[key(release)] == nil {
            index[key(release)] = position
        }
        for release in other {
            let k = key(release)
            if let position = index[k] {
                result[position] = combined(zona: result[position], tracker: release)
            } else {
                index[k] = result.count
                result.append(release)
            }
        }
        return result
    }

    private static func key(_ release: TorrentRelease) -> String {
        (release.hash ?? release.id).lowercased()
    }

    static func combined(zona: TorrentRelease, tracker: TorrentRelease) -> TorrentRelease {
        var release = tracker
        release.seeders = max(zona.seeders, tracker.seeders)
        release.peers = max(zona.peers, tracker.peers)
        for name in zona.trackers where !release.trackers.contains(name) {
            release.trackers.append(name)
        }
        if release.size <= 0 { release.size = zona.size }
        if release.quality == .unknown { release.quality = zona.quality }
        release.isHDR = release.isHDR || zona.isHDR
        if release.seasons.isEmpty { release.seasons = zona.seasons }
        release.voiceKinds = Array(Set(release.voiceKinds).union(zona.voiceKinds)).sorted()
        for studio in zona.studios
        where !release.studios.contains(where: { $0.compare(studio, options: .caseInsensitive) == .orderedSame }) {
            release.studios.append(studio)
        }
        if release.audioTracks.isEmpty { release.audioTracks = zona.audioTracks }
        if release.isSeries == nil { release.isSeries = zona.isSeries }
        if release.languages == nil { release.languages = zona.languages }
        if release.knownStarts == nil { release.knownStarts = zona.knownStarts }
        if release.knownFailures == nil { release.knownFailures = zona.knownFailures }
        return release
    }
}
