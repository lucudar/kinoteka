import XCTest
@testable import KinotekaCore

final class KinopoiskNameTests: XCTestCase {
    func testSeriesAnnotation() {
        let parsed = KinopoiskName.split("Во все тяжкие (сериал, 2008 – 2013)")
        XCTAssertEqual(parsed.title, "Во все тяжкие")
        XCTAssertTrue(parsed.isSeries)
        XCTAssertEqual(parsed.year, 2008)
    }

    func testMiniSeries() {
        let parsed = KinopoiskName.split("Чернобыль (мини-сериал, 2019)")
        XCTAssertEqual(parsed.title, "Чернобыль")
        XCTAssertTrue(parsed.isSeries)
        XCTAssertEqual(parsed.year, 2019)
    }

    func testEnglishSeries() {
        let parsed = KinopoiskName.split("Breaking Bad (TV Series 2008–2013)")
        XCTAssertEqual(parsed.title, "Breaking Bad")
        XCTAssertTrue(parsed.isSeries)
        XCTAssertEqual(parsed.year, 2008)
    }

    func testFilmWithYear() {
        let parsed = KinopoiskName.split("Начало (2010)")
        XCTAssertEqual(parsed.title, "Начало")
        XCTAssertFalse(parsed.isSeries)
        XCTAssertEqual(parsed.year, 2010)
    }

    func testPlainNamesStay() {
        XCTAssertEqual(KinopoiskName.split("Матрица").title, "Матрица")
        XCTAssertNil(KinopoiskName.split("Матрица").year)
        let other = KinopoiskName.split("Фильм (твой выбор)")
        XCTAssertEqual(other.title, "Фильм (твой выбор)")
        XCTAssertFalse(other.isSeries)
        XCTAssertNil(other.year)
    }

    func testRussianPlural() {
        XCTAssertEqual(Plural.ru(1, "год", "года", "лет"), "1 год")
        XCTAssertEqual(Plural.ru(3, "год", "года", "лет"), "3 года")
        XCTAssertEqual(Plural.ru(5, "год", "года", "лет"), "5 лет")
        XCTAssertEqual(Plural.ru(11, "год", "года", "лет"), "11 лет")
        XCTAssertEqual(Plural.ru(21, "год", "года", "лет"), "21 год")
        XCTAssertEqual(Plural.ru(104, "год", "года", "лет"), "104 года")
        XCTAssertEqual(Plural.ru(112, "год", "года", "лет"), "112 лет")
    }
}
