import XCTest
@testable import KinotekaCore

final class TorrentSearchTests: XCTestCase {
    private let jacredJSON = """
    {"Results":[
      {"Tracker":"korsars, kinozal, rutor","Details":"https://korsars.pro/t=1",
       "Title":"Дюна / Dune: Part One / 2021 / ДБ, ПМ, СТ / WEB-DL (1080p) | Дубляж","Size":11467562680,
       "PublishDate":"2021-10-22T18:49:00Z","Category":[2000],"CategoryDesc":"Movies","Seeders":18209,"Peers":1619,
       "ffprobe":[{"codec_type":"video","codec_name":"h264"},
                  {"codec_type":"audio","codec_name":"ac3","tags":{"language":"rus","title":"Dub [iTunes]"}},
                  {"codec_type":"audio","codec_name":"eac3","tags":{"language":"eng"}}],
       "MagnetUri":"magnet:?xt=urn:btih:DA70A96FBFA062FDA51A80308DD6A8BF3806DADE&dn=Dune",
       "info":{"name":"Дюна","originalname":"Dune: Part One","sizeName":"10.68 GB","relased":2021,"videotype":"sdr",
               "quality":1080,"voices":["Дубляж","HDRezka"],"seasons":[],"types":["movie"]}},
      {"Tracker":"rutracker","Title":"Дюна / Dune (Дэвид Линч / David Lynch) [1984, США, BDRip 720p] MVO","Size":8000000000,
       "Seeders":50,"Peers":3,"MagnetUri":"magnet:?xt=urn:btih:1111111111111111111111111111111111111111",
       "info":{"quality":720,"relased":1984,"types":["movie"]}},
      {"Tracker":"nnmclub","Title":"Дюна / Dune: Part One (2021) CAMRip | L","Size":1400000000,"Seeders":"12","Peers":null,
       "MagnetUri":"magnet:?xt=urn:btih:2222222222222222222222222222222222222222","info":{"relased":2021}},
      {"Tracker":"bitru","Title":"Дюна / Dune: Part One / 2021 / ДБ / WEB-DL (1080p)","Size":11467562680,"Seeders":900,
       "MagnetUri":"magnet:?xt=urn:btih:da70a96fbfa062fda51a80308dd6a8bf3806dade"},
      {"Tracker":"kinozal","Title":"Дюна / Dune: Part One / 2021 / ДБ / BDRemux (2160p) HDR","Size":80000000000,"Seeders":40,
       "MagnetUri":"magnet:?xt=urn:btih:3333333333333333333333333333333333333333","info":{"quality":2160,"videotype":"hdr"}},
      {"Tracker":"rutor","Title":"Совсем другой фильм (2021) 1080p","Size":1,"Seeders":5000,
       "MagnetUri":"magnet:?xt=urn:btih:4444444444444444444444444444444444444444"},
      {"Tracker":"rutor","Title":"Дюна / Dune: Part One (2021) WEB-DL 720p | D","Size":4900000000,"Seeders":0,
       "MagnetUri":"magnet:?xt=urn:btih:5555555555555555555555555555555555555555"},
      {"Title":"","MagnetUri":"magnet:?xt=urn:btih:6666666666666666666666666666666666666666"},
      "broken element"
    ],"jacred":true}
    """

    private var filter: ReleaseFilter {
        ReleaseFilter(title: "Дюна", originalTitle: "Dune: Part One", year: 2021, isSeries: false, strict: true)
    }

    private func decode(_ json: String) throws -> JackettSearchResponse {
        try JSONDecoder().decode(JackettSearchResponse.self, from: Data(json.utf8))
    }

    func testDecodesJacredResponseLeniently() throws {
        let response = try decode(jacredJSON)
        XCTAssertTrue(response.isJacred)
        XCTAssertEqual(response.items.count, 8)
        let first = response.items[0]
        XCTAssertEqual(first.seeders, 18209)
        XCTAssertEqual(first.info.quality, 1080)
        XCTAssertEqual(first.info.voices, ["Дубляж", "HDRezka"])
        XCTAssertEqual(first.audioTracks, ["Dub [iTunes]", "Английский"])
        XCTAssertEqual(response.items[2].seeders, 12)
        XCTAssertEqual(response.items[2].peers, 0)
    }

    func testBuildFiltersMergesAndParses() throws {
        let releases = ReleaseBuilder.build(from: try decode(jacredJSON), filter: filter)
        // 1984 film, the unrelated title and the empty title are dropped; two copies of one hash merge.
        XCTAssertEqual(releases.count, 4)
        let dune = releases[0]
        XCTAssertEqual(dune.id, "da70a96fbfa062fda51a80308dd6a8bf3806dade")
        XCTAssertEqual(dune.trackers, ["korsars", "kinozal", "rutor", "bitru"])
        XCTAssertEqual(dune.seeders, 18209)
        XCTAssertEqual(dune.quality, .fullHD)
        XCTAssertEqual(dune.voiceKinds, [.dub, .multi, .subtitles])
        XCTAssertEqual(dune.studios, ["HDRezka"])
        XCTAssertEqual(dune.year, 2021)
        XCTAssertEqual(dune.isSeries, false)
        XCTAssertNotNil(dune.published)
        XCTAssertTrue(dune.summary.hasPrefix("1080p · "))
        XCTAssertTrue(releases.contains { $0.isCamRip })
        XCTAssertTrue(releases.contains { $0.quality == .uhd && $0.isHDR })
    }

    func testCustomQueryKeepsEverythingWithTitle() throws {
        let custom = ReleaseFilter(title: "Дюна", originalTitle: nil, year: 2021, isSeries: false, strict: false)
        XCTAssertEqual(ReleaseBuilder.build(from: try decode(jacredJSON), filter: custom).count, 6)
    }

    func testBestReleasePrefersQualitySeedsAndDub() throws {
        let releases = ReleaseBuilder.build(from: try decode(jacredJSON), filter: filter)
        XCTAssertEqual(ReleaseRanking.best(releases, preferred: .fullHD)?.id, "da70a96fbfa062fda51a80308dd6a8bf3806dade")
        XCTAssertEqual(ReleaseRanking.best(releases, preferred: .uhd)?.quality, .uhd)
        // A camera copy never wins over a normal release, and releases without seeders are skipped.
        let cam = releases.first { $0.isCamRip }!
        var better = releases.first { $0.seeders == 0 }!
        better.seeders = 1
        XCTAssertGreaterThan(ReleaseRanking.score(better, preferred: .fullHD), ReleaseRanking.score(cam, preferred: .fullHD))
        XCTAssertNil(ReleaseRanking.best(releases.filter { $0.seeders == 0 }, preferred: .fullHD))
    }

    func testHugeRemuxLosesToStreamableRelease() {
        func release(_ id: String, _ quality: ReleaseQuality, gigabytes: Double, seeders: Int) -> TorrentRelease {
            TorrentRelease(id: id, title: id, link: "magnet:?xt=urn:btih:\(id)", hash: id, size: Int64(gigabytes * 1_073_741_824),
                           seeders: seeders, peers: 0, trackers: [], published: nil, quality: quality, isHDR: false,
                           isCamRip: false, seasons: [], voiceKinds: [.dub], studios: [], audioTracks: [],
                           year: nil, isSeries: false, detailsURL: nil)
        }
        let uhd = [release("remux", .uhd, gigabytes: 90, seeders: 212), release("bdrip", .uhd, gigabytes: 28.8, seeders: 113)]
        XCTAssertEqual(ReleaseRanking.best(uhd, quality: .uhd)?.id, "bdrip")
        // A preferred 4K still wins over 1080p even when it is big.
        let mixed = [release("remux", .uhd, gigabytes: 80, seeders: 40), release("web", .fullHD, gigabytes: 11, seeders: 18_000)]
        XCTAssertEqual(ReleaseRanking.best(mixed, preferred: .uhd)?.id, "remux")
        XCTAssertEqual(ReleaseRanking.best(mixed, preferred: .fullHD)?.id, "web")
    }

    func testSeasonAwareBest() {
        func release(_ id: String, seasons: [Int], seeders: Int) -> TorrentRelease {
            TorrentRelease(id: id, title: id, link: "magnet:?xt=urn:btih:\(id)", hash: id, size: 20_000_000_000,
                           seeders: seeders, peers: 0, trackers: [], published: nil, quality: .fullHD, isHDR: false,
                           isCamRip: false, seasons: seasons, voiceKinds: [.multi], studios: [], audioTracks: [],
                           year: nil, isSeries: true, detailsURL: nil)
        }
        let list = [release("a", seasons: [1], seeders: 300), release("b", seasons: [2], seeders: 100), release("c", seasons: [1, 2, 3], seeders: 150)]
        XCTAssertEqual(ReleaseRanking.best(list, preferred: .fullHD, season: 2)?.id, "b")
        XCTAssertEqual(ReleaseRanking.best(list, preferred: .fullHD, season: 3)?.id, "c")
        XCTAssertEqual(ReleaseRanking.best(list, preferred: .fullHD, season: 1)?.id, "a")
        XCTAssertEqual(ReleaseRanking.sorted(list, by: .seeders).map { $0.id }, ["a", "c", "b"])
    }

    func testQualityChoices() throws {
        let releases = ReleaseBuilder.build(from: try decode(jacredJSON), filter: filter)
        // 720p exists only without seeders and SD only as a camera copy, so they are not offered.
        XCTAssertEqual(ReleaseRanking.qualities(releases), [.uhd, .fullHD])
        XCTAssertEqual(ReleaseRanking.best(releases, quality: .uhd)?.id, "3333333333333333333333333333333333333333")
        XCTAssertEqual(ReleaseRanking.best(releases, quality: .fullHD)?.id, "da70a96fbfa062fda51a80308dd6a8bf3806dade")
        XCTAssertNil(ReleaseRanking.best(releases, quality: .hd))
        XCTAssertNil(ReleaseRanking.best(releases, quality: .sd))
        XCTAssertEqual(ReleaseRanking.perQuality(releases).map { $0.quality }, [.uhd, .fullHD])
        // The release that plays now stays in the menu for its quality.
        var other = releases.first { $0.quality == .fullHD }!
        other.id = "other"
        other.seeders = 1
        XCTAssertEqual(ReleaseRanking.perQuality(releases + [other], current: other).map { $0.id }[1], "other")
    }

    func testQualityChoicesForSeason() {
        func release(_ id: String, _ quality: ReleaseQuality, seasons: [Int]) -> TorrentRelease {
            TorrentRelease(id: id, title: id, link: "magnet:?xt=urn:btih:\(id)", hash: id, size: 1, seeders: 10, peers: 0,
                           trackers: [], published: nil, quality: quality, isHDR: false, isCamRip: false, seasons: seasons,
                           voiceKinds: [], studios: [], audioTracks: [], year: nil, isSeries: true, detailsURL: nil)
        }
        let list = [release("a", .uhd, seasons: [1]), release("b", .fullHD, seasons: [2]), release("c", .hd, seasons: [])]
        XCTAssertEqual(ReleaseRanking.qualities(list, season: 2), [.fullHD, .hd])
        XCTAssertEqual(ReleaseRanking.matching(list, season: 1).map { $0.id }, ["a", "c"])
        XCTAssertEqual(ReleaseRanking.qualities(list), [.uhd, .fullHD, .hd])
        XCTAssertNil(ReleaseRanking.best(list, quality: .uhd, season: 2))
    }

    func testReleaseRoundTrip() throws {
        let releases = ReleaseBuilder.build(from: try decode(jacredJSON), filter: filter)
        let data = try JSONEncoder().encode(releases)
        XCTAssertEqual(try JSONDecoder().decode([TorrentRelease].self, from: data), releases)
    }

    func testDecodesPlainArraysAndJackettLinks() throws {
        let json = """
        [{"tracker":"rutor","title":"Film (2020) 1080p","size":100,"sid":7,"pir":1,"magnet":"magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01","quality":1080,"seasons":[]},
         {"Title":"Film 2020 720p","Tracker":"Private","Size":5,"Seeders":3,"Link":"http://jackett:9117/dl/private/?jackett_apikey=k&path=x&file=Film"}]
        """
        let response = try decode(json)
        XCTAssertFalse(response.isJacred)
        let releases = ReleaseBuilder.build(from: response, filter: nil)
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases[0].seeders, 7)
        XCTAssertEqual(releases[0].hash, "abcdef0123456789abcdef0123456789abcdef01")
        XCTAssertNil(releases[1].hash)
        let marked = LinkInspector.markTorrent(releases[1].link)
        XCTAssertEqual(LinkInspector.kind(of: marked), .torrent)
        XCTAssertEqual(LinkInspector.stripMarker(marked), releases[1].link)
        XCTAssertEqual(LinkInspector.markTorrent("magnet:?xt=urn:btih:ABC"), "magnet:?xt=urn:btih:ABC")
    }

    func testRejectsNonResultObjects() {
        XCTAssertThrowsError(try decode("{\"error\":\"bad key\"}"))
    }

    func testQueryURL() throws {
        let query = TorrentSearchQuery(title: "Форсаж+", originalTitle: "Fast & Furious", year: 2009, isSeries: false)
        let url = try XCTUnwrap(query.url(server: "jac.red/", apiKey: ""))
        let text = url.absoluteString
        XCTAssertTrue(text.hasPrefix("https://jac.red/api/v2.0/indexers/all/results?apikey=&Query="))
        XCTAssertTrue(text.contains("%2B"))
        XCTAssertTrue(text.contains("title_original=Fast%20%26%20Furious"))
        XCTAssertTrue(text.contains("year=2009"))
        XCTAssertTrue(text.contains("is_serial=1"))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(comps.queryItems?.first { $0.name == "Query" }?.value, "Форсаж+")

        let custom = TorrentSearchQuery(title: "Дюна", originalTitle: "Dune", year: 2021, isSeries: true, custom: "dune 2021 remux")
        let customURL = try XCTUnwrap(custom.url(server: "http://192.168.1.10:9117", apiKey: "KEY"))
        XCTAssertTrue(customURL.absoluteString.hasPrefix("http://192.168.1.10:9117/api/v2.0/indexers/all/results?apikey=KEY"))
        XCTAssertFalse(customURL.absoluteString.contains("title="))
        XCTAssertTrue(customURL.absoluteString.contains("is_serial=2"))

        XCTAssertEqual(TorrentSearchQuery.normalizedServer("https://jac.red/api/v2.0/indexers/all/results"), "https://jac.red")
        XCTAssertNil(TorrentSearchQuery.normalizedServer("   "))
        let original = try XCTUnwrap(query.url(server: "https://jac.red", apiKey: "", useOriginalTitle: true))
        XCTAssertEqual(URLComponents(url: original, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Query" }?.value, "Fast & Furious")
    }

    func testInfoHash() {
        XCTAssertEqual(LinkInspector.infoHash(of: "magnet:?xt=urn:btih:DA70A96FBFA062FDA51A80308DD6A8BF3806DADE&dn=x"), "da70a96fbfa062fda51a80308dd6a8bf3806dade")
        XCTAssertEqual(LinkInspector.infoHash(of: "DA70A96FBFA062FDA51A80308DD6A8BF3806DADE"), "da70a96fbfa062fda51a80308dd6a8bf3806dade")
        XCTAssertNil(LinkInspector.infoHash(of: "https://example.com/video.mp4"))
    }
}
