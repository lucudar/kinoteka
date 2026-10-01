import Foundation

/// A portable backup of local library data and non-secret preferences.
/// API keys and playlist addresses are intentionally not included.
struct AppBackup: Codable {
    var formatVersion = 1
    var createdAt = Date()
    var library: LibraryData
    var settings: BackupSettings
}

struct BackupSettings: Codable {
    var autoNext: Bool
    var savePlayerSettings: Bool
    var playerRate: Double
    var playerAspect: String
    var backgroundAudio: Bool
    var searchServer: String
    var preferredQuality: Int
    var preferredVoice: String
    var autoPlayBest: Bool
    var prepareTorrent: Bool
    var smartQuality: Bool
    var automaticFallback: Bool
    var automaticRecovery: Bool
    var preloadNextEpisode: Bool
    var playerGestures: Bool

    static func current(defaults: UserDefaults = .standard) -> BackupSettings {
        BackupSettings(
            autoNext: defaults.bool(forKey: SettingsKeys.autoNext),
            savePlayerSettings: defaults.bool(forKey: SettingsKeys.savePlayerSettings),
            playerRate: defaults.double(forKey: SettingsKeys.playerRate),
            playerAspect: defaults.string(forKey: SettingsKeys.playerAspect) ?? AspectMode.fit.rawValue,
            backgroundAudio: defaults.bool(forKey: SettingsKeys.backgroundAudio),
            searchServer: defaults.string(forKey: SettingsKeys.searchServer) ?? TorrentSearchService.defaultServer,
            preferredQuality: defaults.object(forKey: SettingsKeys.preferredQuality) as? Int ?? ReleaseQuality.fullHD.rawValue,
            preferredVoice: defaults.string(forKey: SettingsKeys.preferredVoice) ?? "auto",
            autoPlayBest: defaults.bool(forKey: SettingsKeys.autoPlayBest),
            prepareTorrent: defaults.bool(forKey: SettingsKeys.prepareTorrent),
            smartQuality: defaults.bool(forKey: SettingsKeys.smartQuality),
            automaticFallback: defaults.bool(forKey: SettingsKeys.automaticFallback),
            automaticRecovery: defaults.bool(forKey: SettingsKeys.automaticRecovery),
            preloadNextEpisode: defaults.bool(forKey: SettingsKeys.preloadNextEpisode),
            playerGestures: defaults.bool(forKey: SettingsKeys.playerGestures)
        )
    }

    func apply(to defaults: UserDefaults = .standard) {
        defaults.set(autoNext, forKey: SettingsKeys.autoNext)
        defaults.set(savePlayerSettings, forKey: SettingsKeys.savePlayerSettings)
        defaults.set(playerRate, forKey: SettingsKeys.playerRate)
        defaults.set(playerAspect, forKey: SettingsKeys.playerAspect)
        defaults.set(backgroundAudio, forKey: SettingsKeys.backgroundAudio)
        defaults.set(searchServer, forKey: SettingsKeys.searchServer)
        defaults.set(preferredQuality, forKey: SettingsKeys.preferredQuality)
        defaults.set(preferredVoice, forKey: SettingsKeys.preferredVoice)
        defaults.set(autoPlayBest, forKey: SettingsKeys.autoPlayBest)
        defaults.set(prepareTorrent, forKey: SettingsKeys.prepareTorrent)
        defaults.set(smartQuality, forKey: SettingsKeys.smartQuality)
        defaults.set(automaticFallback, forKey: SettingsKeys.automaticFallback)
        defaults.set(automaticRecovery, forKey: SettingsKeys.automaticRecovery)
        defaults.set(preloadNextEpisode, forKey: SettingsKeys.preloadNextEpisode)
        defaults.set(playerGestures, forKey: SettingsKeys.playerGestures)
    }
}

enum BackupError: LocalizedError {
    case unsupportedVersion
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "Эта резервная копия создана более новой версией приложения."
        case .invalidFile:
            return "Не удалось прочитать резервную копию."
        }
    }
}

enum BackupService {
    static func exportURL(library: LibraryData) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "Kinoteka-backup-\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let backup = AppBackup(library: library, settings: .current())
        if let data = try? encoder.encode(backup) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }

    static func load(from url: URL) throws -> AppBackup {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { throw BackupError.invalidFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(AppBackup.self, from: data) else {
            throw BackupError.invalidFile
        }
        guard backup.formatVersion <= 1 else { throw BackupError.unsupportedVersion }
        return backup
    }
}