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
    let connectedSeeders: Int?
    let downloadSpeed: Double?
    let preloadedBytes: Int64?
    let preloadSize: Int64?
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

    var speedText: String {
        let value = downloadSpeed ?? 0
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
    /// suspension) and the app's engine settings are applied before torrents are added.
    func ensureRunning() async throws {
        try await startIfNeeded()
        await applySettingsOnce()
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

    // MARK: Engine settings

    /// Seconds a torrent stays connected after the player stops reading it (TorrServer default: 30).
    /// Long enough to reopen the film or pick another episode without reconnecting to peers.
    static let keepAliveSeconds = 180

    private var settingsApplied = false
    private var settingsTask: Task<Void, Never>?

    /// Changing settings makes TorrServer drop its torrents and reconnect its client, so it
    /// is done once, and every caller waits for it before adding a torrent.
    private func applySettingsOnce() async {
        guard let task = settingsTaskToAwait() else { return }
        await task.value
    }

    /// The task applying the settings (started by the first caller), or nil once applied.
    private func settingsTaskToAwait() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if settingsApplied { return nil }
        if let existing = settingsTask { return existing }
        let task = Task { await self.applyPreferredSettings() }
        settingsTask = task
        return task
    }

    private func finishSettings(applied: Bool) {
        lock.lock()
        settingsApplied = applied
        settingsTask = nil
        lock.unlock()
    }

    /// TorrServer keeps its settings in its own database.
    private func applyPreferredSettings() async {
        guard let data = try? await post(["action": "get"], path: "/settings"),
              var sets = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            finishSettings(applied: false)
            return
        }
        var changes: [String] = []
        let timeout = (sets["TorrentDisconnectTimeout"] as? NSNumber)?.intValue ?? 0
        if timeout < TorrServer.keepAliveSeconds {
            sets["TorrentDisconnectTimeout"] = TorrServer.keepAliveSeconds
            changes.append("удержание \(TorrServer.keepAliveSeconds) с")
        }
        // Discovery of other devices is not needed inside the app; it only adds
        // multicast traffic and work while the phone plays.
        for key in ["EnableBonjour", "EnableLPD", "EnableDLNA"] where (sets[key] as? Bool) == true {
            sets[key] = false
            changes.append(key)
        }
        guard !changes.isEmpty else {
            finishSettings(applied: true)
            return
        }
        let saved = (try? await post(["action": "set", "sets": sets], path: "/settings")) != nil
        AppDiagnostics.shared.log("torrent", saved ? "Настройки движка: \(changes.joined(separator: ", "))" : "Настройки движка не сохранились")
        finishSettings(applied: saved)
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
}
