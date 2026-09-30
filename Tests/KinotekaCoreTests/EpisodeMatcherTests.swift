import XCTest
@testable import KinotekaCore

final class EpisodeMatcherTests: XCTestCase {
    private func file(_ id: Int, _ path: String) -> TorrentFile {
        TorrentFile(id: id, path: path, length: 1_000_000_000)
    }

    func testParsesCommonNames() {
        XCTAssertEqual(EpisodeMatcher.parse("Breaking.Bad.S01E02.1080p.mkv")?.season, 1)
        XCTAssertEqual(EpisodeMatcher.parse("Breaking.Bad.S01E02.1080p.mkv")?.episode, 2)
        XCTAssertEqual(EpisodeMatcher.parse("Show 2x05 HDTV.avi")?.episode, 5)
        XCTAssertEqual(EpisodeMatcher.parse("Show 2x05 HDTV.avi")?.season, 2)
        XCTAssertEqual(EpisodeMatcher.parse("Сериал 3 сезон 7 серия.mkv")?.season, 3)
        XCTAssertEqual(EpisodeMatcher.parse("Сериал 3 сезон 7 серия.mkv")?.episode, 7)
        XCTAssertEqual(EpisodeMatcher.parse("04 серия.mkv")?.episode, 4)
        XCTAssertNil(EpisodeMatcher.parse("04 серия.mkv")?.season)
        XCTAssertEqual(EpisodeMatcher.parse("01. Пилот.mkv")?.episode, 1)
        XCTAssertNil(EpisodeMatcher.parse("Movie.1920x1080.mkv"))
    }

    func testFolderSeason() {
        XCTAssertEqual(EpisodeMatcher.folderSeason("Show/Season 2/05.mkv"), 2)
        XCTAssertEqual(EpisodeMatcher.folderSeason("Show/S03/05.mkv"), 3)
        XCTAssertEqual(EpisodeMatcher.folderSeason("Сериал/4 сезон/05.mkv"), 4)
        XCTAssertNil(EpisodeMatcher.folderSeason("05.mkv"))
    }

    func testFindsEpisodeUsingFolderSeason() {
        let files = [
            file(1, "Show/Season 1/01.mkv"), file(2, "Show/Season 1/02.mkv"),
            file(3, "Show/Season 2/01.mkv"), file(4, "Show/Season 2/02.mkv")
        ]
        XCTAssertEqual(EpisodeMatcher.find(in: files, season: 2, episode: 2)?.id, 4)
        XCTAssertEqual(EpisodeMatcher.find(in: files, season: 1, episode: 1)?.id, 1)
        XCTAssertNil(EpisodeMatcher.find(in: files, season: 3, episode: 1))
    }

    func testNextUsesEpisodeNumbersNotAlphabet() {
        let files = [
            file(1, "Show/Show.S01E10.mkv"), file(2, "Show/Show.S01E2.mkv"),
            file(3, "Show/Show.S01E1.mkv"), file(4, "Show/Show.S01E3.mkv")
        ]
        XCTAssertEqual(EpisodeMatcher.next(after: files[2], in: files)?.id, 2)
        XCTAssertEqual(EpisodeMatcher.next(after: files[1], in: files)?.id, 4)
        XCTAssertEqual(EpisodeMatcher.next(after: files[3], in: files)?.id, 1)
        XCTAssertNil(EpisodeMatcher.next(after: files[0], in: files))
    }

    func testNextStaysInTheSameFolder() {
        let files = [
            file(1, "Show/1080p LostFilm/S01E01.mkv"), file(2, "Show/1080p LostFilm/S01E02.mkv"),
            file(3, "Show/720p Кубик/S01E01.mkv"), file(4, "Show/720p Кубик/S01E02.mkv")
        ]
        XCTAssertEqual(EpisodeMatcher.next(after: files[2], in: files)?.id, 4)
        XCTAssertEqual(EpisodeMatcher.next(after: files[0], in: files)?.id, 2)
    }

    func testNextGoesToTheNextSeason() {
        let files = [
            file(1, "Show/Season 1/01.mkv"), file(2, "Show/Season 1/02.mkv"),
            file(3, "Show/Season 2/01.mkv"), file(4, "Show/Season 2/02.mkv")
        ]
        XCTAssertEqual(EpisodeMatcher.next(after: files[1], in: files)?.id, 3)
        XCTAssertNil(EpisodeMatcher.next(after: files[3], in: files))
    }

    func testNextWithoutNumbersUsesFolderOrder() {
        let files = [file(1, "Film/Part B.mkv"), file(2, "Film/Part A.mkv"), file(3, "Other/Part C.mkv")]
        XCTAssertEqual(EpisodeMatcher.next(after: files[1], in: files)?.id, 1)
        XCTAssertNil(EpisodeMatcher.next(after: files[0], in: files))
    }
}
