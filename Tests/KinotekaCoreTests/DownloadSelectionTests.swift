import XCTest
@testable import KinotekaCore

final class DownloadSelectionTests: XCTestCase {
    private func file(_ id: Int, _ path: String, _ size: Int64 = 1_000_000_000) -> TorrentFile {
        TorrentFile(id: id, path: path, length: size)
    }

    func testMovieTakesMainFeature() {
        let all = [file(1, "Movie/Movie.2020.mkv", 9_000_000_000), file(2, "Movie/Extras/Interview.mkv", 500_000_000),
                   file(3, "Movie/Movie.2020.srt", 50_000)]
        XCTAssertEqual(DownloadSelection.files(all, isSeries: false, season: nil, episode: nil).map(\.id), [1])
    }

    func testMovieInPartsTakesAll() {
        let all = [file(1, "Movie/CD1.avi", 700_000_000), file(2, "Movie/CD2.avi", 700_000_000)]
        XCTAssertEqual(DownloadSelection.files(all, isSeries: false, season: nil, episode: nil).map(\.id), [1, 2])
    }

    func testSeriesEpisodeSeasonAndAll() {
        let all = [file(1, "Show/Season 1/Show.S01E01.mkv"), file(2, "Show/Season 1/Show.S01E02.mkv"),
                   file(3, "Show/Season 2/Show.S02E01.mkv"), file(4, "Show/Season 2/Show.S02E02.mkv")]
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: 2, episode: 1).map(\.id), [3])
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: 1, episode: nil).map(\.id), [1, 2])
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: nil, episode: nil).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: 3, episode: nil), [])
    }

    func testSingleSeasonWithoutNumbers() {
        let all = [file(1, "Show/01.mkv"), file(2, "Show/02.mkv")]
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: 1, episode: nil).map(\.id), [1, 2])
        XCTAssertEqual(DownloadSelection.files(all, isSeries: true, season: 1, episode: 2).map(\.id), [2])
    }

    func testSubtitleCompanions() {
        let video = file(1, "Movie/Movie.2020.mkv")
        let all = [video, file(2, "Movie/Movie.2020.rus.srt", 10), file(3, "Movie/Subs/Other.srt", 10),
                   file(4, "Movie/Movie.2020.ac3", 10)]
        XCTAssertEqual(DownloadSelection.subtitles(for: video, in: all).map(\.id), [2])
    }

    func testTorrentFileCodable() throws {
        let original = file(7, "A/B.mkv", 42)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(TorrentFile.self, from: data), original)
    }
}
