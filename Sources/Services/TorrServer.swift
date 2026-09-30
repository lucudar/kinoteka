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
        ByteCountFormatter.string(fromByteCount: Int64(downloadSpeed ?? 0), countStyle: .file) + "/с"
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

    private var dataDirectory: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrServer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Must be called on `queue`.
    private func startOnQueue() {
        let message = TorrserverkitStartServer(port, dataDirectory)
        lock.lock()
        lastError = message.isEmpty ? nil : message
        lock.unlock()
    }

    func start() {
        queue.async {
            if !TorrserverkitIsRunning() {
                self.startOnQueue()
            }
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
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func waitForPing(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if await ping() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Makes sure the local HTTP server answers (iOS may break the socket after a long suspension).
    func ensureRunning() async throws {
        try await startIfNeeded()
        await applyPreferredSettings()
    }

    private func startIfNeeded() async throws {
        if await waitForPing(attempts: 6) { return }
        await onQueue {
            if !TorrserverkitIsRunning() { self.startOnQueue() }
        }
        if await waitForPing(attempts: 24) { return }
        await onQueue {
            _ = TorrserverkitStopServer()
            Thread.sleep(forTimeInterval: 0.5)
            self.startOnQueue()
        }
        if await waitForPing(attempts: 40) { return }
        throw TorrServerError.notRunning(startError ?? "сервер не отвечает")
    }

    // MARK: Engine settings

    /// Seconds a torrent stays connected after the player stops reading it (TorrServer default: 30).
    /// Long enough to reopen the film or pick another episode without reconnecting to peers.
    static let keepAliveSeconds = 180

    private var settingsState = 0 // 0: not checked, 1: checking, 2: done

    private func beginSettingsCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard settingsState == 0 else { return false }
        settingsState = 1
        return true
    }

    private func endSettingsCheck(done: Bool) {
        lock.lock()
        settingsState = done ? 2 : 0
        lock.unlock()
    }

    /// Applied once: TorrServer keeps its settings in its own database.
    /// Changing settings restarts the engine's torrents, so it is done only when needed.
    private func applyPreferredSettings() async {
        guard beginSettingsCheck() else { return }
        var done = false
        defer { endSettingsCheck(done: done) }
        guard let data = try? await post(["action": "get"], path: "/settings"),
              var sets = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let timeout = (sets["TorrentDisconnectTimeout"] as? NSNumber)?.intValue ?? 0
        guard timeout < TorrServer.keepAliveSeconds else {
            done = true
            return
        }
        sets["TorrentDisconnectTimeout"] = TorrServer.keepAliveSeconds
        if (try? await post(["action": "set", "sets": sets], path: "/settings")) != nil {
            done = true
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
}
