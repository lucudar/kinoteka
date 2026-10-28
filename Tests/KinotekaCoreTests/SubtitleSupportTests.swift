import XCTest
@testable import KinotekaCore

final class SubtitleSupportTests: XCTestCase {
    func testHashOfZerosIsFileSize() {
        let zeros = Data(count: OpenSubtitlesHash.chunkSize)
        XCTAssertEqual(OpenSubtitlesHash.compute(fileSize: 65_536, head: zeros, tail: zeros), "0000000000010000")
    }

    func testHashSumsLittleEndianWords() {
        var head = Data(count: OpenSubtitlesHash.chunkSize)
        head[0] = 0x01
        head[8] = 0x02
        var tail = Data(count: OpenSubtitlesHash.chunkSize)
        tail[OpenSubtitlesHash.chunkSize - 8] = 0xFF
        tail[OpenSubtitlesHash.chunkSize - 1] = 0x01
        // size 0x20000 + 1 + 2 + 0x01000000000000FF
        XCTAssertEqual(OpenSubtitlesHash.compute(fileSize: 0x20000, head: head, tail: tail), "0100000000020102")
    }

    func testHashOverflowWraps() {
        let ones = Data(repeating: 0xFF, count: OpenSubtitlesHash.chunkSize)
        XCTAssertNotNil(OpenSubtitlesHash.compute(fileSize: Int64.max, head: ones, tail: ones))
    }

    func testHashNeedsEnoughData() {
        XCTAssertNil(OpenSubtitlesHash.compute(fileSize: 1_000, head: Data(count: 1_000), tail: Data(count: 1_000)))
    }

    func testTrackLanguageGuess() {
        XCTAssertEqual(TrackLanguage.guess("Дубляж - [Русский]"), .russian)
        XCTAssertEqual(TrackLanguage.guess("Track 2 - [Russian]"), .russian)
        XCTAssertEqual(TrackLanguage.guess("MVO LostFilm"), .russian)
        XCTAssertEqual(TrackLanguage.guess("rus"), .russian)
        XCTAssertEqual(TrackLanguage.guess("Track 1 - [English]"), .foreign)
        XCTAssertEqual(TrackLanguage.guess("Original"), .foreign)
        XCTAssertEqual(TrackLanguage.guess("Український дубляж"), .foreign)
        XCTAssertEqual(TrackLanguage.guess("Ukr"), .foreign)
        XCTAssertEqual(TrackLanguage.guess("Track 1"), .unknown)
        XCTAssertEqual(TrackLanguage.guess("Дорожка 1"), .unknown)
        XCTAssertEqual(TrackLanguage.guess(""), .unknown)
    }

    func testNeedsSubtitles() {
        XCTAssertTrue(TrackLanguage.needsSubtitles(audio: ["Track 1 - [English]"], subtitles: ["English"]))
        XCTAssertFalse(TrackLanguage.needsSubtitles(audio: ["Track 1 - [English]"], subtitles: ["Русские форсированные"]))
        XCTAssertFalse(TrackLanguage.needsSubtitles(audio: ["Дубляж", "Original"], subtitles: []))
        XCTAssertFalse(TrackLanguage.needsSubtitles(audio: ["Track 1"], subtitles: []))
        XCTAssertFalse(TrackLanguage.needsSubtitles(audio: [], subtitles: []))
    }

    private func candidate(_ id: Int, _ language: String, release: String = "", downloads: Int = 0,
                           hash: Bool = false, hi: Bool = false, season: Int? = nil, episode: Int? = nil) -> SubtitleCandidate {
        SubtitleCandidate(fileId: id, language: language, release: release, fileName: release + ".srt",
                          downloads: downloads, hearingImpaired: hi, machineTranslated: false,
                          hashMatch: hash, season: season, episode: episode)
    }

    func testRankingPrefersLanguageThenHashThenRelease() {
        let list = [
            candidate(1, "en", release: "Movie.2020.1080p.WEB-DL", downloads: 9_000),
            candidate(2, "ru", release: "Movie.2020.720p.BluRay", downloads: 100),
            candidate(3, "ru", release: "Movie.2020.1080p.WEB-DL.NTb", downloads: 10),
            candidate(4, "ru", release: "Other", downloads: 5, hash: true)
        ]
        let sorted = SubtitleRanking.sorted(list, languages: ["ru", "en"], releaseName: "Movie.2020.1080p.WEB-DL.NTb.mkv")
        XCTAssertEqual(sorted.map(\.fileId), [4, 3, 2, 1])
    }

    func testRankingFiltersOtherEpisodes() {
        let list = [candidate(1, "ru", season: 1, episode: 2), candidate(2, "ru", season: 1, episode: 3), candidate(3, "ru")]
        let sorted = SubtitleRanking.sorted(list, languages: ["ru"], releaseName: nil, season: 1, episode: 3)
        XCTAssertEqual(Set(sorted.map(\.fileId)), [2, 3])
    }

    func testRankingPenalizesHearingImpaired() {
        let list = [candidate(1, "ru", downloads: 50, hi: true), candidate(2, "ru", downloads: 50)]
        XCTAssertEqual(SubtitleRanking.sorted(list, languages: ["ru"], releaseName: nil).first?.fileId, 2)
    }

    func testContentRange() {
        XCTAssertEqual(HTTPRange.total(fromContentRange: "bytes 100-199/1234"), 1234)
        XCTAssertEqual(HTTPRange.start(fromContentRange: "bytes 100-199/1234"), 100)
        XCTAssertNil(HTTPRange.total(fromContentRange: "bytes 0-1/*"))
        XCTAssertNil(HTTPRange.total(fromContentRange: nil))
    }
}
