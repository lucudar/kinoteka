import Foundation
import CryptoKit

enum APIError: LocalizedError {
    case noToken
    case http(Int)
    case limit
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Добавьте ключ API Кинопоиска: Моё → Настройки."
        case .http(let code):
            if code == 401 { return "Ключ API Кинопоиска не подходит. Проверьте его в настройках." }
            if code == 404 { return "Ничего не найдено." }
            return "Ошибка сервера (\(code)). Попробуйте позже."
        case .limit:
            return "Дневной лимит запросов к Кинопоиску исчерпан. Уже загруженное доступно из кэша."
        case .invalidURL:
            return "Некорректный адрес запроса."
        }
    }
}

/// Coalesces identical requests made by several rows/screens at the same time.
private actor KPRequestPool {
    private struct Payload: Sendable {
        let data: Data
        let statusCode: Int
    }

    private var tasks: [String: Task<Payload, Error>] = [:]

    func fetch(_ request: URLRequest, using session: URLSession) async throws -> (Data, Int) {
        let key = request.url?.absoluteString ?? UUID().uuidString
        if let task = tasks[key] {
            let payload = try await task.value
            return (payload.data, payload.statusCode)
        }

        let task = Task<Payload, Error> {
            let (data, response) = try await session.data(for: request)
            return Payload(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        tasks[key] = task
        do {
            let payload = try await task.value
            tasks.removeValue(forKey: key)
            return (payload.data, payload.statusCode)
        } catch {
            tasks.removeValue(forKey: key)
            throw error
        }
    }
}

/// Client for kinopoiskapiunofficial.tech with a simple on-disk cache
/// (the free plan allows 500 requests per day).
final class KPClient {
    static let shared = KPClient()

    enum TTL {
        static let hours: TimeInterval = 60 * 60 * 6
        static let day: TimeInterval = 60 * 60 * 24
        static let week: TimeInterval = 60 * 60 * 24 * 7
        static let month: TimeInterval = 60 * 60 * 24 * 30
    }

    private let base = "https://kinopoiskapiunofficial.tech"
    private let session: URLSession
    private let requests = KPRequestPool()
    private let cacheDir: URL

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("kp-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    var token: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.kpToken) ?? "").trimmed
    }

    var hasToken: Bool { !token.isEmpty }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(name + ".json")
    }

    private func cached<T: Decodable>(_ file: URL, maxAge: TimeInterval?) -> T? {
        if let maxAge = maxAge {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let date = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(date) < maxAge else { return nil }
        }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, query: [(String, String)] = [], ttl: TimeInterval = TTL.day) async throws -> T {
        guard var comps = URLComponents(string: base + path) else { throw APIError.invalidURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = comps.url else { throw APIError.invalidURL }
        let file = cacheFile(for: url)

        if let fresh: T = cached(file, maxAge: ttl) {
            return fresh
        }
        let key = token
        guard !key.isEmpty else {
            if let stale: T = cached(file, maxAge: nil) { return stale }
            throw APIError.noToken
        }

        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, code) = try await requests.fetch(request, using: session)
            if code == 402 || code == 429 { throw APIError.limit }
            guard (200..<300).contains(code) else { throw APIError.http(code) }
            let value = try JSONDecoder().decode(T.self, from: data)
            try? data.write(to: file, options: .atomic)
            return value
        } catch {
            if let stale: T = cached(file, maxAge: nil) { return stale }
            throw error
        }
    }

    // MARK: - Endpoints

    func collection(_ type: String, page: Int = 1) async throws -> KPPage {
        try await get("/api/v2.2/films/collections", query: [("type", type), ("page", String(page))], ttl: TTL.day)
    }

    func films(_ filter: CatalogFilter, page: Int) async throws -> KPPage {
        try await get("/api/v2.2/films", query: filter.query + [("page", String(page))], ttl: TTL.day)
    }

    func search(_ keyword: String, page: Int = 1) async throws -> KPPage {
        try await get("/api/v2.1/films/search-by-keyword", query: [("keyword", keyword), ("page", String(page))], ttl: TTL.day)
    }

    func film(_ id: Int) async throws -> KPFilm {
        try await get("/api/v2.2/films/\(id)", ttl: TTL.week)
    }

    func seasons(_ id: Int) async throws -> [KPSeason] {
        let result: KPSeasons = try await get("/api/v2.2/films/\(id)/seasons", ttl: TTL.day)
        return KPSeason.merged(result.items)
    }

    func staff(_ id: Int) async throws -> [KPStaff] {
        try await get("/api/v1/staff", query: [("filmId", String(id))], ttl: TTL.month)
    }

    func similars(_ id: Int) async throws -> [MediaItem] {
        let page: KPPage = try await get("/api/v2.2/films/\(id)/similars", ttl: TTL.month)
        return page.items
    }

    func videos(_ id: Int) async throws -> [KPVideo] {
        let result: KPVideos = try await get("/api/v2.2/films/\(id)/videos", ttl: TTL.month)
        return result.items
    }

    func filters() async throws -> KPFilters {
        try await get("/api/v2.2/films/filters", ttl: TTL.month)
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    var cacheSizeText: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}
