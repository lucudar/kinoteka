import Foundation

enum TorrentSearchError: LocalizedError {
    case noServer
    case http(Int)
    case badResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noServer:
            return "Не задан сервер поиска раздач. Укажите его: Моё → Настройки → Поиск раздач."
        case .http(let code):
            if code == 401 || code == 403 { return "Сервер поиска отклонил запрос (\(code)): проверьте API-ключ в настройках." }
            if code == 429 { return "Сервер поиска раздач просит подождать: слишком много запросов. Попробуйте через минуту." }
            return "Сервер поиска раздач недоступен (ошибка \(code)). Попробуйте позже или укажите другой сервер."
        case .badResponse:
            return "Сервер поиска вернул неожиданный ответ. Проверьте адрес в настройках: нужен Jacred или Jackett."
        case .network(let text):
            return "Нет связи с сервером поиска раздач: \(text)"
        }
    }
}

struct TorrentSearchResult: Codable, Sendable {
    var releases: [TorrentRelease]
    /// Results returned by the server before filtering.
    var found: Int
}

extension TorrentSearchQuery {
    /// The automatic search for a film or series of the catalog.
    init(item: MediaItem) {
        self.init(title: item.title, originalTitle: item.originalTitle, year: item.year, isSeries: item.kind == .series)
    }
}

/// Finds torrents for a title through a Jackett-compatible API (Jacred by default),
/// the way Zona lists "раздачи" for every film.
///
/// Fast on purpose: the film page searches in advance, equal requests running at the same time
/// share one download, and results are kept in memory and on disk (the page of a film opened
/// before shows its releases at once, even offline).
@MainActor
final class TorrentSearchService {
    static let shared = TorrentSearchService()
    nonisolated static let defaultServer = "https://jac.red"

    /// Results younger than this are used without asking the server again.
    private let freshLifetime: TimeInterval = 30 * 60
    /// Older results are still used when the server cannot be reached.
    private let staleLifetime: TimeInterval = 3 * 24 * 60 * 60

    private let session: URLSession
    private var memory: [URL: CachedSearch] = [:]
    private var inFlight: [URL: (id: UUID, task: Task<TorrentSearchResult, Error>)] = [:]
    private var pruned = false
    /// Different film pages share one polite request queue, preventing jac.red 429 bursts.
    private var nextRequestAt = Date.distantPast
    private var rateLimitUntil = Date.distantPast
    private var rateLimitLevel = 0

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }

    var server: String {
        let value = (UserDefaults.standard.string(forKey: SettingsKeys.searchServer) ?? "").trimmed
        return value.isEmpty ? TorrentSearchService.defaultServer : value
    }

    var apiKey: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.searchApiKey) ?? "").trimmed
    }

    var preferredQuality: ReleaseQuality {
        ReleaseQuality(rawValue: UserDefaults.standard.integer(forKey: SettingsKeys.preferredQuality)) ?? .fullHD
    }

    /// Releases for the query: fresh cached ones at once, otherwise from the server
    /// (and the older cached ones when the server does not answer).
    func search(_ query: TorrentSearchQuery, force: Bool = false) async throws -> TorrentSearchResult {
        guard let url = query.url(server: server, apiKey: apiKey) else { throw TorrentSearchError.noServer }
        if !force {
            if let hit = await cached(url) {
                if hit.age < freshLifetime { return hit.result }
                // During server backoff show the older result immediately instead of
                // making the film page wait for the retry timer.
                if Date() < rateLimitUntil, hit.age < staleLifetime { return hit.result }
            }
            if let running = inFlight[url] { return try await running.task.value }
        }
        let alternative = query.url(server: server, apiKey: apiKey, useOriginalTitle: true)
        let id = UUID()
        let task = Task {
            let started = Date()
            let result = try await self.download(url, alternative: alternative, query: query)
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            AppDiagnostics.shared.log("search", "\(query.title): \(result.releases.count) раздач за \(elapsed) мс")
            return result
        }
        inFlight[url] = (id, task)
        defer {
            if inFlight[url]?.id == id { inFlight[url] = nil }
        }
        do {
            let result = try await task.value
            store(CachedSearch(url: url.absoluteString, date: Date(), result: result), for: url)
            return result
        } catch {
            if error is CancellationError { throw error }
            if let stale = await cached(url), stale.age < staleLifetime { return stale.result }
            throw error
        }
    }

    /// Whatever was found before for the query (up to a few days old), without asking the server.
    func cachedResult(_ query: TorrentSearchQuery) async -> TorrentSearchResult? {
        guard let url = query.url(server: server, apiKey: apiKey),
              let hit = await cached(url), hit.age < staleLifetime else { return nil }
        return hit.result
    }

    func clearCache() {
        memory.removeAll()
        let dir = TorrentSearchService.cacheDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Cache

    private func cached(_ url: URL) async -> CachedSearch? {
        if let hit = memory[url] { return hit }
        let file = TorrentSearchService.cacheFile(for: url)
        let key = url.absoluteString
        let loaded: CachedSearch? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(CachedSearch.self, from: data),
                  entry.url == key else { return nil }
            return entry
        }.value
        guard let entry = loaded else { return nil }
        // A newer result may have arrived while the file was read.
        if let newer = memory[url], newer.date > entry.date { return newer }
        memory[url] = entry
        return entry
    }

    private func store(_ entry: CachedSearch, for url: URL) {
        memory[url] = entry
        if memory.count > 200 {
            let old = memory.sorted { $0.value.date < $1.value.date }.prefix(memory.count - 150)
            for (key, _) in old { memory.removeValue(forKey: key) }
        }
        let file = TorrentSearchService.cacheFile(for: url)
        let dir = TorrentSearchService.cacheDirectory
        let prune = !pruned
        pruned = true
        let maxAge = staleLifetime
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            try? manager.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: file, options: .atomic)
            }
            if prune { TorrentSearchService.prune(dir, maxAge: maxAge, keep: 300) }
        }
    }

    private nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("torrent-search", isDirectory: true)
    }

    /// v1: bump when the parsing of results changes, so old parsed results are not reused.
    private nonisolated static func cacheFile(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent("v1-" + CacheName.digest(url.absoluteString) + ".json")
    }

    /// Removes results older than `maxAge` and the oldest ones above `keep` files.
    private nonisolated static func prune(_ dir: URL, maxAge: TimeInterval, keep: Int) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { file -> (URL, Date) in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (file, date)
        }.sorted { $0.1 > $1.1 }
        let now = Date()
        for (index, item) in dated.enumerated() where index >= keep || now.timeIntervalSince(item.1) > maxAge {
            try? manager.removeItem(at: item.0)
        }
    }

    // MARK: Network

    private func download(_ url: URL, alternative: URL?, query: TorrentSearchQuery) async throws -> TorrentSearchResult {
        var result = try await fetch(url, query: query)
        // A plain Jackett searches by one string: retry with the original title when nothing matched.
        if result.releases.isEmpty, !query.isCustom,
           let original = query.originalTitle?.nonEmpty, original != query.title,
           let alternative = alternative, alternative != url {
            let second = try await fetch(alternative, query: query)
            result = TorrentSearchResult(releases: second.releases, found: result.found + second.found)
        }
        return result
    }

    private func fetch(_ url: URL, query: TorrentSearchQuery) async throws -> TorrentSearchResult {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var responseData: Data?
        var lastCode = 0
        for attempt in 0..<2 {
            try await waitForRequestSlot()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                AppDiagnostics.shared.log("search", "Ошибка сети: \(error.localizedDescription)")
                throw TorrentSearchError.network(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            lastCode = code
            if code == 429 {
                let headerDelay = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                registerRateLimit(retryAfter: headerDelay)
                AppDiagnostics.shared.log("search", "HTTP 429, повтор \(attempt + 1)")
                if attempt == 0 { continue }
            }
            guard (200..<300).contains(code) else {
                AppDiagnostics.shared.log("search", "HTTP \(code)")
                throw TorrentSearchError.http(code)
            }
            rateLimitLevel = max(0, rateLimitLevel - 1)
            responseData = data
            break
        }
        guard let data = responseData else { throw TorrentSearchError.http(lastCode) }

        let filter = query.filter
        let parsed: (found: Int, releases: [TorrentRelease])? = await Task.detached(priority: .userInitiated) {
            guard let decoded = try? JSONDecoder().decode(JackettSearchResponse.self, from: data) else { return nil }
            return (decoded.items.count, ReleaseBuilder.build(from: decoded, filter: filter))
        }.value
        guard let parsed = parsed else { throw TorrentSearchError.badResponse }
        return TorrentSearchResult(releases: parsed.releases, found: parsed.found)
    }

    /// Reserves a request slot before sleeping, so concurrent searches cannot wake together.
    private func waitForRequestSlot() async throws {
        let now = Date()
        let slot = max(now, max(nextRequestAt, rateLimitUntil))
        nextRequestAt = slot.addingTimeInterval(0.9)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
    }

    private func registerRateLimit(retryAfter: TimeInterval?) {
        rateLimitLevel = min(rateLimitLevel + 1, 4)
        let automatic = min(120, 12 * pow(2, Double(rateLimitLevel - 1)))
        let delay = max(1, retryAfter ?? automatic)
        rateLimitUntil = max(rateLimitUntil, Date().addingTimeInterval(delay))
    }
}

/// One saved search result.
private struct CachedSearch: Codable, Sendable {
    var url: String
    var date: Date
    var result: TorrentSearchResult

    var age: TimeInterval { Date().timeIntervalSince(date) }
}

/// Short stable file names for cache entries (FNV-1a, 64 bit).
enum CacheName {
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
