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

struct TorrentFile: Identifiable, Hashable {
    let id: Int
    let path: String
    let length: Int64

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var isVideo: Bool { TorrentFile.videoExtensions.contains(ext) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: length, countStyle: .file) }

    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "mts", "wmv", "flv", "webm",
        "mpg", "mpeg", "vob", "3gp", "ogv", "divx", "rmvb", "asf"
    ]
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

    private func post(_ body: [String: Any]) async throws -> Data {
        guard let url = URL(string: base + "/torrents") else { throw TorrServerError.server("bad url") }
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

    func add(link: String, title: String, poster: String?) async throws -> TSStatus {
        var body: [String: Any] = ["action": "add", "link": link, "title": title, "save_to_db": true]
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

    /// Polls the torrent until its file list (metadata) is known.
    func waitForFiles(hash: String, timeout: TimeInterval = 120, progress: @escaping @MainActor (TSStatus) -> Void) async throws -> [TorrentFile] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try await get(hash: hash)
            await progress(status)
            let files = status.files
            if !files.isEmpty { return files }
            try await Task.sleep(nanoseconds: 700_000_000)
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

// MARK: - Links

enum LinkKind {
    case torrent
    case direct
}

enum LinkInspector {
    static func isInfoHash(_ text: String) -> Bool {
        let s = text.trimmed
        return s.count == 40 && s.allSatisfy { $0.isHexDigit }
    }

    static func kind(of link: String) -> LinkKind {
        let s = link.trimmed
        let lower = s.lowercased()
        if lower.hasPrefix("magnet:") || isInfoHash(s) { return .torrent }
        if let url = URL(string: s), url.pathExtension.lowercased() == "torrent" { return .torrent }
        if lower.contains(".torrent?") { return .torrent }
        return .direct
    }

    static func isSupported(_ link: String) -> Bool {
        let s = link.trimmed
        if s.lowercased().hasPrefix("magnet:") || isInfoHash(s) { return true }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "rtmp", "rtsp", "rtp", "udp", "ftp", "smb", "mms"].contains(scheme)
    }

    static func kindText(_ link: String) -> String {
        switch kind(of: link) {
        case .torrent: return "Торрент"
        case .direct:
            let lower = link.lowercased()
            if lower.contains(".m3u8") { return "HLS-поток" }
            return "Прямая ссылка"
        }
    }
}

enum SourceNaming {
    static func defaultName(for link: String) -> String {
        let s = link.trimmed
        if s.lowercased().hasPrefix("magnet:") {
            if let comps = URLComponents(string: s),
               let dn = comps.queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value,
               !dn.isEmpty {
                return dn.replacingOccurrences(of: "+", with: " ")
            }
            return "Торрент"
        }
        if LinkInspector.isInfoHash(s) {
            return "Торрент " + String(s.prefix(8)).lowercased()
        }
        if let url = URL(string: s) {
            let file = url.lastPathComponent
            let host = url.host ?? ""
            if !file.isEmpty && file != "/" {
                return host.isEmpty ? file : "\(file) · \(host)"
            }
            if !host.isEmpty { return host }
        }
        return "Источник"
    }
}

// MARK: - Episode matching in torrent file names

enum EpisodeMatcher {
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            groups.append(range.location == NSNotFound ? "" : ns.substring(with: range))
        }
        return groups
    }

    /// Season and episode numbers parsed from a file name.
    static func parse(_ path: String) -> (season: Int?, episode: Int)? {
        let name = (path as NSString).lastPathComponent
        let paired = [
            "s(\\d{1,2})[ ._-]*e(\\d{1,3})",
            "(?<!\\d)(\\d{1,2})x(\\d{1,3})(?!\\d)",
            "season[ ._-]*(\\d{1,2}).*?episode[ ._-]*(\\d{1,3})",
            "(\\d{1,2})[ ._-]*сезон.*?(\\d{1,3})[ ._-]*сери",
            "сезон[ ._-]*(\\d{1,2}).*?(\\d{1,3})[ ._-]*сери",
            "сезон[ ._-]*(\\d{1,2}).*?сери[яи]?[ ._-]*(\\d{1,3})"
        ]
        for pattern in paired {
            if let g = firstMatch(pattern, in: name), g.count >= 2, let s = Int(g[0]), let e = Int(g[1]) {
                return (s, e)
            }
        }
        let single = [
            "(?<![a-zа-я])(?:ep|e)[ ._-]?(\\d{1,3})(?!\\d)",
            "(\\d{1,3})[ ._-]*(?:серия|seriya|series)",
            "(?:серия|seriya|episode)[ ._-]*(\\d{1,3})",
            "^(\\d{1,3})(?!\\d)"
        ]
        for pattern in single {
            if let g = firstMatch(pattern, in: name), let first = g.first, let e = Int(first) {
                return (nil, e)
            }
        }
        return nil
    }

    /// Season number mentioned in the folder part of the path ("Season 2", "S02", "2 сезон").
    static func folderSeason(_ path: String) -> Int? {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty else { return nil }
        let patterns = ["season[ ._-]*(\\d{1,2})", "(?<![a-z])s(\\d{1,2})(?!\\d)", "(\\d{1,2})[ ._-]*сезон", "сезон[ ._-]*(\\d{1,2})"]
        for pattern in patterns {
            if let g = firstMatch(pattern, in: folder), let first = g.first, let s = Int(first) { return s }
        }
        return nil
    }

    static func find(in files: [TorrentFile], season: Int?, episode: Int) -> TorrentFile? {
        let parsed = files.map { file -> (TorrentFile, Int?, Int?) in
            let p = parse(file.path)
            return (file, p?.season ?? folderSeason(file.path), p?.episode)
        }
        if let season = season,
           let exact = parsed.first(where: { $0.1 == season && $0.2 == episode }) {
            return exact.0
        }
        let seasons = Set(parsed.compactMap { $0.1 })
        if seasons.count <= 1, let loose = parsed.first(where: { $0.2 == episode }) {
            return loose.0
        }
        return nil
    }

    static func sorted(_ files: [TorrentFile]) -> [TorrentFile] {
        files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
