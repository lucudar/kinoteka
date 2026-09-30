import XCTest
@testable import KinotekaCore

final class M3UParserTests: XCTestCase {
    func testParsesChannels() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-logo="http://logo/1.png" group-title="Новости",Первый канал
        http://example.com/1.m3u8
        #EXTINF:-1 tvg-name="Второй",Канал, с запятой
        #EXTGRP:Кино
        #EXTVLCOPT:http-user-agent=TestAgent
        #EXTVLCOPT:http-referrer=http://ref/
        http://example.com/2.m3u8
        #EXTINF:-1,Дубль
        http://example.com/1.m3u8
        #EXTINF:-1 group-title="A, B",Name "quoted"
        https://example.com/3.ts
        """
        let channels = M3UParser.parse(text)
        XCTAssertEqual(channels.count, 3)
        XCTAssertEqual(channels[0].name, "Первый канал")
        XCTAssertEqual(channels[0].logo, "http://logo/1.png")
        XCTAssertEqual(channels[0].group, "Новости")
        XCTAssertEqual(channels[1].name, "Канал, с запятой")
        XCTAssertEqual(channels[1].group, "Кино")
        XCTAssertEqual(channels[1].userAgent, "TestAgent")
        XCTAssertEqual(channels[1].referrer, "http://ref/")
        XCTAssertEqual(channels[2].group, "A, B")
        XCTAssertEqual(channels[2].name, "Name \"quoted\"")
    }

    func testFallbackName() {
        let channels = M3UParser.parse("http://tv.example.org/live.m3u8\n")
        XCTAssertEqual(channels.first?.name, "tv.example.org")
    }
}
