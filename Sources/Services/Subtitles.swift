import Foundation
import Security

/// A password kept in the iOS Keychain (not in the settings or the backup).
enum KeychainStore {
    private static let service = "com.lucudar.kinoteka"

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Subtitles from OpenSubtitles.com (REST API v1). It needs a free API key of the user:
/// opensubtitles.com → profile → API consumers. Without an account the service allows
/// a few downloads a day per address; with a free account — more.
@MainActor
final class SubtitleService {
    static let shared = SubtitleService()
    static let keyPage = URL(string: "https://www.opensubtitles.com/consumers")
    nonisolated static let passwordAccount = "opensubtitles-password"

    enum Failure: LocalizedError {
        case noKey
        case unauthorized
        case limit(String)
        case server(String)
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .noKey: return "Добавьте ключ OpenSubtitles в настройках субтитров"
            case .unauthorized: return "OpenSubtitles не принял ключ или пароль"
            case .limit(let text): return text.isEmpty ? "Лимит скачиваний OpenSubtitles на сегодня исчерпан" : text
            case .server(let text): return "OpenSubtitles: \(text)"
            case .nothingFound: return "Субтитры не найдены"
            }
        }
    }

    struct Query {
        var title: String
        var originalTitle: String?
        var year: Int?
        var imdbId: String?
        var isSeries: Bool
        var season: Int?
        var episode: Int?
        var movieHash: String?
        /// The name of the playing file: versions with the same words come first.
        var releaseName: String?
    }

    private let session: URLSession
    private var token: String?
    private var tokenDate = Date.distantPast
    private var tokenUser = ""
    private var apiHost = "api.opensubtitles.com"
    private var cache: [String: [SubtitleCandidate]] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    var apiKey: String { UserDefaults.standard.string(forKey: SettingsKeys.openSubtitlesKey)?.trimmed ?? "" }
    var hasKey: Bool { !apiKey.isEmpty }

    /// Languages to ask for, in order of preference ("ru", then "en").
    var languages: [String] {
        let primary = UserDefaults.standard.string(forKey: SettingsKeys.subtitleLanguage)?.nonEmpty ?? "ru"
        var list = [primary]
        if UserDefaults.standard.bool(forKey: SettingsKeys.subtitleEnglishFallback), primary != "en" {
            list.append("en")
        }
        return list
    }

    static let languageChoices: [(code: String, title: String)] = [
        ("ru", "Русские"), ("en", "Английские"), ("uk", "Украинские"), ("de", "Немецкие"),
        ("fr", "Французские"), ("es", "Испанские"), ("it", "Итальянские"), ("ja", "Японские"),
        ("ko", "Корейские"), ("zh-cn", "Китайские")
    ]

    static func languageTitle(_ code: String) -> String {
        languageChoices.first { $0.code == code }?.title ?? code.uppercased()
    }

    // MARK: Search

    func search(_ query: Query) async throws -> [SubtitleCandidate] {
        guard hasKey else { throw Failure.noKey }
        let languages = self.languages
        var items: [(String, String)] = [("languages", languages.sorted().joined(separator: ","))]
        if let hash = query.movieHash { items.append(("moviehash", hash)) }
        let imdb = query.imdbId.flatMap { Int($0.lowercased().replacingOccurrences(of: "tt", with: "")) }
        if query.isSeries {
            items.append(("type", "episode"))
            if let imdb { items.append(("parent_imdb_id", String(imdb))) }
            if let season = query.season { items.append(("season_number", String(season))) }
            if let episode = query.episode { items.append(("episode_number", String(episode))) }
        } else {
            items.append(("type", "movie"))
            if let imdb { items.append(("imdb_id", String(imdb))) }
        }
        if imdb == nil {
            let title = (query.originalTitle?.nonEmpty ?? query.title).lowercased()
            items.append(("query", title))
            if !query.isSeries, let year = query.year { items.append(("year", String(year))) }
        }
        // The service redirects requests with unsorted parameters.
        items.sort { $0.0 < $1.0 }
        let key = items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        if let cached = cache[key] {
            return SubtitleRanking.sorted(cached, languages: languages, releaseName: query.releaseName,
                                          season: query.season, episode: query.episode)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/api/v1/subtitles"
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw Failure.server("неверный запрос") }
        let data = try await send(request(url))
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        let found = response.data.compactMap(\.candidate)
        cache[key] = found
        AppDiagnostics.shared.log("subtitles", "OpenSubtitles: найдено \(found.count)")
        return SubtitleRanking.sorted(found, languages: languages, releaseName: query.releaseName,
                                      season: query.season, episode: query.episode)
    }

    /// Downloads the file of found subtitles; returns where it is saved.
    func download(_ candidate: SubtitleCandidate) async throws -> URL {
        guard hasKey else { throw Failure.noKey }
        let folder = SubtitleService.cacheFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SubtitleService.fileName(candidate)
        let target = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        if let user = UserDefaults.standard.string(forKey: SettingsKeys.openSubtitlesUser)?.trimmed, !user.isEmpty {
            try? await login(user: user)
        }
        guard let url = URL(string: "https://\(apiHost)/api/v1/download") else { throw Failure.server("неверный адрес") }
        var post = request(url)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": candidate.fileId])
        let answer = try JSONDecoder().decode(DownloadResponse.self, from: try await send(post))
        guard let link = answer.link.flatMap(URL.init(string:)) else {
            throw Failure.limit(answer.message ?? "")
        }
        let (data, response) = try await session.data(from: link)
        guard ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2, !data.isEmpty else {
            throw Failure.server("файл не скачался")
        }
        try data.write(to: target, options: .atomic)
        if let remaining = answer.remaining {
            AppDiagnostics.shared.log("subtitles", "Скачаны субтитры \(candidate.language), осталось скачиваний: \(remaining)")
        }
        return target
    }

    /// Checks the account; the token is kept for a day.
    func login(user: String) async throws {
        if token != nil, tokenUser == user, Date().timeIntervalSince(tokenDate) < 20 * 3600 { return }
        guard let password = KeychainStore.string(SubtitleService.passwordAccount), !password.isEmpty else { return }
        guard let url = URL(string: "https://api.opensubtitles.com/api/v1/login") else { return }
        var post = request(url, authorized: false)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: ["username": user, "password": password])
        let answer = try JSONDecoder().decode(LoginResponse.self, from: try await send(post))
        guard let value = answer.token else { throw Failure.unauthorized }
        token = value
        tokenUser = user
        tokenDate = Date()
        if let host = answer.base_url?.nonEmpty {
            apiHost = host.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "/", with: "")
        }
    }

    func forgetLogin() {
        token = nil
        tokenUser = ""
        apiHost = "api.opensubtitles.com"
    }

    private func request(_ url: URL, authorized: Bool = true) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Kinoteka v\(SubtitleService.appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300:
            return data
        case 401, 403:
            forgetLogin()
            throw Failure.unauthorized
        case 406, 429:
            let message = (try? JSONDecoder().decode(DownloadResponse.self, from: data))?.message ?? ""
            throw Failure.limit(message)
        default:
            let text = String(data: data.prefix(200), encoding: .utf8)?.trimmed ?? ""
            throw Failure.server(text.isEmpty ? "HTTP \(code)" : "HTTP \(code) \(text)")
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: Files

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subtitles", isDirectory: true)
    }

    private static func fileName(_ candidate: SubtitleCandidate) -> String {
        var base = (candidate.fileName.isEmpty ? candidate.release : candidate.fileName)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if base.isEmpty { base = "subtitles" }
        let ext = (base as NSString).pathExtension.lowercased()
        if !["srt", "ass", "ssa", "vtt", "sub", "smi"].contains(ext) { base += ".srt" }
        return "\(candidate.language)-\(candidate.fileId)-\(base)"
    }

    /// Downloaded subtitles are kept for a month.
    nonisolated static func pruneCache() {
        DispatchQueue.global(qos: .utility).async {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Subtitles", isDirectory: true)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
            let limit = Date().addingTimeInterval(-30 * 24 * 3600)
            for file in files {
                let date = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                if date < limit { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    /// The OpenSubtitles hash of a playing file: its size and its first and last 64 KB.
    /// The engine reads them from the torrent (the end is usually prepared in advance).
    nonisolated static func movieHash(of url: URL, size: Int64) async -> String? {
        let chunk = Int64(OpenSubtitlesHash.chunkSize)
        guard size >= chunk * 2 else { return nil }
        if url.isFileURL {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: Int(chunk)) else { return nil }
            try? handle.seek(toOffset: UInt64(size - chunk))
            guard let tail = try? handle.read(upToCount: Int(chunk)) else { return nil }
            return OpenSubtitlesHash.compute(fileSize: size, head: head, tail: tail)
        }
        async let head = range(url, from: 0, count: chunk)
        async let tail = range(url, from: size - chunk, count: chunk)
        guard let first = await head, let last = await tail else { return nil }
        return OpenSubtitlesHash.compute(fileSize: size, head: first, tail: last)
    }

    private nonisolated static func range(_ url: URL, from offset: Int64, count: Int64) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 206 else { return nil }
        return data.count >= Int(count) ? data.prefix(Int(count)) : nil
    }
}

// MARK: - Answers of the API

private struct SearchResponse: Decodable {
    let data: [Entry]

    struct Entry: Decodable {
        let attributes: Attributes?

        var candidate: SubtitleCandidate? {
            guard let attributes, let file = attributes.files?.first, let fileId = file.file_id else { return nil }
            return SubtitleCandidate(fileId: fileId,
                                     language: attributes.language ?? "",
                                     release: attributes.release ?? "",
                                     fileName: file.file_name ?? "",
                                     downloads: attributes.download_count ?? 0,
                                     hearingImpaired: attributes.hearing_impaired ?? false,
                                     machineTranslated: (attributes.machine_translated ?? false) || (attributes.ai_translated ?? false),
                                     hashMatch: attributes.moviehash_match ?? false,
                                     season: attributes.feature_details?.season_number,
                                     episode: attributes.feature_details?.episode_number)
        }
    }

    struct Attributes: Decodable {
        let language: String?
        let download_count: Int?
        let hearing_impaired: Bool?
        let machine_translated: Bool?
        let ai_translated: Bool?
        let moviehash_match: Bool?
        let release: String?
        let feature_details: Feature?
        let files: [File]?
    }

    struct Feature: Decodable {
        let season_number: Int?
        let episode_number: Int?
    }

    struct File: Decodable {
        let file_id: Int?
        let file_name: String?
    }
}

private struct DownloadResponse: Decodable {
    let link: String?
    let file_name: String?
    let remaining: Int?
    let message: String?
}

private struct LoginResponse: Decodable {
    let token: String?
    let base_url: String?
}
