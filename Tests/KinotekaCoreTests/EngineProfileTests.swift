import XCTest
@testable import KinotekaCore

final class EngineProfileTests: XCTestCase {
    private let gb: Int64 = 1 << 30

    private func env(_ connection: ConnectionClass, free: Int64? = 20 << 30, expensive: Bool = false,
                     constrained: Bool = false,
                     encryption: EngineEncryptionMode = .automatic) -> EngineEnvironment {
        EngineEnvironment(connection: connection, isExpensive: expensive, isConstrained: constrained,
                          freeBytes: free, cachePath: "/tmp/cache", encryption: encryption)
    }

    func testDiskCacheFollowsFreeSpace() {
        XCTAssertNil(EngineProfile.diskCache(freeBytes: nil))
        XCTAssertEqual(EngineProfile.diskCache(freeBytes: 40 * gb), 2 * gb)
        XCTAssertEqual(EngineProfile.diskCache(freeBytes: 8 * gb), gb)
        XCTAssertEqual(EngineProfile.diskCache(freeBytes: 4 * gb), 512 << 20)
        XCTAssertEqual(EngineProfile.diskCache(freeBytes: 2 * gb), 256 << 20)
        XCTAssertNil(EngineProfile.diskCache(freeBytes: gb))
    }

    func testWifiUsesTheBigDiskBuffer() {
        let profile = EngineProfile.make(env(.wifi))
        XCTAssertEqual(profile.kind, .fast)
        XCTAssertEqual(profile.cacheBytes, 2 * gb)
        XCTAssertTrue(profile.useDisk)
        XCTAssertEqual(profile.connections, 60)
        XCTAssertTrue(profile.utp)
        XCTAssertFalse(profile.forceEncrypt)
        XCTAssertEqual(profile.uploadLimit, 0)
        XCTAssertEqual(profile.warmupHead, 8 << 20)
        XCTAssertEqual(profile.warmupTail, 4 << 20)
    }

    func testMobileNetworkIsTCPOnlyWithLimitedUpload() {
        let profile = EngineProfile.make(env(.cellular))
        XCTAssertEqual(profile.kind, .mobile)
        XCTAssertEqual(profile.cacheBytes, 256 << 20)
        XCTAssertTrue(profile.useDisk)
        XCTAssertEqual(profile.connections, 40)
        XCTAssertFalse(profile.utp)
        XCTAssertFalse(profile.forceEncrypt)
        XCTAssertEqual(profile.uploadLimit, 100)
    }

    func testHotspotCountsAsMobile() {
        let profile = EngineProfile.make(env(.wifi, expensive: true))
        XCTAssertEqual(profile.kind, .mobile)
        XCTAssertFalse(profile.forceEncrypt)
    }

    func testIPv6UPnPAndAFixedPortStayOff() {
        for connection in [ConnectionClass.wifi, .cellular, .wired, .other] {
            let settings = EngineProfile.make(env(connection)).settings
            XCTAssertEqual(settings["EnableIPv6"], .bool(false))
            XCTAssertEqual(settings["DisableUPNP"], .bool(true))
            XCTAssertEqual(settings["PeersListenPort"], .int(0))
            XCTAssertEqual(settings["ForceEncrypt"], .bool(false))
        }
    }

    func testOnlyTheKindOfNetworkChangesTheProfile() {
        // Wi‑Fi, a cable and a VPN interface need no retune of the engine between them.
        let wifi = EngineProfile.make(env(.wifi))
        XCTAssertEqual(wifi, EngineProfile.make(env(.wired)))
        XCTAssertEqual(wifi, EngineProfile.make(env(.other)))
        XCTAssertNotEqual(wifi, EngineProfile.make(env(.cellular)))
        XCTAssertEqual(EngineProfile.make(env(.cellular)), EngineProfile.make(env(.wifi, expensive: true)))
    }

    func testLowDataModeSavesTraffic() {
        let profile = EngineProfile.make(env(.cellular, constrained: true))
        XCTAssertEqual(profile.kind, .economy)
        XCTAssertEqual(profile.cacheBytes, 128 << 20)
        XCTAssertEqual(profile.warmupHead, 0)
        XCTAssertEqual(profile.warmupTail, 0)
        XCTAssertEqual(profile.connections, 25)
    }

    func testLittleFreeSpaceKeepsTheCacheInMemory() {
        let profile = EngineProfile.make(env(.wifi, free: gb))
        XCTAssertFalse(profile.useDisk)
        XCTAssertEqual(profile.cacheBytes, EngineProfile.memoryCache)
        XCTAssertFalse(EngineProfile.make(env(.wifi, free: nil)).useDisk)
    }

    func testEncryptionChoice() {
        XCTAssertTrue(EngineProfile.make(env(.wifi, encryption: .always)).forceEncrypt)
        XCTAssertTrue(EngineProfile.make(env(.cellular, encryption: .always)).forceEncrypt)
        XCTAssertFalse(EngineProfile.make(env(.cellular, encryption: .automatic)).forceEncrypt)
        XCTAssertEqual(EngineEncryptionMode.stored("always"), .always)
        XCTAssertEqual(EngineEncryptionMode.stored("automatic"), .automatic)
        // The "never" choice of 0.9.0 and missing values are the default.
        XCTAssertEqual(EngineEncryptionMode.stored("never"), .automatic)
        XCTAssertEqual(EngineEncryptionMode.stored(nil), .automatic)
        XCTAssertEqual(EngineEncryptionMode.allCases, [.automatic, .always])
    }

    func testChangesAgainstEngineSettings() throws {
        let json = """
        {"CacheSize": 67108864, "UseDisk": false, "TorrentsSavePath": "", "RemoveCacheOnDrop": false,
         "ReaderReadAHead": 95, "PreloadCache": 50, "ResponsiveMode": true, "ConnectionsLimit": 25,
         "DisableTCP": false, "DisableUTP": false, "DisableUPNP": false, "DisableDHT": false,
         "DisablePEX": false, "DisableUpload": false, "ForceEncrypt": false, "UploadRateLimit": 0,
         "DownloadRateLimit": 0, "EnableIPv6": false, "PeersListenPort": 0, "RetrackersMode": 1,
         "TorrentDisconnectTimeout": 30,
         "EnableDLNA": false, "EnableRutorSearch": false}
        """
        let current = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let profile = EngineProfile.make(env(.wifi))
        XCTAssertEqual(profile.changes(from: current),
                       ["CacheSize", "ConnectionsLimit", "DisableUPNP", "RemoveCacheOnDrop", "TorrentDisconnectTimeout",
                        "TorrentsSavePath", "UseDisk"])

        // What the engine stores and returns after the change.
        let merged = profile.merged(into: current)
        let stored = try JSONSerialization.data(withJSONObject: merged)
        let reloaded = try XCTUnwrap(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertEqual(profile.changes(from: reloaded), [])
        XCTAssertEqual(reloaded["PreloadCache"] as? Int, 50)

        // Another network changes only what differs.
        let mobile = EngineProfile.make(env(.cellular))
        XCTAssertEqual(mobile.changes(from: reloaded),
                       ["CacheSize", "ConnectionsLimit", "DisableUTP", "UploadRateLimit"])
        XCTAssertEqual(EngineProfile.make(env(.wifi, encryption: .always)).changes(from: reloaded), ["ForceEncrypt"])
    }

    func testMissingKeysAreZeroValues() {
        let profile = EngineProfile.make(env(.wifi))
        let changes = Set(profile.changes(from: [:]))
        XCTAssertFalse(changes.contains("EnableDLNA"))
        XCTAssertFalse(changes.contains("DisableTCP"))
        XCTAssertTrue(changes.contains("CacheSize"))
        XCTAssertTrue(changes.contains("ResponsiveMode"))
    }

    func testTexts() {
        XCTAssertEqual(EngineProfile.sizeText(2 << 30), "2 ГБ")
        XCTAssertEqual(EngineProfile.sizeText(3 << 29), "1,5 ГБ")
        XCTAssertEqual(EngineProfile.sizeText(256 << 20), "256 МБ")
        let summary = EngineProfile.make(env(.cellular)).summary
        XCTAssertTrue(summary.contains("кэш 256 МБ на диске"))
        XCTAssertTrue(summary.contains("только TCP"))
        XCTAssertFalse(summary.contains("шифрование"))
        XCTAssertTrue(EngineProfile.make(env(.cellular, encryption: .always)).summary.contains("только шифрование"))
        XCTAssertTrue(EngineProfile.make(env(.wifi, free: gb)).summary.contains("кэш 64 МБ в памяти"))
    }

    func testWarmupTargetPicksThePlayedFile() {
        let movie = [
            TorrentFile(id: 0, path: "Film/Sample/sample.mkv", length: 50_000_000),
            TorrentFile(id: 1, path: "Film/Film.2019.1080p.mkv", length: 9_000_000_000),
            TorrentFile(id: 2, path: "Film/Film.nfo", length: 2_000)
        ]
        XCTAssertEqual(WarmupTarget(isSeries: false).file(in: movie)?.id, 1)
        XCTAssertEqual(WarmupTarget(fileId: 0, isSeries: false).file(in: movie)?.id, 1)

        let series = (1...3).map { TorrentFile(id: $0, path: "Show/Show.S01E0\($0).mkv", length: 1_000_000_000) }
        XCTAssertEqual(WarmupTarget(season: 1, episode: 2, isSeries: true).file(in: series)?.id, 2)
        XCTAssertEqual(WarmupTarget(fileId: 3, isSeries: true).file(in: series)?.id, 3)
        XCTAssertEqual(WarmupTarget(isSeries: true).file(in: series)?.id, 1)
    }
}
