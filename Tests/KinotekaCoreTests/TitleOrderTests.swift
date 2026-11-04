import XCTest
@testable import KinotekaCore

/// How many pages load at once.
private actor LoadCounter {
    var now = 0
    var most = 0
    func enter() { now += 1; most = max(most, now) }
    func leave() { now -= 1 }
}

final class TitleOrderTests: XCTestCase {
    private struct Title: Equatable {
        let name: String
        let year: Int?
        let rating: Double?
    }

    private let list = [
        Title(name: "a", year: 1996, rating: 7.1),
        Title(name: "b", year: 2026, rating: nil),
        Title(name: "c", year: nil, rating: 8.4),
        Title(name: "d", year: 2010, rating: 6.0),
        Title(name: "e", year: 2026, rating: 7.1),
        Title(name: "f", year: 0, rating: 0)
    ]

    private func names(_ order: TitleOrder) -> String {
        order.sorted(list, year: { $0.year }, rating: { $0.rating }).map(\.name).joined()
    }

    func testOriginalKeepsTheListOrder() {
        XCTAssertEqual(names(.original), "abcdef")
    }

    func testNewestFirstKeepsTiesAndPutsUnknownYearsLast() {
        XCTAssertEqual(names(.newest), "bedacf")
    }

    func testOldestFirstPutsUnknownYearsLast() {
        XCTAssertEqual(names(.oldest), "adbecf")
    }

    func testRatingKeepsTiesAndPutsUnratedLast() {
        XCTAssertEqual(names(.rating), "caedbf")
    }

    func testValidYear() {
        XCTAssertNil(TitleOrder.validYear(nil))
        XCTAssertNil(TitleOrder.validYear(0))
        XCTAssertNil(TitleOrder.validYear(20260))
        XCTAssertEqual(TitleOrder.validYear(1895), 1895)
    }

    func testTitles() {
        XCTAssertEqual(TitleOrder.original.title(original: "По популярности"), "По популярности")
        XCTAssertEqual(TitleOrder.newest.title(original: "По популярности"), "Сначала новые")
        XCTAssertEqual(TitleOrder(rawValue: "oldest"), .oldest)
    }

    func testPagesComeInOrder() async {
        let answer = await PagedLoad.pages(2...9, width: 3) { number -> Int in
            try await Task.sleep(nanoseconds: UInt64((10 - number) * 2_000_000))
            return number * 10
        }
        XCTAssertNil(answer.error)
        XCTAssertEqual(answer.pages, [20, 30, 40, 50, 60, 70, 80, 90])
    }

    func testPagesStopAtTheFirstFailure() async {
        struct Failure: Error {}
        let answer = await PagedLoad.pages(1...8, width: 4) { number -> Int in
            if number == 3 || number == 6 { throw Failure() }
            return number
        }
        XCTAssertTrue(answer.error is Failure)
        XCTAssertEqual(answer.pages, [1, 2])
    }

    func testPagesLoadAFewAtATime() async {
        let counter = LoadCounter()
        let answer = await PagedLoad.pages(1...10, width: 4) { number -> Int in
            await counter.enter()
            try await Task.sleep(nanoseconds: 5_000_000)
            await counter.leave()
            return number
        }
        let most = await counter.most
        XCTAssertEqual(answer.pages.count, 10)
        XCTAssertLessThanOrEqual(most, 4)
        XCTAssertGreaterThan(most, 1)
    }
}
