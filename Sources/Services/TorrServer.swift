import Foundation
import TorrServerKit

// MARK: - TorrServer JSON

struct TSFileRaw: Decodable {
    let id: Int?
    let path: String?
    let length: Int64?
}

struct TSStatus: Decodable {
    let hash: String?
    let title: String?
    let stat: Int?
    let statString: String?
    let totalPeers: Int?
    let activePeers: Int?
    let pendingPeers: Int?
    let halfOpenPeers: Int?
    let connectedSeeders: Int?
    let downloadSpeed: Double?
    let uploadSpeed: Double?
    let preloadedBytes: Int64?
    let preloadSize: Int64?
    let bytesRead: Int64?
    let fileStats: [TSFileRaw]?

    var files: [TorrentFile] {
        (fileStats ?? []).compactMap { raw in
            guard let id = raw.id, let path = raw.path else { return nil }
            return TorrentFile(id: id, path: path, length: raw.length ?? 0)
        }
    }

    var peersText: String {
        "Пиры: \(activePeers ?? 0) из \(totalPeers ?? 0), сиды: \(connectedSeeders ?? 0)"
    }

    var speedText: String { TSStatus.rateText(downloadSpeed) }
    var uploadText: String { TSStatus.rateText(uploadSpeed) }

    /// What the engine keeps of the torrent now (its buffer ahead of the playback).
    var cachedText: String {
        ByteCountFormatter.string(fromByteCount: max(0, preloadedBytes ?? 0), countStyle: .file)
    }

    static func rateText(_ value: Double?) -> String {
        let value = value ?? 0
        let bytes: Int64
        if !value.isFinite || value <= 0 {
            bytes = 0
        } else if value >= Double(Int64.max) {
            bytes = Int64.max
        } else {
            bytes = Int64(value)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/с"
    }
}

enum TorrServerError: LocalizedError {
    case notRunning(String)
    case server(String)
    case timeout
    case noVideo

    var errorDescription: String? {
        switch self {
        case .notRunning(let reason):
            return "Торрент-движок не запустился: \(reason)"
        case .server(let text):
            return text.isEmpty ? "Торрент-движок вернул ошибку." : "Торрент-движок: \(text)"
        case .timeout:
            return "Не удалось получить данные торрента: нет пиров или ссылка неверна."
        case .noVideo:
            return "В торренте нет видеофайлов."
        }
    }
}

// MARK: - Embedded TorrServer (MatriX) wrapper

final class TorrServer {
    static let shared = TorrServer()

    let port = 8090
    var base: String { "http://127.0.0.1:\(port)" }

    private let queue = DispatchQueue(label: "kinoteka.torrserver", qos: .userInitiated)
    private let lock = NSLock()
    private var lastError: String?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    var startError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastError
    }

    var isRunning: Bool { TorrserverkitIsRunning() }

    static var dataDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// TorrServer writes its log here and also sends the process's stdout/stderr to it,
    /// so Go panics and Swift runtime errors of the previous run end up in this file.
    static var logFile: URL { dataDirectory.appendingPathComponent("torrserver.log") }

    /// Pieces of the playing torrents (the disk cache of EngineProfile).
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrServerCache", isDirectory: true)
    }

    private var logPrepared = false

    /// Must be called on `queue`.
    ///
    /// TorrServer cannot be stopped and started again inside one process: its stop
    /// closes the settings database but keeps using it, so the next start crashes the
    /// whole app in Go. The engine is therefore only ever started when it is not running.
    private func startOnQueue() {
        guard !TorrserverkitIsRunning() else { return }
        if !logPrepared {
            logPrepared = true
            EngineLog.inspectPreviousRun(TorrServer.logFile)
            prepareFirstStart()
        }
        let started = Date()
        let message = TorrserverkitStartServer(port, TorrServer.dataDirectory.path)
        lock.lock()
        lastError = message.isEmpty ? nil : message
        lock.unlock()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AppDiagnostics.shared.log("torrent", message.isEmpty ? "Движок запущен за \(elapsed) мс" : "Движок не запустился: \(message)")
    }

    func start() {
        queue.async {
            self.startOnQueue()
        }
    }

    private func onQueue(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }

    func ping() async -> Bool {
        guard let url = URL(string: base + "/echo") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func waitForPing(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await ping() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        return false
    }

    /// Makes sure the local HTTP server answers (iOS may break the socket after a long
    /// suspension) and the engine is tuned (EngineProfile) before torrents are added.
    ///
    /// `applyNetworkChanges`: retuning for another network (Wi‑Fi ↔ mobile) makes the engine
    /// close all its torrents, so only callers that start a new playback pass true; the first
    /// check after the start is always made.
    func ensureRunning(applyNetworkChanges: Bool = false) async throws {
        try await startIfNeeded()
        await applyProfile(allowChange: applyNetworkChanges)
    }

    private func startIfNeeded() async throws {
        if await waitForPing(seconds: 1.5) { return }
        for attempt in 1...2 {
            // Only starts when the engine is not running (its HTTP server stopped).
            await onQueue { self.startOnQueue() }
            if await waitForPing(seconds: attempt == 1 ? 10 : 15) { return }
            if Task.isCancelled { throw CancellationError() }
        }
        let reason: String
        if isRunning {
            reason = "движок не отвечает. Закройте Кинотеку в переключателе приложений и откройте снова."
        } else {
            reason = startError ?? "сервер не отвечает"
        }
        AppDiagnostics.shared.log("torrent", "Движок недоступен: \(reason)")
        throw TorrServerError.notRunning(reason)
    }

    // MARK: Engine profile

    private var appliedProfile: EngineProfile?
    private var profileVerified = false
    private var profileTask: Task<Void, Never>?
    private var loggedProfile: EngineProfile?
    private var playerActive = false
    private var measuredFreeSpace: Int64??

    /// The player is open: the engine must not be retuned (that closes its torrents) by
    /// anything else than the player itself.
    var isPlayerActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return playerActive
    }

    func setPlayerActive(_ active: Bool) {
        lock.lock()
        playerActive = active
        lock.unlock()
    }

    /// The profile the engine runs with; nil until it is checked after the start.
    var activeProfile: EngineProfile? {
        lock.lock()
        defer { lock.unlock() }
        return appliedProfile
    }

    /// The profile for the network and the device right now.
    var desiredProfile: EngineProfile { EngineProfile.make(environment()) }

    private func environment(waitForNetwork: Bool = false) -> EngineEnvironment {
        let network = waitForNetwork
            ? NetworkState.shared.wait(timeout: 0.5)
            : (NetworkState.shared.current ?? NetworkState.reachabilitySnapshot())
        let mode = EngineEncryptionMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.engineEncryption) ?? "") ?? .automatic
        return EngineEnvironment(connection: network.connection,
                                 isExpensive: network.isExpensive,
                                 isConstrained: network.isConstrained,
                                 supportsIPv6: network.supportsIPv6,
                                 freeBytes: freeSpace(),
                                 cachePath: TorrServer.cacheDirectory.path,
                                 encryption: mode)
    }

    /// Measured once per run: the cache takes space itself and must not shrink its own size.
    private func freeSpace() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        if let measured = measuredFreeSpace { return measured }
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage
        measuredFreeSpace = .some(free)
        return free
    }

    /// Before the first start in this process (on `queue`): the disk cache is emptied (pieces
    /// left by an earlier run could be taken for complete ones), the extra trackers are written,
    /// and the saved engine settings get the profile of the current network, so the engine starts
    /// tuned instead of reconnecting when the first torrent is added.
    private func prepareFirstStart() {
        let manager = FileManager.default
        let cache = TorrServer.cacheDirectory
        // Before the free space is measured for the size of the new cache.
        try? manager.removeItem(at: cache)
        try? manager.createDirectory(at: cache, withIntermediateDirectories: true)
        let trackers = EngineProfile.trackers.joined(separator: "\n") + "\n"
        try? Data(trackers.utf8).write(to: TorrServer.dataDirectory.appendingPathComponent("trackers.txt"), options: .atomic)
        presetSettingsFile(EngineProfile.make(environment(waitForNetwork: true)))
    }

    /// TorrServer keeps its settings in settings.json of its folder (written by an earlier run).
    private func presetSettingsFile(_ profile: EngineProfile) {
        let file = TorrServer.dataDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: file),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sets = root["BitTorr"] as? [String: Any] else { return }
        let changes = profile.changes(from: sets)
        guard !changes.isEmpty else { return }
        root["BitTorr"] = profile.merged(into: sets)
        guard JSONSerialization.isValidJSONObject(root),
              let output = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]),
              (try? output.write(to: file, options: .atomic)) != nil else { return }
        AppDiagnostics.shared.log("torrent", "Профиль задан до запуска движка: \(changes.joined(separator: ", "))")
    }

    private func applyProfile(allowChange: Bool) async {
        let env = environment()
        let desired = EngineProfile.make(env)
        guard let task = profileTaskToAwait(desired, allowChange: allowChange && env.connection != .offline) else { return }
        await task.value
    }

    /// The task checking or applying the profile (shared by the callers), or nil when nothing is needed.
    private func profileTaskToAwait(_ desired: EngineProfile, allowChange: Bool) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let running = profileTask { return running }
        if profileVerified && (!allowChange || appliedProfile == desired) { return nil }
        // Not checked yet (the check failed): retuning closes the torrents, so it waits for
        // a new playback while a film plays.
        if !profileVerified && !allowChange && playerActive { return nil }
        let task = Task { await self.verifyAndApply(desired) }
        profileTask = task
        return task
    }

    /// Changing settings makes TorrServer drop its torrents and reconnect its client, so it is done
    /// only when the engine runs with other values, and every caller waits for it.
    private func verifyAndApply(_ profile: EngineProfile) async {
        guard let data = try? await post(["action": "get"], path: "/settings"),
              let sets = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            finishProfile(nil)
            return
        }
        let changes = profile.changes(from: sets)
        guard !changes.isEmpty else {
            finishProfile(profile)
            return
        }
        let started = Date()
        let saved = (try? await post(["action": "set", "sets": profile.merged(into: sets)], path: "/settings")) != nil
        if saved {
            // The engine has closed its torrents and reconnected.
            _ = await waitForPing(seconds: 10)
            await TorrentWarmup.shared.engineDidReset()
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AppDiagnostics.shared.log("torrent", saved
            ? "Движок перенастроен за \(elapsed) мс: \(changes.joined(separator: ", "))"
            : "Настройки движка не сохранились")
        finishProfile(saved ? profile : nil)
    }

    private func finishProfile(_ profile: EngineProfile?) {
        lock.lock()
        if let profile = profile {
            appliedProfile = profile
            profileVerified = true
        }
        profileTask = nil
        let log = profile != nil && profile != loggedProfile
        if log { loggedProfile = profile }
        lock.unlock()
        if log, let profile = profile {
            AppDiagnostics.shared.log("torrent", "Профиль движка: \(profile.summary)")
        }
    }

    // MARK: Torrents

    private func post(_ body: [String: Any], path: String = "/torrents") async throws -> Data {
        guard let url = URL(string: base + path) else { throw TorrServerError.server("bad url") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8)?.trimmed ?? ""
            throw TorrServerError.server(text.isEmpty ? "HTTP \(code)" : String(text.prefix(200)))
        }
        return data
    }

    private func decodeStatus(_ data: Data) throws -> TSStatus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TSStatus.self, from: data)
    }

    /// Adds a torrent (or returns the one already added). Torrents saved to the engine's database
    /// keep their metadata, so opening them again does not wait for peers to send it.
    func add(link: String, title: String, poster: String?, saveToDB: Bool = true) async throws -> TSStatus {
        var body: [String: Any] = ["action": "add", "link": link, "title": title, "save_to_db": saveToDB]
        if let poster = poster { body["poster"] = poster }
        return try decodeStatus(try await post(body))
    }

    func get(hash: String) async throws -> TSStatus {
        try decodeStatus(try await post(["action": "get", "hash": hash]))
    }

    func drop(hash: String) async {
        _ = try? await post(["action": "drop", "hash": hash])
    }

    func wipe() async {
        _ = try? await post(["action": "wipe"])
    }

    /// Polls the torrent until its file list (metadata) is known: often at first
    /// (a prepared torrent is ready at once), then less often.
    func waitForFiles(hash: String, timeout: TimeInterval = 120, progress: @escaping @MainActor (TSStatus) -> Void) async throws -> [TorrentFile] {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await get(hash: hash)
            await progress(status)
            let files = status.files
            if !files.isEmpty { return files }
            attempt += 1
            try await Task.sleep(nanoseconds: attempt < 20 ? 250_000_000 : 600_000_000)
        }
        throw TorrServerError.timeout
    }

    func streamURL(hash: String, file: TorrentFile) -> URL? {
        let ext = file.ext.isEmpty ? "mkv" : file.ext
        var comps = URLComponents(string: base + "/stream/video." + ext)
        comps?.queryItems = [
            URLQueryItem(name: "link", value: hash),
            URLQueryItem(name: "index", value: String(file.id)),
            URLQueryItem(name: "play", value: nil)
        ]
        return comps?.url
    }

    /// Reads a tiny range of the next episode so TorrServer starts requesting
    /// its pieces before the current episode ends. Best effort only.
    func prefetch(hash: String, file: TorrentFile, bytes: Int = 256 * 1024) async {
        guard bytes > 0, let url = streamURL(hash: hash, file: file) else { return }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            AppDiagnostics.shared.log("torrent", "Подготовлена следующая серия, HTTP \(code)")
        } catch {
            if !Task.isCancelled {
                AppDiagnostics.shared.log("torrent", "Подготовка серии не удалась: \(error.localizedDescription)")
            }
        }
    }

    /// Reads a range of the file through the engine, so it downloads those pieces now: the start
    /// and the end of the film the open page will play. Returns the bytes read.
    func readAhead(hash: String, file: TorrentFile, offset: Int64, length: Int64, idleTimeout: TimeInterval = 20) async -> Int64 {
        guard length > 0, offset >= 0, offset < file.length, let url = streamURL(hash: hash, file: file) else { return 0 }
        let last = min(file.length, offset + length) - 1
        var request = URLRequest(url: url, timeoutInterval: idleTimeout)
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await session.data(for: request)
            return Int64(data.count)
        } catch {
            return 0
        }
    }
}
