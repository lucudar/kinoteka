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
///
/// The API is hosted abroad: on Russian networks without a VPN it is often slowed down until an
/// answer stalls. Lists, film pages and people then come from Zona's index (ZonaCatalog, hosted in
/// Russia), as they do without a key: when the API fails, when it is slow (the index is asked too
/// after a few seconds and the first answer wins) and for a while after that.
final class KPClient: @unchecked Sendable {
    static let shared = KPClient()
    static let host = "kinopoiskapiunofficial.tech"

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
    /// An answer slower than this makes Zona's index asked as well.
    private let hedgeDelay: TimeInterval = 4
    private let lock = NSLock()
    /// The key the API refused (wrong key, the daily limit) and until when: the index is used
    /// instead. Another key is tried at once.
    private var refused: (key: String, until: Date, limit: Bool)?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
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

    /// The answer for the path: a fresh cached one, otherwise from the API; `fallback` (Zona's
    /// index) answers without a key, when the API fails or is slow and while it is marked down.
    func get<T: Decodable & Sendable>(_ path: String, query: [(String, String)] = [], ttl: TimeInterval = TTL.day,
                                      fallback: (@Sendable () async throws -> T)? = nil) async throws -> T {
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
        let fallback = ZonaCatalog.isEnabled ? fallback : nil
        let skipAPI = key.isEmpty || isRefused(key) || HostHealth.shared.isDown(KPClient.host)
        if skipAPI, let fallback = fallback {
            do {
                return try await fallback()
            } catch {
                if KPClient.isCancellation(error) { throw error }
                if let stale: T = cached(file, maxAge: nil) { return stale }
                // Without a key there is nothing else to ask; a refused or slow API is tried again.
                if key.isEmpty { throw error }
            }
        }
        guard !key.isEmpty else {
            if let stale: T = cached(file, maxAge: nil) { return stale }
            throw APIError.noToken
        }

        let started = Date()
        let api = Task<T, Error> { try await self.fetch(url, key: key, file: file) }
        guard let fallback = fallback, !skipAPI else {
            do {
                return try await api.value
            } catch {
                if KPClient.isCancellation(error) { throw error }
                if let stale: T = cached(file, maxAge: nil) { return stale }
                throw error
            }
        }
        // Answered in time (or failed): the usual way.
        if let early = await TaskWait.result(of: api, within: hedgeDelay) {
            switch early {
            case .success(let value):
                return value
            case .failure(let error):
                if KPClient.isCancellation(error) { throw error }
                if let stale: T = cached(file, maxAge: nil) { return stale }
                if let value = try? await fallback() { return value }
                throw error
            }
        }
        if Task.isCancelled { throw CancellationError() }
        // Slow: Zona's index is asked too, the first answer is shown.
        let zona = Task<T, Error> { try await fallback() }
        let first = await TaskWait.firstSuccess([api, zona])
        switch first.result {
        case .success(let value):
            if first.index == 1 {
                let waited = Int(Date().timeIntervalSince(started) * 1_000)
                if HostHealth.shared.markDown(KPClient.host, for: 3 * 60, reason: "отвечает медленно") {
                    AppDiagnostics.shared.log("kp", "Кинопоиск отвечает медленно (нет ответа за \(waited) мс): каталог из индекса Zona")
                }
            }
            return value
        case .failure(let error):
            if KPClient.isCancellation(error) { throw error }
            if let stale: T = cached(file, maxAge: nil) { return stale }
            // The error of the API says more (the key, the limit).
            if let apiError = await TaskWait.result(of: api, within: 0.1), case .failure(let reason) = apiError { throw reason }
            throw error
        }
    }

    /// One request to the API; failures mark the host or the key, so the next requests go to the
    /// index at once.
    private func fetch<T: Decodable & Sendable>(_ url: URL, key: String, file: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let started = Date()
        do {
            let (data, code) = try await requests.fetch(request, using: session)
            if code == 402 || code == 429 { throw APIError.limit }
            guard (200..<300).contains(code) else { throw APIError.http(code) }
            let value = try JSONDecoder().decode(T.self, from: data)
            try? data.write(to: file, options: .atomic)
            // Only a quick answer clears the mark of a slow host.
            if Date().timeIntervalSince(started) < hedgeDelay { HostHealth.shared.markUp(KPClient.host) }
            return value
        } catch {
            note(error, key: key)
            throw error
        }
    }

    private func note(_ error: Error, key: String) {
        if KPClient.isCancellation(error) { return }
        switch error {
        case APIError.limit:
            refuse(key, for: 60 * 60, limit: true)
            AppDiagnostics.shared.log("kp", "Лимит запросов Кинопоиска исчерпан: каталог из индекса Zona")
        case APIError.http(let code) where code == 401 || code == 403:
            refuse(key, for: 30 * 60, limit: false)
            AppDiagnostics.shared.log("kp", "Ключ Кинопоиска не принят (\(code)): каталог из индекса Zona")
        case APIError.http(let code) where code >= 500:
            if HostHealth.shared.markDown(KPClient.host, for: 5 * 60, reason: "временно недоступен (ошибка \(code))") {
                AppDiagnostics.shared.log("kp", "Кинопоиск: ошибка \(code), каталог из индекса Zona")
            }
        default:
            if HostHealth.isHostFailure(error),
               HostHealth.shared.markDown(KPClient.host, for: 10 * 60, reason: "не отвечает") {
                AppDiagnostics.shared.log("kp", "Кинопоиск не отвечает (\(error.localizedDescription)): каталог из индекса Zona")
            }
        }
    }

    private func refuse(_ key: String, for seconds: TimeInterval, limit: Bool) {
        lock.lock()
        refused = (key, Date().addingTimeInterval(seconds), limit)
        lock.unlock()
    }

    private func isRefused(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let refused = refused, refused.key == key else { return false }
        return refused.until > Date()
    }

    /// Why the catalog comes from Zona's index now, for the banner and the log; nil while the API is used.
    var fallbackReason: String? {
        let key = token
        if key.isEmpty { return "нет ключа API Кинопоиска" }
        lock.lock()
        let refusal = refused
        lock.unlock()
        if let refusal = refusal, refusal.key == key, refusal.until > Date() {
            return refusal.limit ? "лимит запросов Кинопоиска на сегодня исчерпан" : "ключ API Кинопоиска не принят"
        }
        if let reason = HostHealth.shared.reason(KPClient.host) { return "Кинопоиск \(reason)" }
        return nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Endpoints

    func collection(_ type: String, page: Int = 1) async throws -> KPPage {
        try await get("/api/v2.2/films/collections", query: [("type", type), ("page", String(page))], ttl: TTL.day) {
            try await ZonaCatalog.shared.collection(type, page: page)
        }
    }

    func films(_ filter: CatalogFilter, page: Int) async throws -> KPPage {
        // A genre or country chosen without the API has no id: only the index can filter by it.
        if filter.needsNames, ZonaCatalog.isEnabled {
            return try await ZonaCatalog.shared.films(filter, page: page)
        }
        return try await get("/api/v2.2/films", query: filter.query + [("page", String(page))], ttl: TTL.day) {
            try await ZonaCatalog.shared.films(filter, page: page)
        }
    }

    func search(_ keyword: String, page: Int = 1) async throws -> KPPage {
        try await get("/api/v2.1/films/search-by-keyword", query: [("keyword", keyword), ("page", String(page))], ttl: TTL.day) {
            try await ZonaCatalog.shared.search(keyword, page: page)
        }
    }

    func film(_ id: Int) async throws -> KPFilm {
        try await get("/api/v2.2/films/\(id)", ttl: TTL.week) {
            try await ZonaCatalog.shared.film(id)
        }
    }

    func seasons(_ id: Int) async throws -> [KPSeason] {
        let result: KPSeasons = try await get("/api/v2.2/films/\(id)/seasons", ttl: TTL.day) {
            KPSeasons(items: try await ZonaCatalog.shared.seasons(id))
        }
        return KPSeason.merged(result.items)
    }

    func staff(_ id: Int) async throws -> [KPStaff] {
        try await get("/api/v1/staff", query: [("filmId", String(id))], ttl: TTL.month) {
            try await ZonaCatalog.shared.staff(id)
        }
    }

    func similars(_ id: Int) async throws -> [MediaItem] {
        let page: KPPage = try await get("/api/v2.2/films/\(id)/similars", ttl: TTL.month) {
            KPPage(totalPages: 1, items: try await ZonaCatalog.shared.similars(id))
        }
        return page.items
    }

    func videos(_ id: Int) async throws -> [KPVideo] {
        let result: KPVideos = try await get("/api/v2.2/films/\(id)/videos", ttl: TTL.month)
        return result.items
    }

    func filters() async throws -> KPFilters {
        try await get("/api/v2.2/films/filters", ttl: TTL.month) {
            ZonaCatalog.filters()
        }
    }

    func person(_ id: Int) async throws -> KPPerson {
        try await get("/api/v1/staff/\(id)", ttl: TTL.month) {
            try await ZonaCatalog.shared.person(id)
        }
    }

    /// Answers not used for two months are removed once per launch, in the background:
    /// otherwise the cache grows with every film page ever opened.
    func pruneCache(olderThan age: TimeInterval = 60 * 60 * 24 * 60) {
        let dir = cacheDir
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 20) {
            let manager = FileManager.default
            let files = (try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let now = Date()
            var removed = 0
            for file in files {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(date) > age, (try? manager.removeItem(at: file)) != nil {
                    removed += 1
                }
            }
            if removed > 0 {
                AppDiagnostics.shared.log("cache", "Удалено старых ответов Кинопоиска: \(removed)")
            }
        }
    }

    /// The saved answers of the API and of Zona's catalog.
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        ZonaCatalog.shared.clearCache()
    }

    var cacheSizeText: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let total = files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total + ZonaCatalog.shared.cacheBytes), countStyle: .file)
    }
}
