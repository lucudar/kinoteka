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
            return "Сервер поиска раздач недоступен (ошибка \(code)). Попробуйте позже или укажите другой сервер."
        case .badResponse:
            return "Сервер поиска вернул неожиданный ответ. Проверьте адрес в настройках: нужен Jacred или Jackett."
        case .network(let text):
            return "Нет связи с сервером поиска раздач: \(text)"
        }
    }
}

struct TorrentSearchResult {
    var releases: [TorrentRelease]
    /// Results returned by the server before filtering.
    var found: Int
}

/// Finds torrents for a title through a Jackett-compatible API (Jacred by default),
/// the way Zona lists "раздачи" for every film.
@MainActor
final class TorrentSearchService {
    static let shared = TorrentSearchService()
    nonisolated static let defaultServer = "https://jac.red"

    private let session: URLSession
    private var cache: [URL: (date: Date, result: TorrentSearchResult)] = [:]
    private let cacheLifetime: TimeInterval = 20 * 60

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
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

    func search(_ query: TorrentSearchQuery, force: Bool = false) async throws -> TorrentSearchResult {
        guard let url = query.url(server: server, apiKey: apiKey) else { throw TorrentSearchError.noServer }
        if !force, let hit = cache[url], Date().timeIntervalSince(hit.date) < cacheLifetime {
            return hit.result
        }
        var result = try await fetch(url, query: query)
        // A plain Jackett searches by one string: retry with the original title when nothing matched.
        if result.releases.isEmpty, !query.isCustom,
           let original = query.originalTitle?.nonEmpty, original != query.title,
           let alternative = query.url(server: server, apiKey: apiKey, useOriginalTitle: true), alternative != url {
            let second = try await fetch(alternative, query: query)
            result = TorrentSearchResult(releases: second.releases, found: result.found + second.found)
        }
        cache[url] = (Date(), result)
        return result
    }

    func clearCache() {
        cache.removeAll()
    }

    private func fetch(_ url: URL, query: TorrentSearchQuery) async throws -> TorrentSearchResult {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw TorrentSearchError.network(error.localizedDescription)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TorrentSearchError.http(code) }

        let filter = query.filter
        let parsed: (found: Int, releases: [TorrentRelease])? = await Task.detached(priority: .userInitiated) {
            guard let decoded = try? JSONDecoder().decode(JackettSearchResponse.self, from: data) else { return nil }
            return (decoded.items.count, ReleaseBuilder.build(from: decoded, filter: filter))
        }.value
        guard let parsed = parsed else { throw TorrentSearchError.badResponse }
        return TorrentSearchResult(releases: parsed.releases, found: parsed.found)
    }
}
