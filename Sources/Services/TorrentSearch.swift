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
    /// The Jacred server (mirror) that answered.
    var server: String? = nil
    /// Where the releases came from, in order: "Zona", "jr.maxvol.pro".
    var sources: [String]? = nil

    var hasZona: Bool { sources?.contains(ZonaReleases.source) ?? false }
}

extension TorrentSearchQuery {
    /// The automatic search for a film or series of the catalog.
    init(item: MediaItem) {
        self.init(title: item.title, originalTitle: item.originalTitle, year: item.year, isSeries: item.kind == .series,
                  kinopoiskId: item.id > 0 ? item.id : nil)
    }
}

/// A finished search and the source still being waited for.
private struct SearchOutcome: Sendable {
    var result: TorrentSearchResult
    /// The slower source: its releases are added to the saved result when it answers.
    var late: Task<TorrentSearchResult, Error>?
    var lateIsZona = false
}

/// Finds torrents for a title the way Zona lists "раздачи" for every film: in Zona's own index
/// by the Kinopoisk id of the film (hosted in Russia, it answers without a VPN) and through a
/// Jackett-compatible API by the title (Jacred by default). Both are asked at once; the
/// same torrent found by both becomes one release.
///
/// Fast on purpose: the film page searches in advance, equal requests running at the same time
/// share one download, and results are kept in memory and on disk (the page of a film opened
/// before shows its releases at once, even offline). The slower source is waited for only a
/// moment: its releases are added to the saved result when they come, and the open pages are told.
///
/// For the public Jacred the mirrors (SearchMirrors) are asked in turn: a server that does not
/// answer quickly (a mobile network slowing foreign hosting down) is replaced by the next one.
@MainActor
final class TorrentSearchService {
    static let shared = TorrentSearchService()
    nonisolated static let defaultServer = SearchMirrors.primary
    /// Posted with the search's identifier (`identifier(for:)`) when late releases were added.
    nonisolated static let updated = Notification.Name("TorrentSearchService.updated")

    /// Results younger than this are used without asking the server again.
    private let freshLifetime: TimeInterval = 30 * 60
    /// Older results are still used when the server cannot be reached.
    private let staleLifetime: TimeInterval = 3 * 24 * 60 * 60

    /// A mirror that answered when the first one did not is asked first for this long.
    private let mirrorMemory: TimeInterval = 6 * 60 * 60
    /// How long the second source is waited for once the first one has found releases.
    private let secondSourceWait: TimeInterval = 2.5

    /// For the last (or the only) server: waits as long as needed.
    private let session: URLSession
    /// For a server with another one after it: gives up quickly when the answer stalls.
    private let quickSession: URLSession
    /// For Zona's index: a small answer from Russia, given up soon when it stalls (through a VPN abroad).
    private let zonaSession: URLSession
    private var memory: [URL: CachedSearch] = [:]
    private var inFlight: [URL: (id: UUID, task: Task<SearchOutcome, Error>)] = [:]
    private var pruned = false
    /// Different film pages share one polite request queue per server, preventing jac.red 429 bursts.
    private var nextRequestAt: [String: Date] = [:]
    private var rateLimitUntil: [String: Date] = [:]
    private var rateLimitLevel: [String: Int] = [:]

    init() {
        session = TorrentSearchService.makeSession(idle: 30, total: 90)
        quickSession = TorrentSearchService.makeSession(idle: 10, total: 20)
        zonaSession = TorrentSearchService.makeSession(idle: 8, total: 20)
    }

    private nonisolated static func makeSession(idle: TimeInterval, total: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idle
        config.timeoutIntervalForResource = total
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    var server: String {
        let value = (UserDefaults.standard.string(forKey: SettingsKeys.searchServer) ?? "").trimmed
        return value.isEmpty ? TorrentSearchService.defaultServer : value
    }

    /// The server results are cached for: all public mirrors share one cache.
    private var cacheServer: String {
        SearchMirrors.isBuiltIn(server) ? SearchMirrors.primary : server
    }

    /// The servers to ask in turn and the one asked first without the remembered mirror.
    private func searchPlan() -> (servers: [String], natural: String?, remembered: String?) {
        let configured = server
        let defaults = UserDefaults.standard
        var remembered: String?
        if let saved = defaults.string(forKey: SettingsKeys.searchMirror),
           let date = defaults.object(forKey: SettingsKeys.searchMirrorDate) as? Date,
           Date().timeIntervalSince(date) < mirrorMemory, date <= Date() {
            remembered = saved
        }
        // On a mobile network without a VPN foreign hosting is the one that gets slowed down.
        let network = NetworkState.shared.current
        let preferDomestic = network.map { $0.connection == .cellular && !$0.usesVPN } ?? false
        let natural = SearchMirrors.order(configured: configured, lastGood: nil, preferDomestic: preferDomestic).first
        let servers = SearchMirrors.order(configured: configured, lastGood: remembered, preferDomestic: preferDomestic)
        return (servers, natural, remembered)
    }

    var apiKey: String {
        (UserDefaults.standard.string(forKey: SettingsKeys.searchApiKey) ?? "").trimmed
    }

    /// Releases are also taken from Zona's index (on by default).
    nonisolated static var isZonaEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.zonaIndex) as? Bool ?? true
    }

    var zonaEnabled: Bool { TorrentSearchService.isZonaEnabled }

    /// The film's torrents come from the index too: the result is saved under its own key.
    private func cacheKey(_ query: TorrentSearchQuery) -> URL? {
        guard let url = query.url(server: cacheServer, apiKey: apiKey) else { return nil }
        guard zonaEnabled, let id = query.zonaId else { return url }
        return URL(string: url.absoluteString + "&zona=\(id)") ?? url
    }

    /// Compared with the object of `updated` notifications.
    func identifier(for query: TorrentSearchQuery) -> String? {
        cacheKey(query)?.absoluteString
    }

    var preferredQuality: ReleaseQuality {
        ReleaseQuality(rawValue: UserDefaults.standard.integer(forKey: SettingsKeys.preferredQuality)) ?? .fullHD
    }

    /// Releases for the query: fresh cached ones at once, otherwise from the server
    /// (and the older cached ones when the server does not answer).
    func search(_ query: TorrentSearchQuery, force: Bool = false) async throws -> TorrentSearchResult {
        guard let url = cacheKey(query) else { throw TorrentSearchError.noServer }
        if !force {
            if let hit = await cached(url) {
                if hit.age < freshLifetime { return hit.result }
                // During server backoff show the older result immediately instead of
                // making the film page wait for the retry timer.
                if allServersRateLimited, hit.age < staleLifetime { return hit.result }
            }
            if let running = inFlight[url] { return try await running.task.value.result }
        }
        let id = UUID()
        let task = Task {
            let started = Date()
            let outcome = try await self.download(query)
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            let sources = outcome.result.sources ?? []
            let from = sources.isEmpty ? "" : " (\(sources.joined(separator: " + ")))"
            AppDiagnostics.shared.log("search", "\(query.title): \(outcome.result.releases.count) раздач за \(elapsed) мс\(from)")
            return outcome
        }
        inFlight[url] = (id, task)
        defer {
            if inFlight[url]?.id == id { inFlight[url] = nil }
        }
        do {
            let outcome = try await task.value
            store(CachedSearch(url: url.absoluteString, date: Date(), result: outcome.result), for: url)
            if let late = outcome.late {
                addLate(late, isZona: outcome.lateIsZona, key: url, title: query.title)
            }
            return outcome.result
        } catch {
            if error is CancellationError { throw error }
            if let stale = await cached(url), stale.age < staleLifetime { return stale.result }
            throw error
        }
    }

    /// Whatever was found before for the query (up to a few days old), without asking the server.
    func cachedResult(_ query: TorrentSearchQuery) async -> TorrentSearchResult? {
        guard let url = cacheKey(query),
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

    /// v2 (releases of Zona's index): bump when the parsing of results changes, so old parsed
    /// results are not reused.
    private nonisolated static func cacheFile(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent("v2-" + CacheName.digest(url.absoluteString) + ".json")
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

    /// Zona's index and Jacred at once. Without a VPN the index (in Russia) answers first; through
    /// a VPN abroad Jacred does, and the index may stall. The first source with releases gives the
    /// result; the second one is waited for a moment and otherwise added later.
    private func download(_ query: TorrentSearchQuery) async throws -> SearchOutcome {
        guard zonaEnabled, let id = query.zonaId else {
            return SearchOutcome(result: try await downloadJacred(query))
        }
        let zona = Task { try await self.fetchZona(id) }
        let jacred = Task { try await self.downloadJacred(query) }
        let viaVPN = NetworkState.shared.current?.usesVPN ?? false
        let first = viaVPN ? jacred : zona
        let second = viaVPN ? zona : jacred
        let firstIsZona = !viaVPN

        let firstResult = await TaskWait.result(of: first, within: 120) ?? .failure(TorrentSearchError.network("нет ответа"))
        if case .success(let found) = firstResult, !found.releases.isEmpty {
            if let secondResult = await TaskWait.result(of: second, within: secondSourceWait) {
                if case .success(let more) = secondResult {
                    return SearchOutcome(result: firstIsZona ? merged(zona: found, other: more) : merged(zona: more, other: found))
                }
                return SearchOutcome(result: found)
            }
            return SearchOutcome(result: found, late: second, lateIsZona: !firstIsZona)
        }
        if Task.isCancelled { throw CancellationError() }
        // The first source failed or found nothing: the second one decides.
        let secondResult = await TaskWait.result(of: second, within: 120) ?? .failure(TorrentSearchError.network("нет ответа"))
        switch (firstResult, secondResult) {
        case (.success(let a), .success(let b)):
            return SearchOutcome(result: firstIsZona ? merged(zona: a, other: b) : merged(zona: b, other: a))
        case (.failure, .success(let b)):
            return SearchOutcome(result: b)
        case (.success(let a), .failure(let error)):
            // "Nothing" from the index alone is not trusted while the search by title failed.
            if firstIsZona { throw error }
            return SearchOutcome(result: a)
        case (.failure(let a), .failure(let b)):
            if a is CancellationError || b is CancellationError { throw CancellationError() }
            // The error of the search by title says more (server, API key, "too many requests").
            throw firstIsZona ? b : a
        }
    }

    private func merged(zona: TorrentSearchResult, other: TorrentSearchResult) -> TorrentSearchResult {
        var sources: [String] = []
        for source in (zona.sources ?? []) + (other.sources ?? []) where !sources.contains(source) {
            sources.append(source)
        }
        return TorrentSearchResult(releases: ReleaseMerge.merge(zona.releases, other.releases),
                                   found: zona.found + other.found,
                                   server: other.server ?? zona.server,
                                   sources: sources)
    }

    /// The slower source answered after the result was shown: its releases join the saved result.
    private func addLate(_ task: Task<TorrentSearchResult, Error>, isZona: Bool, key: URL, title: String) {
        Task { [weak self] in
            guard let late = try? await task.value, !late.releases.isEmpty else { return }
            self?.mergeLate(late, isZona: isZona, key: key, title: title)
        }
    }

    private func mergeLate(_ late: TorrentSearchResult, isZona: Bool, key: URL, title: String) {
        guard let saved = memory[key] else { return }
        let result = isZona ? merged(zona: late, other: saved.result) : merged(zona: saved.result, other: late)
        store(CachedSearch(url: saved.url, date: saved.date, result: result), for: key)
        let from = (late.sources ?? []).joined(separator: ", ")
        AppDiagnostics.shared.log("search", "\(title): позже добавлено \(late.releases.count) раздач (\(from)), всего \(result.releases.count)")
        NotificationCenter.default.post(name: TorrentSearchService.updated, object: key.absoluteString)
    }

    /// The film's torrents in Zona's index, the most seeded first.
    private func fetchZona(_ id: Int) async throws -> TorrentSearchResult {
        guard let url = ZonaIndex.releasesURL(kinopoiskId: id) else { throw TorrentSearchError.badResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await zonaSession.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            AppDiagnostics.shared.log("search", "Zona: ошибка сети: \(error.localizedDescription)")
            throw TorrentSearchError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            AppDiagnostics.shared.log("search", "Zona: HTTP \(code)")
            throw TorrentSearchError.http(code)
        }
        let parsed: (found: Int, releases: [TorrentRelease])? = await Task.detached(priority: .userInitiated) {
            guard let page = try? JSONDecoder().decode(ZonaPage<ZonaTorrent>.self, from: data) else { return nil }
            return (page.found, ZonaReleases.build(from: page.docs))
        }.value
        guard let parsed = parsed else {
            AppDiagnostics.shared.log("search", "Zona: неожиданный ответ, \(data.count) байт")
            throw TorrentSearchError.badResponse
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        AppDiagnostics.shared.log("search", "Zona: \(parsed.releases.count) из \(parsed.found) раздач за \(elapsed) мс, \(data.count / 1024) КБ")
        return TorrentSearchResult(releases: parsed.releases, found: parsed.found, server: nil, sources: [ZonaReleases.source])
    }

    /// The search by title through Jacred (or the user's own Jackett).
    private func downloadJacred(_ query: TorrentSearchQuery) async throws -> TorrentSearchResult {
        var result = try await fetch(query, useOriginalTitle: false)
        // A plain Jackett searches by one string: retry with the original title when nothing matched.
        if result.releases.isEmpty, !query.isCustom,
           let original = query.originalTitle?.nonEmpty, original != query.title {
            let second = try await fetch(query, useOriginalTitle: true)
            result = TorrentSearchResult(releases: second.releases, found: result.found + second.found,
                                         server: second.server ?? result.server, sources: second.sources ?? result.sources)
        }
        return result
    }

    /// Asks the servers in turn until one answers.
    private func fetch(_ query: TorrentSearchQuery, useOriginalTitle: Bool) async throws -> TorrentSearchResult {
        let plan = searchPlan()
        guard !plan.servers.isEmpty else { throw TorrentSearchError.noServer }
        var lastError: Error = TorrentSearchError.noServer
        for (index, base) in plan.servers.enumerated() {
            let isLast = index == plan.servers.count - 1
            guard let url = query.url(server: base, apiKey: apiKey, useOriginalTitle: useOriginalTitle) else { continue }
            let host = url.host?.lowercased() ?? base
            // A server that asked to wait is skipped while another one can answer.
            if !isLast, let until = rateLimitUntil[host], until > Date() { continue }
            do {
                var result = try await fetchOne(url, host: host, filter: query.filter, quick: !isLast)
                result.server = base
                result.sources = [SearchMirrors.host(base) ?? host]
                rememberMirror(base, plan: plan, failover: index > 0)
                return result
            } catch {
                if error is CancellationError { throw error }
                lastError = error
                if !isLast, let next = plan.servers[(index + 1)...].first.flatMap(SearchMirrors.host) {
                    AppDiagnostics.shared.log("search", "\(host) не ответил (\(error.localizedDescription)), пробую \(next)")
                }
            }
        }
        throw lastError
    }

    /// Asked first next time: the mirror that answered after the first one failed (for a few hours);
    /// forgotten as soon as the usual first server answers again.
    private func rememberMirror(_ server: String, plan: (servers: [String], natural: String?, remembered: String?), failover: Bool) {
        let defaults = UserDefaults.standard
        if let natural = plan.natural, SearchMirrors.host(natural) == SearchMirrors.host(server) {
            if plan.remembered != nil {
                defaults.removeObject(forKey: SettingsKeys.searchMirror)
                defaults.removeObject(forKey: SettingsKeys.searchMirrorDate)
            }
        } else if failover {
            defaults.set(server, forKey: SettingsKeys.searchMirror)
            defaults.set(Date(), forKey: SettingsKeys.searchMirrorDate)
            AppDiagnostics.shared.log("search", "Запомнен сервер \(SearchMirrors.host(server) ?? server)")
        }
    }

    /// One server. `quick`: another server follows, so a stalled answer is given up soon
    /// and a "too many requests" answer is not waited for.
    private func fetchOne(_ url: URL, host: String, filter: ReleaseFilter, quick: Bool) async throws -> TorrentSearchResult {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = quick ? quickSession : self.session
        var responseData: Data?
        var lastCode = 0
        for attempt in 0..<(quick ? 1 : 2) {
            try await waitForRequestSlot(host: host)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                AppDiagnostics.shared.log("search", "\(host): ошибка сети: \(error.localizedDescription)")
                throw TorrentSearchError.network(error.localizedDescription)
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            lastCode = code
            if code == 429 {
                let headerDelay = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                registerRateLimit(host: host, retryAfter: headerDelay)
                AppDiagnostics.shared.log("search", "\(host): HTTP 429, попытка \(attempt + 1)")
                if attempt == 0 && !quick { continue }
            }
            guard (200..<300).contains(code) else {
                AppDiagnostics.shared.log("search", "\(host): HTTP \(code)")
                throw TorrentSearchError.http(code)
            }
            rateLimitLevel[host] = max(0, (rateLimitLevel[host] ?? 0) - 1)
            responseData = data
            break
        }
        guard let data = responseData else { throw TorrentSearchError.http(lastCode) }

        let parsed: (found: Int, releases: [TorrentRelease])? = await Task.detached(priority: .userInitiated) {
            guard let decoded = try? JSONDecoder().decode(JackettSearchResponse.self, from: data) else { return nil }
            return (decoded.items.count, ReleaseBuilder.build(from: decoded, filter: filter))
        }.value
        guard let parsed = parsed else {
            AppDiagnostics.shared.log("search", "\(host): неожиданный ответ, \(data.count) байт")
            throw TorrentSearchError.badResponse
        }
        return TorrentSearchResult(releases: parsed.releases, found: parsed.found)
    }

    /// Every server to ask is waiting out a "too many requests" answer.
    private var allServersRateLimited: Bool {
        let now = Date()
        let hosts = searchPlan().servers.compactMap { URL(string: $0)?.host?.lowercased() }
        return !hosts.isEmpty && hosts.allSatisfy { (rateLimitUntil[$0] ?? .distantPast) > now }
    }

    /// Reserves a request slot before sleeping, so concurrent searches cannot wake together.
    private func waitForRequestSlot(host: String) async throws {
        let now = Date()
        let slot = max(now, max(nextRequestAt[host] ?? .distantPast, rateLimitUntil[host] ?? .distantPast))
        nextRequestAt[host] = slot.addingTimeInterval(0.9)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(seconds: min(delay, 300))
        }
        try Task.checkCancellation()
    }

    private func registerRateLimit(host: String, retryAfter: TimeInterval?) {
        let level = min((rateLimitLevel[host] ?? 0) + 1, 4)
        rateLimitLevel[host] = level
        let automatic = min(120, 12 * pow(2, Double(level - 1)))
        // Retry-After comes from the server: "inf", "nan" or a huge number must not
        // break the timer, and a search should never wait for more than five minutes.
        let requested = retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? automatic
        let delay = min(300, max(1, requested))
        let current = rateLimitUntil[host] ?? .distantPast
        rateLimitUntil[host] = min(max(current, Date().addingTimeInterval(delay)), Date().addingTimeInterval(300))
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
