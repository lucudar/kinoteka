import Foundation

enum ZonaCatalogError: LocalizedError {
    case notFound
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Ничего не найдено."
        case .http(let code):
            return "Каталог Zona не отвечает (ошибка \(code)). Попробуйте позже."
        case .badResponse:
            return "Каталог Zona вернул неожиданный ответ."
        }
    }
}

/// The catalog of Zona's index (zsolr3.zonasearch.com, hosted in Russia) as the app's Kinopoisk
/// models: home collections, the catalog with filters, the search, film pages with seasons and
/// people, similar titles and the films of a person.
///
/// Used when the Kinopoisk API has no key or does not answer: it is hosted abroad and often slowed
/// down on Russian networks without a VPN, while the index answers there quickly and needs no key.
/// Posters keep the Kinopoisk API addresses: the picture cache takes Zona's copies when those do
/// not come.
actor ZonaCatalog {
    static let shared = ZonaCatalog()

    enum TTL {
        static let list: TimeInterval = 60 * 60 * 6
        static let movie: TimeInterval = 60 * 60 * 24 * 3
    }

    /// The catalog is used without a key and when the Kinopoisk API fails (on by default).
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.zonaIndex) as? Bool ?? true
    }

    private let session: URLSession
    private let cacheDir: URL
    private var running: [URL: Task<Data, Error>] = [:]
    /// A film page asks for the title, its seasons and people at once: one answer serves all three.
    private var movies: [Int: (date: Date, movie: ZonaMovie)] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
        cacheDir = ZonaCatalog.directory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zona-cache", isDirectory: true)
    }

    // MARK: Lists

    func collection(_ type: String, page: Int) async throws -> KPPage {
        try await list(ZonaIndex.collection(type), page: page)
    }

    func films(_ filter: CatalogFilter, page: Int) async throws -> KPPage {
        let decade = Decade.byId(filter.decade)
        let series: Bool?
        switch filter.type {
        case "TV_SERIES", "MINI_SERIES", "TV_SHOW": series = true
        case "FILM": series = false
        default: series = nil
        }
        let list = ZonaIndex.catalog(series: series, genre: filter.genreName, country: filter.countryName,
                                     years: decade.from...decade.to, ratingFrom: filter.ratingFrom, order: filter.order)
        return try await self.list(list, page: page)
    }

    func search(_ text: String, page: Int) async throws -> KPPage {
        guard let list = ZonaIndex.search(text) else { return KPPage(totalPages: 1, items: []) }
        return try await self.list(list, page: page)
    }

    private func list(_ list: ZonaIndex.ListQuery, page: Int) async throws -> KPPage {
        guard page <= list.maxPages else { return KPPage(totalPages: list.maxPages, items: []) }
        guard let url = ZonaIndex.listURL(list, page: page) else { throw ZonaCatalogError.badResponse }
        let answer: ZonaPage<ZonaMovie> = try await load(url, ttl: TTL.list)
        return KPPage(totalPages: ZonaIndex.totalPages(found: answer.found, list: list),
                      items: answer.docs.filter { $0.hasName }.map { $0.item })
    }

    // MARK: Film page

    func movie(_ id: Int) async throws -> ZonaMovie {
        if let hit = movies[id], Date().timeIntervalSince(hit.date) < 30 * 60 { return hit.movie }
        guard let url = ZonaIndex.movieURL(id: id) else { throw ZonaCatalogError.notFound }
        let answer: ZonaPage<ZonaMovie> = try await load(url, ttl: TTL.movie)
        guard let movie = answer.docs.first(where: { $0.id == id }) else { throw ZonaCatalogError.notFound }
        if movies.count > 80 { movies.removeAll() }
        movies[id] = (Date(), movie)
        return movie
    }

    func film(_ id: Int) async throws -> KPFilm {
        try await movie(id).film
    }

    func seasons(_ id: Int) async throws -> [KPSeason] {
        try await movie(id).kpSeasons
    }

    func staff(_ id: Int) async throws -> [KPStaff] {
        try await movie(id).staff
    }

    /// Sequels and remakes first, then the titles Zona finds similar, in its order.
    func similars(_ id: Int) async throws -> [MediaItem] {
        let related = Array(try await movie(id).related.prefix(30))
        guard let url = ZonaIndex.moviesURL(ids: related) else { return [] }
        let answer: ZonaPage<ZonaMovie> = try await load(url, ttl: TTL.movie)
        var byId: [Int: ZonaMovie] = [:]
        for movie in answer.docs where byId[movie.id] == nil { byId[movie.id] = movie }
        return related.compactMap { byId[$0] }.filter { $0.hasName }.map { $0.item }
    }

    /// The films of a person, with the kind of work from the people of each film.
    func person(_ id: Int) async throws -> KPPerson {
        guard let url = ZonaIndex.personURL(id: id) else { throw ZonaCatalogError.notFound }
        let answer: ZonaPage<ZonaMovie> = try await load(url, ttl: TTL.movie)
        var nameRu: String?
        var nameEn: String?
        var films: [KPPersonFilm] = []
        for movie in answer.docs where movie.hasName {
            let roles = movie.persons.filter { $0.id == id }
            if nameRu == nil, let first = roles.first {
                nameRu = first.name.nonEmpty
                nameEn = first.nameEn?.nonEmpty
            }
            let keys = roles.compactMap { $0.role?.professionKey }
            for key in keys.isEmpty ? ["UNKNOWN"] : keys {
                films.append(KPPersonFilm(filmId: movie.id, nameRu: movie.personFilmName, nameEn: movie.originalTitle,
                                          rating: movie.ratingKP, professionKey: key))
            }
        }
        guard !films.isEmpty else { throw ZonaCatalogError.notFound }
        return KPPerson(personId: id, nameRu: nameRu, nameEn: nameEn,
                        posterUrl: "https://kinopoiskapiunofficial.tech/images/actor_posters/kp/\(id).jpg", films: films)
    }

    /// Genres for the catalog filters without the Kinopoisk API: the names are enough for the index.
    nonisolated static func filters() -> KPFilters {
        let genres = ZonaIndex.genreIds.keys
            .filter { $0 != "для взрослых" }
            .map { KPFilterValue(id: nil, genre: $0 == "реальное тв" ? "реальное ТВ" : $0, country: nil) }
        let countries = ["Россия", "СССР", "США", "Великобритания", "Франция", "Германия", "Италия", "Испания",
                         "Япония", "Корея Южная", "Китай", "Индия", "Канада", "Австралия", "Турция", "Бразилия",
                         "Мексика", "Швеция", "Дания", "Норвегия", "Польша", "Украина", "Беларусь", "Казахстан"]
            .map { KPFilterValue(id: nil, genre: nil, country: $0) }
        return KPFilters(genres: genres, countries: countries)
    }

    // MARK: Network and cache

    /// Fresh saved answers at once, otherwise the index (and an older saved answer when it fails).
    private func load<T: Decodable>(_ url: URL, ttl: TimeInterval) async throws -> T {
        let file = cacheDir.appendingPathComponent(CacheName.digest(url.absoluteString) + ".json")
        if let value: T = ZonaCatalog.read(file, maxAge: ttl) { return value }
        do {
            let data = try await download(url)
            guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                AppDiagnostics.shared.log("zona", "Каталог: неожиданный ответ, \(data.count) байт")
                throw ZonaCatalogError.badResponse
            }
            try? data.write(to: file, options: .atomic)
            return value
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if let stale: T = ZonaCatalog.read(file, maxAge: nil) { return stale }
            throw error
        }
    }

    private nonisolated static func read<T: Decodable>(_ file: URL, maxAge: TimeInterval?) -> T? {
        if let maxAge = maxAge {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(date) < maxAge else { return nil }
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Equal requests made at the same time (a film, its seasons and people) share one download.
    private func download(_ url: URL) async throws -> Data {
        if let task = running[url] { return try await task.value }
        let session = session
        let task = Task<Data, Error> {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let started = Date()
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code) else {
                    AppDiagnostics.shared.log("zona", "Каталог: HTTP \(code)")
                    throw ZonaCatalogError.http(code)
                }
                let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
                if elapsed > 3_000 {
                    AppDiagnostics.shared.log("zona", "Каталог: медленный ответ, \(elapsed) мс, \(data.count / 1024) КБ")
                }
                return data
            } catch let error as URLError {
                if error.code != .cancelled {
                    AppDiagnostics.shared.log("zona", "Каталог: ошибка сети: \(error.localizedDescription)")
                }
                throw error
            }
        }
        running[url] = task
        defer { running[url] = nil }
        return try await task.value
    }

    nonisolated func clearCache() {
        let dir = ZonaCatalog.directory
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    nonisolated var cacheBytes: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: ZonaCatalog.directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Answers not used for a month are removed, in the background.
    nonisolated func pruneCache(olderThan age: TimeInterval = 60 * 60 * 24 * 30) {
        let dir = ZonaCatalog.directory
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 25) {
            let manager = FileManager.default
            let files = (try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let now = Date()
            for file in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(date) > age { try? manager.removeItem(at: file) }
            }
        }
    }
}

// MARK: - Index → Kinopoisk models

extension ZonaPerson.Role {
    var professionKey: String {
        switch self {
        case .director: return "DIRECTOR"
        case .producer: return "PRODUCER"
        case .writer: return "WRITER"
        case .actor: return "ACTOR"
        }
    }

    var professionText: String {
        switch self {
        case .director: return "Режиссеры"
        case .producer: return "Продюсеры"
        case .writer: return "Сценаристы"
        case .actor: return "Актеры"
        }
    }
}

extension ZonaMovie {
    /// The Kinopoisk API's address of the poster, as in its own answers.
    static func kinopoiskPoster(_ id: Int, small: Bool) -> String {
        "https://kinopoiskapiunofficial.tech/images/posters/\(small ? "kp_small" : "kp")/\(id).jpg"
    }

    var item: MediaItem {
        MediaItem(id: id, title: title, originalTitle: originalTitle, year: year,
                  posterURL: ZonaMovie.kinopoiskPoster(id, small: false),
                  posterPreviewURL: ZonaMovie.kinopoiskPoster(id, small: true),
                  ratingKP: ratingKP, ratingIMDb: ratingIMDb, kind: isSeries ? .series : .movie,
                  genres: genres, countries: countries)
    }

    var film: KPFilm {
        KPFilm(kinopoiskId: id, imdbId: nil, nameRu: nameRu?.nonEmpty, nameEn: nameEn?.nonEmpty,
               nameOriginal: nameOriginal?.nonEmpty,
               posterUrl: ZonaMovie.kinopoiskPoster(id, small: false),
               posterUrlPreview: ZonaMovie.kinopoiskPoster(id, small: true),
               coverUrl: backdropURL, ratingKinopoisk: ratingKP, ratingImdb: ratingIMDb,
               webUrl: "https://www.kinopoisk.ru/\(isSeries ? "series" : "film")/\(id)/",
               year: year, filmLength: runtime, slogan: nil, description: description, shortDescription: nil,
               type: isSeries ? "TV_SERIES" : "FILM", ratingAgeLimits: nil,
               countries: countries.map { KPCountry(country: $0) }, genres: genres.map { KPGenre(genre: $0) },
               startYear: isSeries ? year : nil, endYear: isSeries ? endYear : nil,
               serial: isSeries, completed: isSeries ? ended : nil)
    }

    /// Episodes as numbers only: the index has no names or dates of episodes.
    var kpSeasons: [KPSeason] {
        seasons.filter { $0.number > 0 || seasons.count == 1 }.map { season in
            KPSeason(number: season.number, episodes: season.episodes.map {
                KPEpisode(seasonNumber: season.number, episodeNumber: $0, nameRu: nil, nameEn: nil, synopsis: nil, releaseDate: nil)
            })
        }
    }

    var staff: [KPStaff] {
        persons.compactMap { person in
            guard let role = person.role else { return nil }
            return KPStaff(staffId: person.id, nameRu: person.name.nonEmpty, nameEn: person.nameEn?.nonEmpty, description: nil,
                           posterUrl: "https://kinopoiskapiunofficial.tech/images/actor_posters/kp/\(person.id).jpg",
                           professionText: role.professionText, professionKey: role.professionKey)
        }
    }

    /// The name in the form of the Kinopoisk lists of a person's films: "Во все тяжкие (сериал, 2008)".
    var personFilmName: String {
        switch (isSeries, year) {
        case (true, let year?): return "\(title) (сериал, \(year))"
        case (true, nil): return "\(title) (сериал)"
        case (false, let year?): return "\(title) (\(year))"
        case (false, nil): return title
        }
    }
}
