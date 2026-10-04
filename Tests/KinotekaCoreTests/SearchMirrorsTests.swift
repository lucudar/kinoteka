import XCTest
@testable import KinotekaCore

final class SearchMirrorsTests: XCTestCase {
    func testRecognisesPublicMirrors() {
        XCTAssertTrue(SearchMirrors.isBuiltIn("jac.red"))
        XCTAssertTrue(SearchMirrors.isBuiltIn("https://jac.red/"))
        XCTAssertTrue(SearchMirrors.isBuiltIn("https://www.jac.red"))
        XCTAssertTrue(SearchMirrors.isBuiltIn("JR.MAXVOL.PRO"))
        XCTAssertTrue(SearchMirrors.isBuiltIn("https://jac-red.ru/api/v2.0/indexers/all/results"))
        XCTAssertFalse(SearchMirrors.isBuiltIn("http://192.168.1.5:9117"))
        XCTAssertFalse(SearchMirrors.isBuiltIn("https://jacred.example.org"))
        XCTAssertFalse(SearchMirrors.isBuiltIn(""))
        XCTAssertEqual(SearchMirrors.canonical("jr.maxvol.pro/"), "https://jr.maxvol.pro")
        XCTAssertEqual(SearchMirrors.host("https://jac.red/"), "jac.red")
    }

    func testOrderOnWifi() {
        XCTAssertEqual(SearchMirrors.order(configured: "https://jac.red", lastGood: nil, preferDomestic: false),
                       ["https://jac.red", "https://jr.maxvol.pro", "https://jac-red.ru"])
    }

    func testMobileNetworkAsksTheRussianMirrorFirst() {
        XCTAssertEqual(SearchMirrors.order(configured: "jac.red", lastGood: nil, preferDomestic: true),
                       ["https://jr.maxvol.pro", "https://jac.red", "https://jac-red.ru"])
    }

    func testRememberedMirrorComesFirst() {
        XCTAssertEqual(SearchMirrors.order(configured: "https://jac.red", lastGood: "https://jac-red.ru", preferDomestic: true),
                       ["https://jac-red.ru", "https://jr.maxvol.pro", "https://jac.red"])
        XCTAssertEqual(SearchMirrors.order(configured: "https://jac.red", lastGood: "https://jac.red", preferDomestic: false),
                       ["https://jac.red", "https://jr.maxvol.pro", "https://jac-red.ru"])
    }

    func testChosenMirrorComesBeforeTheOthers() {
        XCTAssertEqual(SearchMirrors.order(configured: "jac-red.ru", lastGood: nil, preferDomestic: false),
                       ["https://jac-red.ru", "https://jac.red", "https://jr.maxvol.pro"])
    }

    func testOwnServerIsNeverReplaced() {
        XCTAssertEqual(SearchMirrors.order(configured: "http://192.168.1.5:9117/", lastGood: "https://jac.red", preferDomestic: true),
                       ["http://192.168.1.5:9117"])
        XCTAssertEqual(SearchMirrors.order(configured: "  ", lastGood: nil, preferDomestic: false), [])
    }
}
