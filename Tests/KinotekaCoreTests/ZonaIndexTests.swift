import XCTest
@testable import KinotekaCore

final class ZonaIndexTests: XCTestCase {
    /// Trimmed answers of zsolr3.zonasearch.com (torrents of "Матрица" and "Во все тяжкие").
    private let torrentsJSON = """
    {"responseHeader":{"status":0,"QTime":3},"response":{"numFound":136,"start":0,"docs":[
      {"torrent_download_link":"magnet:?xt=urn:btih:363bc6c534b1430c6758318d196ccd61db61b647&dn=The+Matrix+%281999%29+720p+BrRip+x264+-+700mb+-+YIFY&tr=http%3A%2F%2Fretracker.local%2Fannounce",
       "size_bytes":738095006,"peers":1213,"resolution":"1280x532","subtitles_parser":"en","languages_parser":"en",
       "seeds":645,"loading_fail_count":0,"loading_success_count":4,"hash":"363bc6c534b1430c6758318d196ccd61db61b647"},
      {"torrent_download_link":"magnet:?xt=urn:btih:AAAABBBBCCCCDDDDEEEEFFFF0000111122223333&dn=%D0%9C%D0%B0%D1%82%D1%80%D0%B8%D1%86%D0%B0+%281999%29+BDRip-1080p.mkv",
       "size_bytes":"28131737600","peers":72,"resolution":"1920x800","translate_info":"профессиональный дублированный",
       "languages_parser":"ru en","subtitles_parser":"ru uk en","seeds":69,"loading_fail_count":1,"loading_success_count":5,
       "hash":"aaaabbbbccccddddeeeeffff0000111122223333"},
      {"torrent_download_link":"magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=%D0%9C%D0%B0%D1%82%D1%80%D0%B8%D1%86%D0%B0+%2F+The+Matrix+%281999%29+BDRip+%5BH.265%2F2160p%5D+%5B4K%2C+HDR10%2C+10-bit%5D",
       "size_bytes":14173392076,"peers":1,"resolution":"3840x1600","translate_info":"дублированный лицензия",
       "languages_parser":"en ru","seeds":19,"hash":"1111111111111111111111111111111111111111"},
      {"torrent_download_link":"magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=Matrica.1999.RUS.BDRip.XviD.AC3.-HRIME",
       "size_bytes":2791728742,"resolution":"704x288","translate_info":"авторский одноголосый, закадровый | д.пучков - goblin",
       "languages_parser":"ru","seeds":24,"peers":30,"loading_fail_count":7,"loading_success_count":1},
      {"torrent_download_link":"magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=V0.vs3.tyajk1e.s05e09.720p.KvK.mkv",
       "size_bytes":1610612736,"resolution":"1280x720","translate_info":"профессиональное двухголосое  кубик в кубе",
       "episodes":"S05E09","seeds":507,"peers":20},
      {"torrent_download_link":"magnet:?xt=urn:btih:4444444444444444444444444444444444444444&dn=Breaking+Bad+Season+1%2C+2%2C+3%2C+4+%2B+Extras+DVDRip+HDTV+TSV",
       "size_bytes":20723217203,"resolution":"848x480","episodes":"S01E01 S01E02 S02E01 S03E01 S04E13","seeds":1364,"peers":5},
      {"torrent_download_link":"http://mults.info/torrents/detstvo_koroleva.torrent","seeds":4,"hash":"e61c0d742d4a15c6fa13adcf15b74220feda9949"},
      {"torrent_download_link":"magnet:?xt=urn:btih:363bc6c534b1430c6758318d196ccd61db61b647&dn=Duplicate","seeds":1},
      "broken"
    ]}}
    """

    private let movieJSON = """
    {"response":{"numFound":1,"start":0,"docs":[{"country":"США, Канада, Венгрия","year":2021,"name_original":"Dune: Part One",
     "name_eng":"","id":"409424","rating_imdb":8.0,"rating_kinopoisk":7.7,"runtime":155,"serial":false,"serial_end_year":0,
     "backdrop_id":302154,"genre_name":"фантастика, боевик, драма, приключения","name_rus":"Дюна",
     "description":"Наследник знаменитого дома Атрейдесов Пол отправляется на Арракис.",
     "persons":"[{\\"o\\":1,\\"r\\":4,\\"i\\":498650,\\"name\\":\\"Ребекка Фергюсон\\",\\"name_eng\\":\\"Rebecca Ferguson\\"},{\\"o\\":0,\\"r\\":4,\\"i\\":1665224,\\"name\\":\\"Тимоти Шаламе\\",\\"name_eng\\":\\"Timothée Chalamet\\"},{\\"o\\":0,\\"r\\":1,\\"i\\":415350,\\"name\\":\\"Дени Вильнёв\\",\\"name_eng\\":\\"Denis Villeneuve\\"},{\\"o\\":0,\\"r\\":3,\\"i\\":415350,\\"name\\":\\"Дени Вильнёв\\",\\"name_eng\\":\\"Denis Villeneuve\\"},{\\"o\\":0,\\"r\\":9,\\"i\\":5,\\"name\\":\\"?\\"}]",
     "rels":"[{\\"rmi\\":4540126,\\"mi\\":409424,\\"r\\":1,\\"p\\":0},{\\"rmi\\":409424,\\"mi\\":2882,\\"r\\":4,\\"p\\":0},{\\"rmi\\":333,\\"mi\\":409424,\\"r\\":0,\\"p\\":3},{\\"rmi\\":589290,\\"mi\\":409424,\\"r\\":0,\\"p\\":1},{\\"rmi\\":2882,\\"mi\\":409424,\\"r\\":0,\\"p\\":2}]"}]}}
    """

    private func torrents() throws -> ZonaPage<ZonaTorrent> {
        try JSONDecoder().decode(ZonaPage<ZonaTorrent>.self, from: Data(torrentsJSON.utf8))
    }

    func testDecodesTorrentsLeniently() throws {
        let page = try torrents()
        XCTAssertEqual(page.found, 136)
        XCTAssertEqual(page.docs.count, 8)
        let second = page.docs[1]
        XCTAssertEqual(second.size, 28_131_737_600)
        XCTAssertEqual(second.languages, ["ru", "en"])
        XCTAssertEqual(second.subtitles, ["ru", "uk", "en"])
        XCTAssertEqual(page.docs[5].episodes.map { $0.season }, [1, 1, 2, 3, 4])
    }

    func testBuildsReleases() throws {
        let releases = ZonaReleases.build(from: try torrents().docs)
        // The .torrent link and the second copy of the first hash are left out.
        XCTAssertEqual(releases.count, 6)

        let yify = releases[0]
        XCTAssertEqual(yify.id, "363bc6c534b1430c6758318d196ccd61db61b647")
        XCTAssertEqual(yify.title, "The Matrix (1999) 720p BrRip x264 - 700mb - YIFY")
        XCTAssertEqual(yify.quality, .hd)
        XCTAssertEqual(yify.trackers, ["Zona"])
        XCTAssertEqual(yify.audioTracks, ["Английский"])
        XCTAssertTrue(yify.isOriginalOnly)
        XCTAssertNil(yify.isSeries)

        let dub = releases[1]
        XCTAssertEqual(dub.hash, "aaaabbbbccccddddeeeeffff0000111122223333")
        XCTAssertEqual(dub.title, "Матрица (1999) BDRip-1080p")
        XCTAssertEqual(dub.quality, .fullHD)
        XCTAssertEqual(dub.voiceKinds, [.dub, .subtitles])
        XCTAssertEqual(dub.audioTracks, ["Русский", "Английский"])
        XCTAssertFalse(dub.isOriginalOnly)
        XCTAssertEqual(dub.knownStarts, 5)

        let uhd = releases[2]
        XCTAssertEqual(uhd.quality, .uhd)
        XCTAssertTrue(uhd.isHDR)
        XCTAssertEqual(uhd.voiceKinds, [.dub])

        let goblin = releases[3]
        XCTAssertEqual(goblin.quality, .sd)
        XCTAssertEqual(goblin.voiceKinds, [.single, .author])
        XCTAssertEqual(goblin.studios, ["Пучков"])
        XCTAssertEqual(goblin.hash, "2222222222222222222222222222222222222222")

        let episode = releases[4]
        XCTAssertEqual(episode.title, "V0.vs3.tyajk1e.s05e09.720p.KvK")
        XCTAssertEqual(episode.quality, .hd)
        XCTAssertEqual(episode.seasons, [5])
        XCTAssertEqual(episode.isSeries, true)
        XCTAssertEqual(episode.voiceKinds, [.two])
        XCTAssertEqual(episode.studios, ["Кубик в Кубе"])

        let pack = releases[5]
        XCTAssertEqual(pack.seasons, [1, 2, 3, 4])
        XCTAssertFalse(pack.isCamRip)
        XCTAssertEqual(pack.quality, .sd)
    }

    func testQualityFromResolution() {
        XCTAssertEqual(ZonaReleases.equivalentHeight("1920x800"), 1080)
        XCTAssertEqual(ZonaReleases.equivalentHeight("1916x794"), 1077)
        XCTAssertEqual(ZonaReleases.equivalentHeight("1440x1080"), 1080)
        XCTAssertEqual(ZonaReleases.equivalentHeight("720x304"), 405)
        XCTAssertNil(ZonaReleases.equivalentHeight("Не указано"))
        XCTAssertNil(ZonaReleases.equivalentHeight(nil))
        XCTAssertEqual(ReleaseParser.quality(title: "Matrix", height: ZonaReleases.equivalentHeight("1272x720")), .hd)
        XCTAssertEqual(ReleaseParser.quality(title: "Matrix", height: ZonaReleases.equivalentHeight("1056x594")), .sd)
        // An explicit resolution in the name still wins.
        XCTAssertEqual(ReleaseParser.quality(title: "Movie 1080p", height: ZonaReleases.equivalentHeight("1280x720")), .fullHD)
    }

    func testVoicesFromTranslation() {
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "проф. полное дублирование"), [.dub])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Профессиональный (многоголосый, закадровый) РТР / НТВ"), [.multi])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "любительский двухголосый Pazl Voice"), [.two, .amateur])
        XCTAssertEqual(ZonaVoices.studios(translation: "любительский двухголосый Pazl Voice", title: ""), ["Pazl Voice"])
        XCTAssertEqual(ZonaVoices.studios(translation: "профессиональный многоголосый закадровый lostfilm", title: ""), ["LostFilm"])
        XCTAssertEqual(ZonaVoices.studios(translation: "", title: "Breaking.Bad.S01.LostFilm.720p"), ["LostFilm"])
        // Names that can be a film title are taken from the audio description only.
        XCTAssertEqual(ZonaVoices.studios(translation: "", title: "Гоблин (2016)"), [])
        XCTAssertEqual(ZonaVoices.studios(translation: "нарезка", title: ""), [])
    }

    func testDisplayName() {
        XCTAssertEqual(ZonaReleases.displayName(link: "magnet:?xt=urn:btih:abc&dn=The.Matrix.1999.mkv&tr=x"), "The.Matrix.1999")
        XCTAssertEqual(ZonaReleases.displayName(link: "magnet:?dn=%D0%94%D1%8E%D0%BD%D0%B0+2021&xt=urn:btih:abc"), "Дюна 2021")
        XCTAssertNil(ZonaReleases.displayName(link: "magnet:?xt=urn:btih:abc"))
    }

    func testDecodesMovie() throws {
        let page = try JSONDecoder().decode(ZonaPage<ZonaMovie>.self, from: Data(movieJSON.utf8))
        let movie = try XCTUnwrap(page.docs.first)
        XCTAssertEqual(movie.id, 409424)
        XCTAssertEqual(movie.title, "Дюна")
        XCTAssertEqual(movie.originalTitle, "Dune: Part One")
        XCTAssertEqual(movie.year, 2021)
        XCTAssertFalse(movie.isSeries)
        XCTAssertNil(movie.endYear)
        XCTAssertEqual(movie.countries, ["США", "Канада", "Венгрия"])
        XCTAssertEqual(movie.genres.first, "фантастика")
        XCTAssertEqual(movie.ratingKP, 7.7)
        XCTAssertEqual(movie.runtime, 155)
        XCTAssertEqual(movie.posterURL, "https://img2.zonapic.com/images/film_240/409/409424.jpg")
        XCTAssertEqual(movie.backdropURL, "https://img2.zonapic.com/images/backdrop_1280/302/302154.jpg")
        // Directors first, then actors in their order; an unknown role is dropped.
        XCTAssertEqual(movie.persons.map { $0.name }, ["Дени Вильнёв", "Тимоти Шаламе", "Ребекка Фергюсон", "Дени Вильнёв"])
        XCTAssertEqual(movie.persons.map { $0.role }, [.director, .actor, .actor, .writer])
        // The sequel and the remake, then the similar films in their order.
        XCTAssertEqual(movie.related, [4540126, 2882, 589290, 333])
    }

    func testSeasonsOfSeries() {
        var movie = ZonaMovie(id: 404900, nameRu: "Во все тяжкие", isSeries: true)
        movie.episodes = ZonaEpisode.list("S01E01;S01E02;S02E01;S02E02;S02E02;S00E01")
        XCTAssertEqual(movie.seasons.map { $0.number }, [0, 1, 2])
        XCTAssertEqual(movie.seasons.last?.episodes, [1, 2])
    }

    func testRequests() throws {
        let url = try XCTUnwrap(ZonaIndex.releasesURL(kinopoiskId: 301))
        XCTAssertEqual(url.host, "zsolr3.zonasearch.com")
        XCTAssertEqual(url.path, "/solr/torrent/select")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "kinopoisk_id:301")
        XCTAssertEqual(items.first { $0.name == "sort" }?.value, "seeds desc")
        XCTAssertEqual(items.first { $0.name == "rows" }?.value, "150")
        XCTAssertNil(ZonaIndex.releasesURL(kinopoiskId: 0))

        let soon = try XCTUnwrap(ZonaIndex.listURL(ZonaIndex.collection("CLOSES_RELEASES"), page: 2))
        XCTAssertTrue(soon.absoluteString.contains("NOW/DAY%2B120DAYS"), soon.absoluteString)
        XCTAssertTrue(soon.absoluteString.contains("start=20"))

        let search = try XCTUnwrap(ZonaIndex.search("Человек-паук: «Нет пути»"))
        XCTAssertTrue(search.query.hasPrefix("name_rus:(человек AND паук AND нет AND (пути OR пути*))"), search.query)
        XCTAssertNil(ZonaIndex.search(" :: "))
        XCTAssertTrue(try XCTUnwrap(ZonaIndex.search("ёлки")).query.contains("(ёлки OR елки)"))

        let catalog = ZonaIndex.catalog(series: true, genre: "Комедия", country: "США", years: 2020...2029, ratingFrom: 7, order: "RATING")
        XCTAssertEqual(catalog.query, "serial:true AND genreId:6 AND country:\"США\" AND year:[2020 TO 2029] AND rating_kinopoisk:[7 TO *]")
        XCTAssertEqual(ZonaIndex.catalog(series: nil, genre: "церемония", country: nil, years: 1000...3000, ratingFrom: 0, order: "NUM_VOTE").query, "genreId:-1")
        XCTAssertEqual(ZonaIndex.totalPages(found: 2544, list: ZonaIndex.collection("TOP_250_MOVIES")), 13)
        XCTAssertEqual(ZonaIndex.totalPages(found: 0, list: ZonaIndex.collection("FAMILY")), 1)
    }

    func testPosterFallbacks() throws {
        let kp = try XCTUnwrap(URL(string: "https://kinopoiskapiunofficial.tech/images/posters/kp_small/301.jpg"))
        XCTAssertEqual(ZonaIndex.posterFallbacks(for: kp).map(\.absoluteString), ["https://img2.zonapic.com/images/film_240/0/301.jpg"])
        let big = try XCTUnwrap(URL(string: "https://kinopoiskapiunofficial.tech/images/posters/kp/409424.jpg"))
        XCTAssertEqual(ZonaIndex.posterFallbacks(for: big).map(\.absoluteString), [
            "https://img2.zonapic.com/images/film_big/409/409424.jpg",
            "https://img2.zonapic.com/images/film_240/409/409424.jpg"
        ])
        let other = try XCTUnwrap(URL(string: "https://avatars.mds.yandex.net/get-kinopoisk-image/1.jpg"))
        XCTAssertTrue(ZonaIndex.posterFallbacks(for: other).isEmpty)
        let actor = try XCTUnwrap(URL(string: "https://kinopoiskapiunofficial.tech/images/actor_posters/kp/7836.jpg"))
        XCTAssertTrue(ZonaIndex.posterFallbacks(for: actor).isEmpty)
    }

    func testReleaseQueryUsesOnlySearchableFields() throws {
        let url = try XCTUnwrap(ZonaIndex.releasesURL(kinopoiskId: 301))
        let text = try XCTUnwrap(url.absoluteString.removingPercentEncoding)
        XCTAssertTrue(text.contains("q=kinopoisk_id:301"))
        XCTAssertTrue(text.contains("fq=magnet:true AND playable:true AND trailer:false"))
        // Stored only: filtering on it finds nothing.
        XCTAssertFalse(text.contains("fq=magnet:true AND playable:true AND trailer:false AND advertisement"))
        XCTAssertTrue(text.contains("advertisement"))

        let json = """
        {"response":{"numFound":2,"docs":[
          {"torrent_download_link":"magnet:?xt=urn:btih:09ef390eb87db6a6df5384fae0aebbe619d9cd4b&dn=The.Matrix.1999.mkv","seeds":5,"advertisement":true},
          {"torrent_download_link":"magnet:?xt=urn:btih:19ef390eb87db6a6df5384fae0aebbe619d9cd4b&dn=The.Matrix.1999.1080p.mkv","seeds":3,"advertisement":false}
        ]}}
        """
        let page = try JSONDecoder().decode(ZonaPage<ZonaTorrent>.self, from: Data(json.utf8))
        XCTAssertEqual(page.docs.count, 2)
        let releases = ZonaReleases.build(from: page.docs)
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases.first?.seeders, 3)
    }

    func testOriginalOnlyReleasesComeLast() throws {
        let releases = ZonaReleases.build(from: try torrents().docs)
        let sorted = ReleaseRanking.sorted(releases, by: .seeders)
        let firstOriginal = try XCTUnwrap(sorted.firstIndex { $0.isOriginalOnly })
        XCTAssertFalse(sorted[firstOriginal...].contains { !$0.isOriginalOnly })
        XCTAssertFalse(sorted[0].isOriginalOnly)
    }

    func testPersonQuery() throws {
        let url = try XCTUnwrap(ZonaIndex.personURL(id: 415350))
        let text = try XCTUnwrap(url.absoluteString.removingPercentEncoding)
        XCTAssertTrue(text.contains("q=personId:415350"))
        XCTAssertTrue(text.contains("sort=year desc"))
        XCTAssertTrue(text.contains("persons"))
        XCTAssertNil(ZonaIndex.personURL(id: 0))
    }

    func testHostHealthMarksWearOff() {
        let health = HostHealth()
        let now = Date()
        XCTAssertFalse(health.isDown("kinopoiskapiunofficial.tech", now: now))
        XCTAssertTrue(health.markDown("KinopoiskApiUnofficial.tech", for: 600, reason: "нет ответа", now: now))
        XCTAssertFalse(health.markDown("kinopoiskapiunofficial.tech", for: 60, reason: "медленно", now: now))
        XCTAssertEqual(health.reason("kinopoiskapiunofficial.tech", now: now.addingTimeInterval(120)), "нет ответа")
        XCTAssertFalse(health.isDown("kinopoiskapiunofficial.tech", now: now.addingTimeInterval(601)))
        health.markDown("jac.red", for: 600, reason: "x", now: now)
        health.markUp("jac.red")
        XCTAssertFalse(health.isDown("jac.red", now: now))
        XCTAssertTrue(HostHealth.isHostFailure(URLError(.timedOut)))
        XCTAssertFalse(HostHealth.isHostFailure(URLError(.notConnectedToInternet)))
        XCTAssertFalse(HostHealth.isHostFailure(CancellationError()))
    }

    func testFirstSuccessfulTaskWins() async throws {
        let slow = Task<String, Error> {
            try await Task.sleep(nanoseconds: 400_000_000)
            return "kp"
        }
        let fast = Task<String, Error> {
            try await Task.sleep(nanoseconds: 20_000_000)
            return "zona"
        }
        let first = await TaskWait.firstSuccess([slow, fast])
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(try first.result.get(), "zona")

        let failing = Task<String, Error> { throw URLError(.timedOut) }
        let later = Task<String, Error> {
            try await Task.sleep(nanoseconds: 50_000_000)
            return "later"
        }
        let second = await TaskWait.firstSuccess([failing, later])
        XCTAssertEqual(try second.result.get(), "later")

        let none = await TaskWait.firstSuccess([
            Task<String, Error> { throw URLError(.timedOut) },
            Task<String, Error> { throw URLError(.cannotFindHost) }
        ])
        XCTAssertThrowsError(try none.result.get())
    }

    func testMergeKeepsTrackerTitleAndBothVoices() throws {
        let zona = ZonaReleases.build(from: try torrents().docs)
        var tracker = zona[1]
        tracker.title = "Матрица / The Matrix (1999) BDRip 1080p | D, A"
        tracker.trackers = ["rutracker"]
        tracker.seeders = 120
        tracker.voiceKinds = [.dub, .author]
        tracker.studios = ["Гаврилов"]
        tracker.audioTracks = []
        tracker.languages = nil
        tracker.knownStarts = nil
        var other = zona[0]
        other.id = "ffffffffffffffffffffffffffffffffffffffff"
        other.hash = other.id
        let merged = ReleaseMerge.merge(zona, [tracker, other])
        XCTAssertEqual(merged.count, zona.count + 1)
        let dune = merged[1]
        XCTAssertEqual(dune.title, "Матрица / The Matrix (1999) BDRip 1080p | D, A")
        XCTAssertEqual(dune.trackers, ["rutracker", "Zona"])
        XCTAssertEqual(dune.seeders, 120)
        XCTAssertEqual(dune.voiceKinds, [.dub, .author, .subtitles])
        XCTAssertEqual(dune.studios, ["Гаврилов"])
        XCTAssertEqual(dune.audioTracks, ["Русский", "Английский"])
        XCTAssertEqual(dune.languages, ["ru", "en"])
        XCTAssertEqual(dune.knownStarts, 5)
    }

    func testRankingPrefersRussianAudioAndWorkingTorrents() throws {
        let releases = ZonaReleases.build(from: try torrents().docs)
        // The English-only YIFY copy has ten times more seeders, the dubbed 1080p one still wins.
        let best = ReleaseRanking.best(Array(releases.prefix(2)), preferred: .fullHD)
        XCTAssertEqual(best?.hash, "aaaabbbbccccddddeeeeffff0000111122223333")

        var failing = releases[1]
        failing.knownStarts = 1
        failing.knownFailures = 9
        XCTAssertLessThan(ReleaseRanking.score(failing, preferred: .fullHD),
                          ReleaseRanking.score(releases[1], preferred: .fullHD))
    }

    func testQueryUsesZonaOnlyForTheFilm() {
        var query = TorrentSearchQuery(title: "Матрица", originalTitle: "The Matrix", year: 1999, isSeries: false, kinopoiskId: 301)
        XCTAssertEqual(query.zonaId, 301)
        query.custom = "matrix remux"
        XCTAssertNil(query.zonaId)
        XCTAssertNil(TorrentSearchQuery(title: "Матрица", originalTitle: nil, year: nil, isSeries: false).zonaId)
    }

    func testWaitingForATaskGivesUpWithoutCancellingIt() async throws {
        let slow = Task<Int, Error> {
            try await Task.sleep(nanoseconds: 300_000_000)
            return 7
        }
        let early = await TaskWait.result(of: slow, within: 0.05)
        XCTAssertNil(early)
        let late = await TaskWait.result(of: slow, within: 5)
        XCTAssertEqual(try late?.get(), 7)

        let failing = Task<Int, Error> { throw URLError(.timedOut) }
        let failure = await TaskWait.result(of: failing, within: 5)
        XCTAssertThrowsError(try failure?.get())
    }
}
