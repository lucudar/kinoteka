import XCTest
@testable import KinotekaCore

final class ReleaseParserTests: XCTestCase {
    func testQuality() {
        XCTAssertEqual(ReleaseParser.quality(title: "Дюна / Dune: Part Two / 2024 / ПМ, СТ / WEB-DL (1080p) | Jaskier", height: 480), .fullHD)
        XCTAssertEqual(ReleaseParser.quality(title: "Dune / 4K, HEVC, HDR, Dolby Vision"), .uhd)
        XCTAssertEqual(ReleaseParser.quality(title: "Film 2160p UHD BDRemux"), .uhd)
        XCTAssertEqual(ReleaseParser.quality(title: "Дюна / Dune: Part One (2021) UHD BDRip-HEVC 1080p от RIPS CLUB | HDR"), .fullHD)
        XCTAssertEqual(ReleaseParser.quality(title: "Film / 4K, HEVC, HDR / WEB-DL", height: 1080), .uhd)
        XCTAssertEqual(ReleaseParser.quality(title: "Film (2021) BDRip 720p"), .hd)
        XCTAssertEqual(ReleaseParser.quality(title: "Film (2021) WEB-DLRip"), .sd)
        XCTAssertEqual(ReleaseParser.quality(title: "Film (2021) WEB-DLRip", height: 720), .hd)
        XCTAssertEqual(ReleaseParser.quality(title: "Film (2021) BDRemux"), .unknown)
    }

    func testHDRAndCam() {
        XCTAssertTrue(ReleaseParser.isHDR(title: "Film 2160p HDR10+ HEVC"))
        XCTAssertTrue(ReleaseParser.isHDR(title: "Film 2160p Dolby Vision"))
        XCTAssertTrue(ReleaseParser.isHDR(title: "Film", videoType: "hdr"))
        XCTAssertFalse(ReleaseParser.isHDR(title: "Film 1080p | HDRezka Studio"))
        XCTAssertFalse(ReleaseParser.isHDR(title: "Film DVDRip DVO"))
        XCTAssertTrue(ReleaseParser.isCamRip("Дюна: Часть вторая (2024) TS 1080p | P"))
        XCTAssertTrue(ReleaseParser.isCamRip("Film CAMRip"))
        XCTAssertTrue(ReleaseParser.isCamRip("Фильм (2024) Экранка"))
        XCTAssertFalse(ReleaseParser.isCamRip("Film BDRemux M2TS DTS-HD"))
        XCTAssertFalse(ReleaseParser.isCamRip("Film WEB-DL 1080p | TVShows"))
    }

    func testSeasons() {
        XCTAssertEqual(ReleaseParser.seasons(in: "Во все тяжкие (1-5 сезоны: 1-62 серии из 62) / Breaking Bad"), [1, 2, 3, 4, 5])
        XCTAssertEqual(ReleaseParser.seasons(in: "Во все тяжкие (4 сезон: 1-13 серии из 13) / Breaking Bad / 2011"), [4])
        XCTAssertEqual(ReleaseParser.seasons(in: "Во все тяжкие / Breaking Bad / Сезон: 1 / Серии 1-7 (7)"), [1])
        XCTAssertEqual(ReleaseParser.seasons(in: "Сериал / Сезоны 1-3 / Серии 1-30"), [1, 2, 3])
        XCTAssertEqual(ReleaseParser.seasons(in: "Друзья (10 сезонов)"), Array(1...10))
        XCTAssertEqual(ReleaseParser.seasons(in: "Show.S02E05.1080p.WEB-DL"), [2])
        XCTAssertEqual(ReleaseParser.seasons(in: "Show S01-S03 1080p"), [1, 2, 3])
        XCTAssertEqual(ReleaseParser.seasons(in: "Show.S01E01-08.1080p"), [1])
        XCTAssertEqual(ReleaseParser.seasons(in: "Show Season 3 Complete"), [3])
        XCTAssertEqual(ReleaseParser.seasons(in: "Дюна / Dune (2021) BDRip 1080p | D"), [])
        XCTAssertEqual(ReleaseParser.seasonsText([2]), "2 сезон")
        XCTAssertEqual(ReleaseParser.seasonsText([1, 2, 3]), "1–3 сезоны")
        XCTAssertEqual(ReleaseParser.seasonsText([1, 3]), "1, 3 сезоны")
        XCTAssertNil(ReleaseParser.seasonsText([]))
    }

    func testVoices() {
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Дюна / Dune: Part One / 2021 / ДБ, ПМ, СТ / WEB-DL (1080p)"), [.dub, .multi, .subtitles])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Дюна / Dune: Part One (2021) WEB-DL 1080p от селезень | D, P | iTunes"), [.dub, .multi])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Dune [2021, WEB-DLRip] Dub (iTunes) + MVO + DVO + Sub"), [.dub, .multi, .two, .subtitles])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Фильм (2020) HDRip | L1"), [.amateur])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Фильм / 2 x АП (Гоблин) / BDRip"), [.author])
        XCTAssertEqual(ReleaseParser.voiceKinds(in: "Movie 2020 1080p WEB-DL"), [])
    }

    func testYear() {
        XCTAssertEqual(ReleaseParser.year(in: "Бегущий по лезвию 2049 / Blade Runner 2049 (2017) BDRip"), 2017)
        XCTAssertEqual(ReleaseParser.year(in: "1917 / 1917 / 2019 / ДБ / BDRip"), 2019)
        XCTAssertEqual(ReleaseParser.year(in: "Дюна / Dune (Дени Вильнев) [2021, США, фантастика]"), 2021)
        XCTAssertEqual(ReleaseParser.year(in: "Брат (Дилогия) / 1997-2000 / РУ, СТ"), 1997)
        XCTAssertEqual(ReleaseParser.year(in: "Film.2015.1080p"), 2015)
        XCTAssertNil(ReleaseParser.year(in: "Film 1080p"))
    }

    func testTextMatch() {
        XCTAssertEqual(TextMatch.normalized("Ёлки: Последние!  (2018)"), "елки последние 2018")
        XCTAssertTrue(TextMatch.containsPhrase("Dune.Part.Two.2024.1080p", "Dune: Part Two"))
        XCTAssertTrue(TextMatch.containsPhrase("Брат 2 / Brother 2 (2000)", "Брат 2"))
        XCTAssertFalse(TextMatch.containsPhrase("Братья Гримм (2005)", "Брат"))
    }
}
