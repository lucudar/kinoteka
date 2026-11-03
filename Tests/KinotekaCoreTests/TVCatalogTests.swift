import XCTest
@testable import KinotekaCore

final class TVCatalogTests: XCTestCase {
    func testCatalogIsConsistent() {
        let all = TVCatalog.all
        XCTAssertEqual(all.count, 44)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids must be unique")
        for channel in all {
            XCTAssertFalse(channel.name.isEmpty)
            XCTAssertFalse(channel.groups.isEmpty, channel.id)
            XCTAssertFalse(channel.sources.isEmpty, channel.id)
            if channel.guide != nil { XCTAssertNotNil(channel.guideURL, channel.id) }
            for source in channel.sources {
                switch source {
                case .stream(let link), .playlistAPI(let link):
                    let scheme = URL(string: link)?.scheme
                    XCTAssertTrue(scheme == "https" || scheme == "http", link)
                case .vitrina(let vitrina):
                    XCTAssertNotNil(vitrina.playerURL, channel.id)
                    XCTAssertNotNil(vitrina.fallbackBalancerURL, channel.id)
                    XCTAssertFalse(vitrina.egress.isEmpty, channel.id)
                }
            }
        }
        for group in TVGroup.allCases {
            XCTAssertFalse(TVCatalog.channels(in: group).isEmpty, group.title)
        }
        // The sections follow the order of the groups.
        let order = all.map { TVGroup.allCases.firstIndex(of: $0.primaryGroup) ?? 0 }
        XCTAssertEqual(order, order.sorted())
    }

    func testLinks() {
        let first = TVCatalog.channel(forLink: "tv:1tvch")
        XCTAssertEqual(first?.name, "Первый канал")
        XCTAssertNil(TVCatalog.channel(forLink: "tv:unknown"))
        XCTAssertNil(TVCatalog.channel(forLink: "https://example.com/tv:1tvch"))

        let channel = TVCatalog.byID["ntv"]!.channel
        XCTAssertEqual(channel.url, "tv:ntv")
        XCTAssertEqual(channel.assetName, "tv-ntv")
        XCTAssertTrue(channel.isBuiltIn)
        XCTAssertEqual(channel.group, "Эфирные")

        // A channel saved by an older version gets the current name and logo.
        let saved = Channel(name: "NTV", url: "tv:ntv", logo: nil, group: nil)
        XCTAssertEqual(saved.refreshed, channel)
        let own = Channel(name: "Мой канал", url: "https://example.com/live.m3u8", logo: "https://example.com/logo.png", group: "Кино")
        XCTAssertEqual(own.refreshed, own)
        XCTAssertFalse(own.isBuiltIn)
        XCTAssertNil(own.assetName)
        XCTAssertEqual(own.initials, "МК")
    }

    func testSearch() {
        let ids = { (query: String) in Set(TVCatalog.search(query).map(\.id)) }
        XCTAssertTrue(ids("первый").contains("1tvch"))
        XCTAssertTrue(ids("Россия").isSuperset(of: ["russia1", "kultura", "russia24"]))
        XCTAssertTrue(ids("стс").isSuperset(of: ["ctc", "ctclove"]))
        XCTAssertTrue(ids("муз-тв").contains("muztv"))
        XCTAssertTrue(ids("ЗВЁЗДА").contains("tvzvezda"))
        XCTAssertTrue(TVCatalog.search("   ").isEmpty)
    }

    func testBalancerFromPlayerPage() {
        let page = """
        <script>var config = {"streams_api_url": "https://media.mediavitrina.ru/balancer/vod/{{PROGRAMME_ID}}/streams.json?application_id={{APPLICATION_ID}}",
        "api": "https://media.mediavitrina.ru/balancer/v3/iz/iz/streams.json?application_id={{APPLICATION_ID}}&player_referer_hostname={{PLAYER_REFERER_HOSTNAME}}&config_checksum_sha256={{CONFIG_CHECKSUM_SHA256}}&egress_version_id=17543499&"};</script>
        """
        let url = TVParsing.balancerURL(inPlayerPage: page, fallbackEgress: "1")
        XCTAssertNotNil(url)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url?.path, "/balancer/v3/iz/iz/streams.json")
        XCTAssertEqual(items.first { $0.name == "player_referer_hostname" }?.value, "vitrina.tv")
        XCTAssertEqual(items.first { $0.name == "egress_version_id" }?.value, "17543499")
        XCTAssertEqual(items.first { $0.name == "application_id" }?.value, "")
        XCTAssertFalse(url!.absoluteString.contains("{{"))
        XCTAssertFalse(url!.absoluteString.contains("%7B"))

        // Escaped slashes of a JSON string; no egress on the page: the one of the catalog.
        let escaped = #"{"url":"https:\/\/media.mediavitrina.ru\/balancer\/v3\/tv5\/5tv\/streams.json?player_referer_hostname={{PLAYER_REFERER_HOSTNAME}}\u0026egress_version_id={{EGRESS}}"}"#
        let second = TVParsing.balancerURL(inPlayerPage: escaped, fallbackEgress: "17543505")
        let secondItems = second.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        XCTAssertEqual(second?.path, "/balancer/v3/tv5/5tv/streams.json")
        XCTAssertEqual(secondItems.first { $0.name == "egress_version_id" }?.value, "17543505")

        XCTAssertNil(TVParsing.balancerURL(inPlayerPage: "<html>no player</html>"))
    }

    func testPlayerPagesInConfig() {
        let config = """
        {"result":{"channels":[
          {"channel_slug":"1tvch","web_player_url":"https://player.mediavitrina.ru/1tvch/1tvch/vitrinatv_web/659fab1a9893b/player.html"},
          {"channel_slug":"iz","web_player_url":"https://player.mediavitrina.ru/iz/vitrinatv_web/player.html"},
          {"channel_slug":"broken"}
        ]}}
        """
        let pages = TVParsing.playerPages(inConfig: Data(config.utf8))
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages["iz"]?.absoluteString, "https://player.mediavitrina.ru/iz/vitrinatv_web/player.html")
    }

    func testStreamAnswer() {
        let geo = """
        {"country":"US","geo":"US-VA","hls":["https://edge02r.mediavitrina.ru/hls-vod/streams/georestrictions/nmg_tv-5_16x9_v1/index.m3u8?token=x"],"mpd":[]}
        """
        let answer = TVParsing.streamAnswer(Data(geo.utf8))
        XCTAssertEqual(answer?.country, "US")
        XCTAssertEqual(answer?.hls.count, 1)
        XCTAssertTrue(TVParsing.isGeoStub(answer!.hls[0]))

        let live = #"{"country":"RU","hls":["https://edge03p.mediavitrina.ru/hls-livef8/izvestia/index.m3u8?token=v2.a"]}"#
        let liveAnswer = TVParsing.streamAnswer(Data(live.utf8))
        XCTAssertFalse(TVParsing.isGeoStub(liveAnswer!.hls[0]))

        XCTAssertNil(TVParsing.streamAnswer(Data(#"{"hls":[]}"#.utf8)))
        XCTAssertNil(TVParsing.streamAnswer(Data("not json".utf8)))
    }

    func testProgrammes() {
        let json = """
        {"title":"Первый канал","programmes":[
          {"title":"Время. 16+","begin_ts":1793667600,"end_ts":1793669400},
          {"title":"ПОДКАСТ.ЛАБ «Собрались с мыслями». 16+","begin_ts":1793661600,"end_ts":1793664000},
          {"title":"Без конца","begin_ts":1793670000,"end_ts":1793660000}
        ]}
        """
        let list = TVParsing.programmes(Data(json.utf8))
        XCTAssertEqual(list.map(\.title), ["ПОДКАСТ.ЛАБ «Собрались с мыслями»", "Время"])
        let programme = list[1]
        XCTAssertEqual(programme.progress(at: Date(timeIntervalSince1970: 1793668500)), 0.5, accuracy: 0.001)
        XCTAssertEqual(programme.progress(at: Date(timeIntervalSince1970: 1793600000)), 0)
        XCTAssertEqual(programme.progress(at: Date(timeIntervalSince1970: 1793700000)), 1)
    }

    func testProgrammeTitle() {
        XCTAssertEqual(TVParsing.programmeTitle("Новости (16+)"), "Новости")
        XCTAssertEqual(TVParsing.programmeTitle("Время 0+"), "Время")
        XCTAssertEqual(TVParsing.programmeTitle("Т/с «Склиф». 12+."), "Т/с «Склиф»")
        XCTAssertEqual(TVParsing.programmeTitle("Ну, погоди!..."), "Ну, погоди!...")
        XCTAssertEqual(TVParsing.programmeTitle("  Футбол.  Лига   чемпионов  "), "Футбол. Лига чемпионов")
    }

    func testLooksLikeStream() {
        XCTAssertTrue(TVParsing.looksLikeStream(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)))
        XCTAssertTrue(TVParsing.looksLikeStream(Data("\u{FEFF}#EXTM3U\n".utf8)))
        XCTAssertTrue(TVParsing.looksLikeStream(Data("<?xml version=\"1.0\"?>\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">".utf8)))
        XCTAssertFalse(TVParsing.looksLikeStream(Data("<html><body>403 Forbidden</body></html>".utf8)))
        XCTAssertFalse(TVParsing.looksLikeStream(Data()))
    }

    func testGunzip() throws {
        let plain = Data("{\"hls\":[]}".utf8)
        XCTAssertEqual(TVParsing.gunzipIfNeeded(plain), plain)
        #if canImport(Darwin)
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/6tWysgpVrKKVsooKSkottLXT9RLrUjMLchJ1U/SyzUutVCK1VFKzi/NKymqVLJSCgpVqgUADY5JDzMAAAA=")!
        let answer = TVParsing.streamAnswer(compressed)
        XCTAssertEqual(answer?.hls, ["https://a.example/b.m3u8"])
        XCTAssertEqual(answer?.country, "RU")
        // gzip of the command line keeps the file name in the header.
        let named = Data(base64Encoded: "H4sICKFo6moAA2d1aWRlLmpzb24Aq1YqKMpPL0rMzU0tVrKKjq0FAMKSFL8RAAAA")!
        XCTAssertEqual(String(decoding: TVParsing.gunzipIfNeeded(named), as: UTF8.self), "{\"programmes\":[]}")
        #endif
    }
}
