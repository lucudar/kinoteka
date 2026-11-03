import Foundation

// MARK: - Built-in TV channels
//
// Free official streams of Russian channels: «Витрина ТВ» (the player the broadcasters use on
// their sites and on vitrina.tv) and the direct links of the broadcasters (smotrim.ru, their CDNs,
// their Rutube broadcasts). A channel keeps several sources; the player takes the first that
// works. «Витрина ТВ» shows the federal channels only to viewers in Russia.

/// The sections of the «ТВ-каналы» screen, in their order.
enum TVGroup: String, CaseIterable, Codable, Hashable, Sendable {
    case federal, news, entertainment, movies, kids, music, knowledge, cities

    var title: String {
        switch self {
        case .federal: return "Эфирные"
        case .news: return "Новости"
        case .entertainment: return "Развлечения"
        case .movies: return "Кино и сериалы"
        case .kids: return "Детям"
        case .music: return "Музыка"
        case .knowledge: return "Познавательные"
        case .cities: return "Города"
        }
    }
}

/// A channel of «Витрина ТВ».
struct VitrinaChannel: Hashable, Sendable {
    /// `channel_slug` in the config of vitrina.tv: the new player page is found by it when the
    /// path below stops working.
    let slug: String
    /// The player page: https://player.mediavitrina.ru/<player>/player.html. It holds the
    /// current link of the balancer that gives the stream.
    let player: String
    /// The balancer for the case the player page can not be read:
    /// https://media.mediavitrina.ru/balancer/v3/<balancer>/streams.json
    let balancer: String
    /// `egress_version_id` of the balancer link (without it the balancer answers 409).
    let egress: String

    var playerURL: URL? {
        URL(string: "https://player.mediavitrina.ru/\(player)/player.html")
    }

    var fallbackBalancerURL: URL? {
        URL(string: "https://media.mediavitrina.ru/balancer/v3/\(balancer)/streams.json?application_id=&player_referer_hostname=vitrina.tv&config_checksum_sha256=&egress_version_id=\(egress)")
    }
}

enum TVSource: Hashable, Sendable {
    case vitrina(VitrinaChannel)
    /// A JSON answer with the links of the stream: {"hls": ["…"]} (Первый канал).
    case playlistAPI(String)
    /// A direct HLS link of the broadcaster.
    case stream(String)
}

struct TVChannel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// The first group is the section of the channel; the others are chips that show it too.
    let groups: [TVGroup]
    /// The path of the programme guide of «Витрина ТВ».
    let guide: String?
    /// Other names for the search.
    let keywords: [String]
    /// In the order of preference.
    let sources: [TVSource]

    var primaryGroup: TVGroup { groups.first ?? .federal }

    /// The logo in the asset catalog of the app (Config/channels, unpacked by the build).
    var logoName: String { "tv-" + id }

    /// The link stored in favourites and recent channels.
    var link: String { TVCatalog.scheme + id }

    var guideURL: URL? {
        guard let guide = guide else { return nil }
        return URL(string: "https://static-api.mediavitrina.ru/v1/epg/\(guide)/lite_broadcast_day_web.json")
    }

    /// The channel as the screens and the library keep it.
    var channel: Channel {
        Channel(name: name, url: link, logo: TVCatalog.assetPrefix + logoName, group: primaryGroup.title)
    }

    /// The name and the other names, normalized for the search.
    var searchText: String {
        TextMatch.normalized(([name, id] + keywords).joined(separator: " "))
    }
}

enum TVCatalog {
    static let scheme = "tv:"
    /// The logo of a built-in channel is a picture of the app, not a link: "asset:tv-1tvch".
    static let assetPrefix = "asset:"
    /// Every channel of vitrina.tv with its current player page.
    static let vitrinaConfigURL = URL(string: "https://static-api.mediavitrina.ru/v1/vitrinatv_app/web/3/config.json")!

    static func channel(forLink link: String) -> TVChannel? {
        let value = link.trimmed
        guard value.hasPrefix(scheme) else { return nil }
        return byID[String(value.dropFirst(scheme.count))]
    }

    static func channels(in group: TVGroup) -> [TVChannel] {
        all.filter { $0.groups.contains(group) }
    }

    static func search(_ query: String) -> [TVChannel] {
        let q = TextMatch.normalized(query)
        guard !q.isEmpty else { return [] }
        return all.filter { $0.searchText.contains(q) }
    }

    static let byID: [String: TVChannel] = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    private static func vitrina(_ slug: String, _ player: String, _ balancer: String, _ egress: String) -> TVSource {
        .vitrina(VitrinaChannel(slug: slug, player: player, balancer: balancer, egress: egress))
    }

    private static func smotrim(_ path: String) -> TVSource {
        .stream("https://stream.smotrim.ru/" + path)
    }

    private static func rutube(_ path: String) -> TVSource {
        .stream("https://bl.rutube.ru/livestream/" + path)
    }

    /// In the order of the screen: the sections by the first group of a channel.
    static let all: [TVChannel] = [federal, news, entertainment, movies, kids, music, knowledge, cities].flatMap { $0 }

    // Эфирные
    private static let federal: [TVChannel] = [
        TVChannel(id: "1tvch", name: "Первый канал", groups: [.federal], guide: "1tvch",
                  keywords: ["первый", "1 канал", "1tv"], sources: [
                    vitrina("1tvch", "1tvch/1tvch/vitrinatv_web/659fab1a9893b", "1tv/1tvch", "17543541"),
                    .playlistAPI("https://stream.1tv.ru/api/playlist/1tvch_as_array.json"),
                  ]),
        TVChannel(id: "russia1", name: "Россия 1", groups: [.federal], guide: "russia1/a5cdd4aa0048b187f7182f1b9ce7a6a7",
                  keywords: ["ртр", "россия"], sources: [
                    vitrina("russia1", "russia1/vitrinatv_web", "russia1/russia1", "17547567"),
                    smotrim("hls2/russia_hd/playlist_6.m3u8"),
                  ]),
        TVChannel(id: "matchtv", name: "Матч ТВ", groups: [.federal], guide: "matchtv",
                  keywords: ["матч", "спорт"], sources: [
                    vitrina("matchtv", "gpm_matchtv_v2/matchtv/vitrinatv_web", "matchtv/gpm_matchtv", "17543527"),
                  ]),
        TVChannel(id: "ntv", name: "НТВ", groups: [.federal], guide: "ntv_msk", keywords: [], sources: [
                    vitrina("ntv", "ntv_v2/ntv/vitrinatv_web", "ntv/ntv_msk", "17543535"),
                    rutube("c37cd74192c6bc3d6cd6077c0c4fd686/index.m3u8?e=2077050299&s=HSWg81JrQ3OqmwuWkEIDAQ&scheme=https"),
                  ]),
        TVChannel(id: "5tv", name: "Пятый канал", groups: [.federal], guide: "5tv",
                  keywords: ["5 канал", "пятый"], sources: [
                    vitrina("5tv", "5tv/vitrinatv_web", "tv5/5tv", "17543505"),
                  ]),
        TVChannel(id: "kultura", name: "Россия К", groups: [.federal, .knowledge], guide: "kultura",
                  keywords: ["культура", "россия культура"], sources: [
                    vitrina("kultura", "kultura/vitrinatv_web", "kultura/russiak", "17543501"),
                    smotrim("hls2/russia_k/playlist_5.m3u8"),
                  ]),
        TVChannel(id: "russia24", name: "Россия 24", groups: [.federal, .news], guide: "russia24",
                  keywords: ["вести", "новости"], sources: [
                    vitrina("russia24", "russia24/vitrinatv_web", "russia24/russia24", "17552453"),
                    smotrim("hls2/russia24_hd/playlist_5.m3u8"),
                  ]),
        TVChannel(id: "carusel", name: "Карусель", groups: [.federal, .kids], guide: "carusel",
                  keywords: ["мультфильмы", "детский"], sources: [
                    vitrina("carusel", "karusel/carusel/vitrinatv_web/675fd5fb41be3", "karusel/karusel", "17543545"),
                  ]),
        TVChannel(id: "otr", name: "ОТР", groups: [.federal], guide: "otr",
                  keywords: ["общественное телевидение"], sources: [
                    vitrina("otr", "otr_v2/otr/vitrinatv_web/66e19a6096580", "default_2026/otr", "17543543"),
                    .stream("https://live-otronline.cdnvideo.ru/otr-decklink/otr_ru_720p/playlist.m3u8"),
                  ]),
        TVChannel(id: "tvc", name: "ТВ Центр", groups: [.federal], guide: "tvc",
                  keywords: ["твц", "тв центр"], sources: [
                    vitrina("tvc", "tvc/tvc/vitrinatv_web", "default_2026/tvc", "17543521"),
                  ]),
        TVChannel(id: "rentv", name: "РЕН ТВ", groups: [.federal], guide: "rentv", keywords: ["рен"], sources: [
                    vitrina("rentv", "rentv/vitrinatv_web", "nmg/rentv", "17543507"),
                  ]),
        TVChannel(id: "spas", name: "Спас", groups: [.federal], guide: "spas/2e65f2f2fdaf6c699b223c61b1b5ab89",
                  keywords: [], sources: [
                    vitrina("spas", "spas/vitrinatv_web", "default_2026/spas", "17557927"),
                    .stream("https://tvspas.mediacdn.ru/cdn/spas/playlist.m3u8"),
                  ]),
        TVChannel(id: "ctc", name: "СТС", groups: [.federal], guide: "ctc_ext", keywords: ["ctc"], sources: [
                    vitrina("ctc", "ctc_ext/vitrinatv_web", "ctc/ctc", "17543517"),
                  ]),
        TVChannel(id: "dom", name: "Домашний", groups: [.federal], guide: "domashniy_ext", keywords: [], sources: [
                    vitrina("dom", "domashniy_ext/vitrinatv_web", "dom/domashniy", "17543497"),
                  ]),
        TVChannel(id: "tv3", name: "ТВ-3", groups: [.federal], guide: "tv3/832635d692f57778f906e5563b757187",
                  keywords: ["тв3", "тв 3"], sources: [
                    vitrina("tv3", "tv3_v2/tv3/vitrinatv_web", "tv3/gpm_tv3", "17543531"),
                  ]),
        TVChannel(id: "friday", name: "Пятница!", groups: [.federal], guide: "friday", keywords: [], sources: [
                    vitrina("friday", "gpm_friday_v2/friday/vitrinatv_web", "gpm_friday/gpm_friday", "17543529"),
                  ]),
        TVChannel(id: "tvzvezda", name: "Звезда", groups: [.federal], guide: "tvzvezda", keywords: [], sources: [
                    vitrina("tvzvezda", "zvezda/tvzvezda/vitrinatv_web", "default_2026/zvezda", "17543523"),
                    .stream("https://tvzvezda.bonus-tv.ru/cdn/tvzvezda/playlist.m3u8"),
                  ]),
        TVChannel(id: "mir", name: "Мир", groups: [.federal], guide: "mir", keywords: [], sources: [
                    vitrina("mir", "mir/mir/vitrinatv_web", "default_2026/mir", "17543503"),
                    .stream("http://hls.mirtv.cdnvideo.ru/mirtv-parampublish/mirtv_2500/playlist.m3u8"),
                  ]),
        TVChannel(id: "tnt", name: "ТНТ", groups: [.federal], guide: "tnt", keywords: ["tnt"], sources: [
                    vitrina("tnt", "gpm_tnt_v2/tnt/vitrinatv_web", "tnt/gpm_tnt", "17543533"),
                  ]),
        TVChannel(id: "muztv", name: "Муз-ТВ", groups: [.federal, .music], guide: "muztv",
                  keywords: ["муз", "музыка"], sources: [
                    vitrina("muztv", "muztv/muztv/vitrinatv_web", "muztv/muztv", "17543525"),
                  ]),
    ]

    // Новости
    private static let news: [TVChannel] = [
        TVChannel(id: "iz", name: "Известия", groups: [.news], guide: "iz", keywords: ["iz"], sources: [
                    vitrina("iz", "iz/vitrinatv_web", "iz/iz", "17543499"),
                    .stream("https://igi-hls.cdnvideo.ru/igi/igi_tcode/playlist.m3u8"),
                  ]),
        TVChannel(id: "mir24", name: "Мир 24", groups: [.news], guide: nil, keywords: [], sources: [
                    .stream("http://hls.mirtv.cdnvideo.ru/mirtv-parampublish/mir24_2500/playlist.m3u8"),
                  ]),
        TVChannel(id: "moskva24", name: "Москва 24", groups: [.news, .cities], guide: nil, keywords: ["москва"], sources: [
                    smotrim("hls/givc8/playlist.m3u8?entity=channel&id=798&sign=37881ef2e289f062ceff0dca6c24dc58"),
                  ]),
        TVChannel(id: "tv360", name: "360°", groups: [.news], guide: nil, keywords: ["360", "подмосковье"], sources: [
                    .stream("https://cdn-evacoder-tv.facecast.io/evacoder_hls_hi/CkxfR1xNUAJwTgtXTBZTAJli/index.m3u8"),
                  ]),
        TVChannel(id: "euronews", name: "Euronews", groups: [.news], guide: nil, keywords: ["евроньюс"], sources: [
                    .stream("https://cdn-euronews.akamaized.net/live/eds/euronews-ru/25071/index.m3u8"),
                  ]),
    ]

    // Развлечения
    private static let entertainment: [TVChannel] = [
        TVChannel(id: "che", name: "Че!", groups: [.entertainment], guide: "che_ext", keywords: ["перец"], sources: [
                    vitrina("che", "che_ext/vitrinatv_web", "che/che", "17543519"),
                  ]),
        TVChannel(id: "ctclove", name: "СТС Love", groups: [.entertainment], guide: "ctc_love_ext",
                  keywords: ["стс лав", "ctc love"], sources: [
                    vitrina("ctclove", "ctc_love_ext/vitrinatv_web", "ctclove/ctclove", "17543515"),
                  ]),
        TVChannel(id: "u", name: "Ю", groups: [.entertainment], guide: "u", keywords: ["ю тв"], sources: [
                    vitrina("u", "u_ott_v2/u/vitrinatv_web", "utv/u_ott", "17543537"),
                    rutube("5c9327074e25ca86f3111d4085cbbb65/index.m3u8?e=2066519758&s=9cPc1rCGu6M932eqrifRhQ&scheme=https"),
                  ]),
        TVChannel(id: "subbota", name: "Суббота!", groups: [.entertainment], guide: "subbota", keywords: [], sources: [
                    vitrina("subbota", "subbota/subbota/vitrinatv_web/67a5c79b91801", "subbota/subbota", "17543547"),
                    rutube("310744c10a5809da38aa445c952976da/index.m3u8?e=2066519758&s=dmUf6BUQzDBTwtQOseAfog&scheme=https"),
                  ]),
        TVChannel(id: "x2x2", name: "2x2", groups: [.entertainment], guide: nil, keywords: ["2х2", "мультфильмы"], sources: [
                    rutube("392b4686b770bae2da6bf5ac4574add5/index.m3u8?e=2068731801&s=tenr-yHXUv1wibfka78s2A&scheme=https"),
                  ]),
        TVChannel(id: "s100fest", name: "100% Праздник", groups: [.entertainment], guide: nil, keywords: [], sources: [
                    smotrim("hls/fasttv04/playlist_3.m3u8"),
                  ]),
    ]

    // Кино и сериалы
    private static let movies: [TVChannel] = [
        TVChannel(id: "s100love", name: "100% Любовь", groups: [.movies], guide: nil, keywords: ["сериалы"], sources: [
                    smotrim("hls/fasttv01/playlist_2.m3u8"),
                  ]),
        TVChannel(id: "s100men", name: "100% Мужское", groups: [.movies], guide: nil, keywords: ["боевики"], sources: [
                    smotrim("hls/fasttv02/playlist_3.m3u8"),
                  ]),
        TVChannel(id: "s100classic", name: "100% Классика", groups: [.movies], guide: nil, keywords: ["советское кино"], sources: [
                    smotrim("hls/fasttv03/playlist_3.m3u8"),
                  ]),
        TVChannel(id: "detective", name: "Честный детектив", groups: [.movies], guide: nil, keywords: [], sources: [
                    .stream("https://live-vgtrksmotrim.cdnvideo.ru/vgtrksmotrim/smotrim-live-01.smil/playlist.m3u8"),
                  ]),
        TVChannel(id: "zvezdaplus", name: "Звезда Плюс", groups: [.movies], guide: nil, keywords: [], sources: [
                    .stream("https://tvzvezda.bonus-tv.ru/cdn/zvezdaplus/playlist.m3u8"),
                  ]),
    ]

    // Детям
    private static let kids: [TVChannel] = [
        TVChannel(id: "solnce", name: "Солнце", groups: [.kids], guide: "solnce", keywords: ["мультфильмы"], sources: [
                    vitrina("solnce", "thesun_v2/solnce/vitrinatv_web/63987dcb40ced", "solntse/solntse", "17543539"),
                  ]),
        TVChannel(id: "s100kids", name: "100% Детское", groups: [.kids], guide: nil, keywords: ["мультфильмы"], sources: [
                    smotrim("hls/fasttv05/playlist_3.m3u8"),
                  ]),
    ]

    // Музыка
    private static let music: [TVChannel] = [
        TVChannel(id: "rutv", name: "RU.TV", groups: [.music], guide: nil, keywords: ["ру тв", "ru tv"], sources: [
                    rutube("b1eb8e90d7e636677b3eb73b4fcbb717/index.m3u8?e=2069285076&s=d-E-bxKy2v3EEJ94RQX9CA&scheme=https"),
                  ]),
    ]

    // Познавательные
    private static let knowledge: [TVChannel] = [
        TVChannel(id: "rtdoc", name: "RT Документальный", groups: [.knowledge], guide: nil, keywords: ["рт", "документальный"], sources: [
                    .stream("https://rt-doc.rttv.com/dvr/rtdru/playlist.m3u8"),
                  ]),
        TVChannel(id: "s100facts", name: "100% Факты", groups: [.knowledge], guide: nil, keywords: ["документальный"], sources: [
                    smotrim("hls/fasttv06/playlist_3.m3u8"),
                  ]),
    ]

    // Города
    private static let cities: [TVChannel] = [
        TVChannel(id: "spb", name: "Санкт-Петербург", groups: [.cities], guide: nil, keywords: ["петербург", "спб"], sources: [
                    smotrim("hls2/ext_spbtv/playlist_5.m3u8"),
                  ]),
        TVChannel(id: "tk78", name: "Телеканал 78", groups: [.cities], guide: "tk78", keywords: ["78", "петербург"], sources: [
                    vitrina("tk78", "tk78/vitrinatv_web", "tk78/tk78", "17543495"),
                  ]),
        TVChannel(id: "doverie", name: "Москва Доверие", groups: [.cities], guide: nil, keywords: ["доверие", "москва"], sources: [
                    smotrim("hls2/doverie/playlist_3.m3u8"),
                  ]),
    ]
}

extension Channel {
    /// Whether this is a built-in channel ("tv:1tvch").
    var isBuiltIn: Bool { url.hasPrefix(TVCatalog.scheme) }

    /// A built-in channel saved in favourites or recent ones gets the current name and logo of
    /// the catalog; a channel of a playlist stays as it is.
    var refreshed: Channel {
        TVCatalog.channel(forLink: url)?.channel ?? self
    }

    /// The name of the logo in the asset catalog of a built-in channel.
    var assetName: String? {
        guard let logo = logo, logo.hasPrefix(TVCatalog.assetPrefix) else { return nil }
        return String(logo.dropFirst(TVCatalog.assetPrefix.count))
    }

    /// "ТВ" for a channel without a logo: the first letters of the first two words.
    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "TV" : letters.uppercased()
    }
}
