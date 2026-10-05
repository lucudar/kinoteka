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

    /// The engine has no torrent client: it did not reconnect after its settings were saved.
    var isClientMissing: Bool {
        if case .server(let text) = self { return text.contains("not connected") }
        return false
    }
}

/// Resumes a continuation once: by the work or by its timeout, whichever comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Embedded TorrServer (MatriX) wrapper

final class TorrServer {
    static let shared = TorrServer()

    /// Not TorrServer's usual 8090: all apps share 127.0.0.1, and another app with the engine
    /// may hold that port. The next ones are tried when one is busy.
    static let ports = [48090, 48091, 48092, 48093, 48094]

    var port: Int {
        lock.lock()
        defer { lock.unlock() }
        return serverPort
    }

    var base: String { "http://127.0.0.1:\(port)" }

    private let queue = DispatchQueue(label: "kinoteka.torrserver", qos: .userInitiated)
    private let lock = NSLock()
    private var lastError: String?
    private var serverPort = TorrServer.ports[0]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // The requests set their own timeouts; saving settings waits for the reconnect.
        config.timeoutIntervalForRequest = 120
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
            TorrServer.raiseOpenFileLimit()
            prepareFirstStart()
        }
        let started = Date()
        var message = ""
        var used = TorrServer.ports[0]
        for candidate in TorrServer.ports {
            used = candidate
            message = TorrserverkitStartServer(candidate, TorrServer.dataDirectory.path)
            guard TorrServer.isPortBusy(message) else { break }
            AppDiagnostics.shared.log("torrent", "Порт \(candidate) занят: \(message)")
        }
        lock.lock()
        if message.isEmpty { serverPort = used }
        lastError = message.isEmpty ? nil : message
        lock.unlock()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        AppDiagnostics.shared.log("torrent", message.isEmpty
            ? "Движок запущен за \(elapsed) мс, порт \(used)"
            : "Движок не запустился: \(message)")
    }

    private static func isPortBusy(_ message: String) -> Bool {
        message.contains("already in use") || message.contains("cannot bind HTTP port")
    }

    /// Each peer connection, tracker request and piece file of the disk cache is an open file;
    /// iOS starts an app with a limit of 256 of them.
    private static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, rlim_t(10240))
        if limit.rlim_cur < wanted {
            var raised = limit
            raised.rlim_cur = wanted
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { limit = raised }
        }
        AppDiagnostics.shared.log("torrent", "Лимит открытых файлов: \(limit.rlim_cur)")
    }

    func start() {
        queue.async {
            self.startOnQueue()
        }
    }

    /// At the launch: the engine starts and its profile is checked while nothing plays yet,
    /// so the first film page does not wait for the engine to be retuned.
    func launch() {
        start()
        Task.detached(priority: .utility) {
            try? await self.ensureRunning()
        }
    }

    /// Runs `work` on the engine queue; false when it has not finished in `timeout` seconds
    /// (the start of the engine hangs), so the caller reports it instead of waiting forever.
    private func onQueue(timeout: TimeInterval, _ work: @escaping () -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            queue.async {
                work()
                once.resume(true)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                once.resume(false)
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
    /// `retune`: the caller is about to add a torrent while nothing plays (a film page, the
    /// network check, a new encryption choice), so the engine may be retuned for the network
    /// it is on now. Retuning makes TorrServer close every torrent and reconnect its client,
    /// so it never happens while a film plays: the player only waits for a retune in progress
    /// (and for the first check after the start).
    func ensureRunning(retune: Bool = false) async throws {
        try await startIfNeeded()
        await applyProfile(retune: retune)
    }

    /// A film page is open: the engine is started and retuned for the current network,
    /// also when its release is not prepared in advance.
    func prepareForPage() async {
        guard !isPlayerActive else { return }
        try? await ensureRunning(retune: true)
    }

    private func startIfNeeded() async throws {
        if await waitForPing(seconds: 1.5) { return }
        for attempt in 1...2 {
            // Only starts when the engine is not running (its HTTP server stopped).
            if !(await onQueue(timeout: 30, { self.startOnQueue() })) {
                AppDiagnostics.shared.log("torrent", "Запуск движка не закончился за 30 с")
            }
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
    /// Checking, applying or re-saving the settings; every engine call waits for it.
    private var profileTask: Task<Void, Never>?
    private var loggedProfile: EngineProfile?
    private var playerActive = false
    private var measuredFreeSpace: Int64??
    private var lastReconnect: Date?

    /// The player is open: the engine must not be retuned (that closes its torrents).
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
        let mode = EngineEncryptionMode.stored(UserDefaults.standard.string(forKey: SettingsKeys.engineEncryption))
        return EngineEnvironment(connection: network.connection,
                                 isExpensive: network.isExpensive,
                                 isConstrained: network.isConstrained,
                                 freeBytes: freeSpace(),
                                 cachePath: TorrServer.cacheDirectory.path,
                                 encryption: mode)
    }

    /// Measured once per run (the cache takes space itself and must not shrink its own size),
    /// outside the lock. It is the space free now, without the files iOS could purge later:
    /// the cache is written at once.
    private func freeSpace() -> Int64? {
        lock.lock()
        let measured = measuredFreeSpace
        lock.unlock()
        if let measured = measured { return measured }
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let free = values?.volumeAvailableCapacity.map { Int64($0) }
        lock.lock()
        defer { lock.unlock() }
        if measuredFreeSpace == nil { measuredFreeSpace = .some(free) }
        return measuredFreeSpace ?? free
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

    private func applyProfile(retune: Bool) async {
        let env = environment()
        let desired = EngineProfile.make(env)
        guard let task = profileTaskToAwait(desired, retune: retune && env.connection != .offline) else { return }
        await task.value
    }

    /// The task checking or applying the profile (shared by the callers), or nil when nothing is needed.
    private func profileTaskToAwait(_ desired: EngineProfile, retune: Bool) -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let running = profileTask { return running }
        if profileVerified {
            // Another network or encryption choice: only when nothing plays.
            guard retune, !playerActive, appliedProfile != desired else { return nil }
        } else if playerActive && !retune {
            // Not checked yet (the check failed): a film may play now, the check waits for
            // a new playback.
            return nil
        }
        let task = Task { await self.verifyAndApply(desired) }
        profileTask = task
        return task
    }

    /// Engine calls wait while the settings are checked or saved: during a retune TorrServer
    /// has no torrent client, and a torrent added at that moment could crash the engine.
    private func waitForProfileTask() async {
        lock.lock()
        let task = profileTask
        lock.unlock()
        if let task = task { await task.value }
    }

    /// Changing settings makes TorrServer drop its torrents and reconnect its client, so it is done
    /// only when the engine runs with other values.
    private func verifyAndApply(_ profile: EngineProfile) async {
        guard let sets = await engineSettings() else {
            AppDiagnostics.shared.log("torrent", "Настройки движка не прочитались")
            finishProfile(nil)
            return
        }
        let changes = profile.changes(from: sets)
        guard !changes.isEmpty else {
            finishProfile(profile)
            return
        }
        let saved = await saveSettings(profile.merged(into: sets), reason: changes.joined(separator: ", "))
        finishProfile(saved ? profile : nil)
    }

    private func engineSettings() async -> [String: Any]? {
        guard let data = try? await post(["action": "get"], path: "/settings", waitForProfile: false) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// TorrServer closes every torrent, saves the settings and reconnects its torrent client
    /// (several seconds, up to half a minute when its peer port is still busy), then answers.
    private func saveSettings(_ sets: [String: Any], reason: String) async -> Bool {
        await TorrentWarmup.shared.engineWillReset()
        let started = Date()
        var saved = false
        do {
            _ = try await post(["action": "set", "sets": sets], path: "/settings", timeout: 120, waitForProfile: false)
            saved = true
        } catch {
            AppDiagnostics.shared.log("torrent", "Настройки движка не сохранились: \(error.localizedDescription)")
        }
        _ = await waitForPing(seconds: 10)
        if saved {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            AppDiagnostics.shared.log("torrent", "Движок перенастроен за \(elapsed) мс: \(reason)")
        }
        return saved
    }

    /// The torrent client is missing (a reconnect of the engine failed): saving the same settings
    /// makes TorrServer connect it again. Shared by the callers, at most once in 20 seconds.
    private func reconnectClient() async {
        lock.lock()
        var task = profileTask
        if task == nil, lastReconnect.map({ Date().timeIntervalSince($0) > 20 }) ?? true {
            lastReconnect = Date()
            let created = Task { await self.resaveSettings() }
            profileTask = created
            task = created
        }
        lock.unlock()
        if let task = task { await task.value }
    }

    private func resaveSettings() async {
        if let sets = await engineSettings() {
            _ = await saveSettings(sets, reason: "переподключение торрент-клиента")
        }
        finishProfile(nil)
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

    private func post(_ body: [String: Any], path: String = "/torrents", timeout: TimeInterval = 60,
                      waitForProfile: Bool = true) async throws -> Data {
        if waitForProfile { await waitForProfileTask() }
        guard let url = URL(string: base + path) else { throw TorrServerError.server("bad url") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TorrServerError.server(TorrServer.errorText(data, code: code))
        }
        return data
    }

    /// TorrServer answers an error as {"error": "…"} or as plain text.
    private static func errorText(_ data: Data, code: Int) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = (object["error"] as? String)?.trimmed, !message.isEmpty {
            return String(message.prefix(200))
        }
        let text = String(data: data, encoding: .utf8)?.trimmed ?? ""
        return text.isEmpty ? "HTTP \(code)" : String(text.prefix(200))
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
        let started = Date()
        do {
            let status = try decodeStatus(try await post(body))
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 3 {
                AppDiagnostics.shared.log("torrent", "Раздача добавлена за \(Int(elapsed * 1000)) мс")
            }
            return status
        } catch let error as TorrServerError where error.isClientMissing {
            AppDiagnostics.shared.log("torrent", "Торрент-клиент движка не подключён, переподключение")
            await reconnectClient()
            do {
                return try decodeStatus(try await post(body))
            } catch let again as TorrServerError where again.isClientMissing {
                AppDiagnostics.shared.log("torrent", "Торрент-клиент движка так и не подключился")
                throw TorrServerError.notRunning("торрент-клиент не подключился к сети. Закройте Кинотеку в переключателе приложений и откройте снова.")
            }
        } catch {
            if !Task.isCancelled {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                AppDiagnostics.shared.log("torrent", "Раздача не добавлена (\(elapsed) мс): \(error.localizedDescription)")
            }
            throw error
        }
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
        await waitForProfileTask()
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
        await waitForProfileTask()
        guard !Task.isCancelled, length > 0, offset >= 0, offset < file.length,
              let url = streamURL(hash: hash, file: file) else { return 0 }
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
