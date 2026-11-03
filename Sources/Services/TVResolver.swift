import Foundation

// MARK: - Streams of the built-in channels

enum TVError: LocalizedError, Equatable {
    /// The service shows the channel only in Russia; the country it sees, when known.
    case geo(String?)
    case http(Int)
    case unavailable

    var isGeo: Bool {
        if case .geo = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .geo(let code):
            var place = ""
            if let code = code?.trimmed.uppercased(), code.count == 2, code != "RU",
               let name = Locale(identifier: "ru_RU").localizedString(forRegionCode: code) {
                place = ", а подключение сейчас определяется как «\(name)»"
            }
            return "Канал показывают только в России\(place). Если включён VPN, выключите его и нажмите «Повторить»."
        case .http, .unavailable:
            return "Канал сейчас не отвечает. Попробуйте позже или выберите другой канал."
        }
    }
}

/// Requests to the TV services: they expect a browser, so the User-Agent is Safari's.
enum TVNet {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["Accept-Language": "ru-RU,ru;q=0.9,en;q=0.5"]
        return URLSession(configuration: config)
    }()

    static func data(_ url: URL, referer: String? = nil, timeout: TimeInterval = 10) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer = referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TVError.http(http.statusCode)
        }
        return TVParsing.gunzipIfNeeded(data)
    }

    /// The link answers with a playlist: a dead or blocked stream is skipped before the player
    /// waits for it. Only the beginning is read.
    static func probe(_ url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TVError.http(http.statusCode)
        }
        var head = Data()
        for try await byte in bytes {
            head.append(byte)
            if head.count >= 1024 { break }
        }
        guard TVParsing.looksLikeStream(head) else { throw TVError.unavailable }
    }
}

actor TVResolver {
    static let shared = TVResolver()

    private struct Cached {
        let url: URL
        let date: Date
    }

    /// The balancer found on the player page of a channel of «Витрина ТВ» (the page is big).
    private var balancers: [String: Cached] = [:]
    private var playerPages: [String: URL] = [:]
    private var playerPagesDate: Date?
    private static let cacheLifetime: TimeInterval = 6 * 3600

    /// A working stream of the channel. Every source is asked at once; the first one in the order
    /// of the catalog wins. A later source is taken when the earlier ones failed — or when they
    /// still have not answered 3 s after it did.
    func resolve(_ channel: TVChannel) async throws -> URL {
        let sources = channel.sources
        guard !sources.isEmpty else { throw TVError.unavailable }
        let outcome = await withTaskGroup(of: (Int, Result<URL, Error>).self,
                                          returning: Result<URL, Error>.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await self.stream(for: source)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<URL, Error>?](repeating: nil, count: sources.count)
            var graceStarted = false
            var graceOver = false
            while let next = await group.next() {
                if next.0 < 0 {
                    graceOver = true
                } else {
                    results[next.0] = next.1
                }
                var pending = false
                var firstSuccess: URL?
                for item in results {
                    switch item {
                    case .none:
                        pending = true
                    case .some(.success(let url)):
                        if firstSuccess == nil { firstSuccess = url }
                    case .some(.failure):
                        break
                    }
                    if pending || firstSuccess != nil { break }
                }
                if let url = firstSuccess {
                    group.cancelAll()
                    return .success(url)
                }
                let anySuccess = results.contains { item in
                    if case .some(.success) = item { return true }
                    return false
                }
                if anySuccess {
                    if graceOver, let url = results.lazy.compactMap({ item -> URL? in
                        if case .some(.success(let url)) = item { return url }
                        return nil
                    }).first {
                        group.cancelAll()
                        return .success(url)
                    }
                    if !graceStarted {
                        graceStarted = true
                        group.addTask {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            return (-1, .failure(CancellationError()))
                        }
                    }
                } else if !pending {
                    break
                }
            }
            let errors: [Error] = results.compactMap { item -> Error? in
                if case .some(.failure(let error)) = item { return error }
                return nil
            }
            if let geo = errors.first(where: { ($0 as? TVError)?.isGeo == true }) {
                return .failure(geo)
            }
            return .failure(TVError.unavailable)
        }
        try Task.checkCancellation()
        return try outcome.get()
    }

    private func stream(for source: TVSource) async throws -> URL {
        switch source {
        case .stream(let link):
            guard let url = URL(string: link) else { throw TVError.unavailable }
            try await TVNet.probe(url)
            return url
        case .playlistAPI(let link):
            guard let api = URL(string: link) else { throw TVError.unavailable }
            let data = try await TVNet.data(api)
            guard let answer = TVParsing.streamAnswer(data) else { throw TVError.unavailable }
            return try await firstWorking(answer)
        case .vitrina(let channel):
            return try await vitrina(channel)
        }
    }

    /// The first link of an answer that plays; outside Russia a blocked stream means the region.
    private func firstWorking(_ answer: TVStreamAnswer) async throws -> URL {
        let links = (answer.hls + answer.mpd).compactMap { URL(string: $0) }
        guard !links.isEmpty else { throw TVError.unavailable }
        if links.allSatisfy({ TVParsing.isGeoStub($0.absoluteString) }) { throw TVError.geo(answer.country) }
        var lastError: Error = TVError.unavailable
        for url in links.prefix(2) where !TVParsing.isGeoStub(url.absoluteString) {
            do {
                try await TVNet.probe(url)
                return url
            } catch {
                lastError = error
            }
        }
        if let country = answer.country?.uppercased(), country != "RU", (lastError as? TVError) == TVError.http(403) {
            throw TVError.geo(country)
        }
        throw lastError
    }

    private func vitrina(_ channel: VitrinaChannel) async throws -> URL {
        if let cached = balancers[channel.slug], Date().timeIntervalSince(cached.date) < Self.cacheLifetime {
            do {
                return try await stream(fromBalancer: cached.url)
            } catch let error as TVError where error.isGeo {
                throw error
            } catch {
                balancers[channel.slug] = nil
            }
        }
        guard let balancer = await findBalancer(channel) else { throw TVError.unavailable }
        do {
            let url = try await stream(fromBalancer: balancer)
            balancers[channel.slug] = Cached(url: balancer, date: Date())
            return url
        } catch let error as TVError where error.isGeo {
            balancers[channel.slug] = Cached(url: balancer, date: Date())
            throw error
        }
    }

    private func stream(fromBalancer balancer: URL) async throws -> URL {
        let data = try await TVNet.data(balancer, referer: "https://player.mediavitrina.ru/")
        guard let answer = TVParsing.streamAnswer(data) else { throw TVError.unavailable }
        return try await firstWorking(answer)
    }

    /// The balancer link from the player page; when the page moved, the new one is taken from the
    /// config of vitrina.tv; the link known to the app is the last resort.
    private func findBalancer(_ channel: VitrinaChannel) async -> URL? {
        if let page = channel.playerURL, let url = await Self.balancer(onPage: page, egress: channel.egress) {
            return url
        }
        if let page = await currentPlayerPage(channel.slug), page != channel.playerURL,
           let url = await Self.balancer(onPage: page, egress: channel.egress) {
            return url
        }
        return channel.fallbackBalancerURL
    }

    private static func balancer(onPage page: URL, egress: String) async -> URL? {
        guard let data = try? await TVNet.data(page, referer: "https://vitrina.tv/") else { return nil }
        return TVParsing.balancerURL(inPlayerPage: String(decoding: data, as: UTF8.self), fallbackEgress: egress)
    }

    private func currentPlayerPage(_ slug: String) async -> URL? {
        let fresh = playerPagesDate.map { Date().timeIntervalSince($0) < Self.cacheLifetime } ?? false
        if !fresh, let data = try? await TVNet.data(TVCatalog.vitrinaConfigURL, referer: "https://vitrina.tv/") {
            let pages = TVParsing.playerPages(inConfig: data)
            if !pages.isEmpty {
                playerPages = pages
                playerPagesDate = Date()
            }
        }
        return playerPages[slug]
    }
}

// MARK: - Programme guide

/// What is on the air now: the guide of «Витрина ТВ» for the channels that have it.
@MainActor
final class TVGuide: ObservableObject {
    static let shared = TVGuide()

    @Published private(set) var schedules: [String: [TVProgramme]] = [:]
    private var attempts: [String: Date] = [:]
    private var loading: Set<String> = []

    func load(_ channel: TVChannel) async {
        guard let url = channel.guideURL else { return }
        let id = channel.id
        if let last = attempts[id] {
            let age = Date().timeIntervalSince(last)
            // Asked a moment ago (or failed): not again while the grid scrolls.
            if age < 5 * 60 || (age < 30 * 60 && now(for: id) != nil) { return }
        }
        guard !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let data = try? await TVNet.data(url, referer: "https://vitrina.tv/", timeout: 12)
        attempts[id] = Date()
        guard let data = data else { return }
        let list = TVParsing.programmes(data)
        if !list.isEmpty { schedules[id] = list }
    }

    func now(for id: String, at date: Date = Date()) -> TVProgramme? {
        schedules[id]?.first { $0.start <= date && date < $0.end }
    }

    func next(for id: String, at date: Date = Date()) -> TVProgramme? {
        schedules[id]?.first { $0.start > date }
    }
}
