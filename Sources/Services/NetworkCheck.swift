import Foundation
import Network
import CFNetwork

/// One line of the network check.
struct NetworkCheckItem: Identifiable, Sendable {
    enum Group: Int, CaseIterable, Identifiable, Sendable {
        case network, catalog, torrent, speed

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .network: return "Подключение"
            case .catalog: return "Каталог и поиск раздач"
            case .torrent: return "Торрент-сеть"
            case .speed: return "Скорость торрента"
            }
        }
    }

    enum State: Sendable {
        case running, ok, warning, failed, info
    }

    let id: String
    let group: Group
    let title: String
    var state: State = .running
    var detail = ""

    /// For the text report.
    var mark: String {
        switch state {
        case .running: return "…"
        case .ok: return "✅"
        case .warning: return "⚠️"
        case .failed: return "❌"
        case .info: return "ℹ️"
        }
    }
}

/// Checks from the iPhone what the app needs in the current network: the catalog, the search
/// servers and their mirrors, trackers and DHT of the torrent network, and the real download speed
/// of a well seeded open torrent. On a mobile network without a VPN it shows what the operator
/// slows down or blocks; the text report can be sent to the developer.
@MainActor
final class NetworkCheck: ObservableObject {
    @Published private(set) var items: [NetworkCheckItem] = []
    @Published private(set) var running = false
    @Published private(set) var testingSpeed = false

    private var task: Task<Void, Never>?
    private var startedAt = Date()

    var isBusy: Bool { running || testingSpeed }

    func start() {
        guard !isBusy else { return }
        task?.cancel()
        items = []
        startedAt = Date()
        running = true
        task = Task { [weak self] in
            guard let self = self else { return }
            await self.runChecks()
            guard !Task.isCancelled else { return }
            self.running = false
            self.log(groups: [.network, .catalog, .torrent])
        }
    }

    func startSpeedTest() {
        guard !isBusy else { return }
        task?.cancel()
        items.removeAll { $0.group == .speed }
        testingSpeed = true
        task = Task { [weak self] in
            guard let self = self else { return }
            await self.runSpeedTest()
            guard !Task.isCancelled else { return }
            self.testingSpeed = false
            self.log(groups: [.speed])
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
        testingSpeed = false
    }

    /// The results as text for a message to the developer (no IP address or keys).
    var report: String {
        let date = startedAt.formatted(date: .numeric, time: .shortened)
        var lines = ["Кинотека \(AppInfo.version) — проверка сети, \(date)"]
        let profile = TorrServer.shared.activeProfile ?? TorrServer.shared.desiredProfile
        lines.append("Движок: \(profile.summary)")
        for group in NetworkCheckItem.Group.allCases {
            let rows = items.filter { $0.group == group }
            guard !rows.isEmpty else { continue }
            lines.append("")
            lines.append(group.title)
            for item in rows {
                lines.append("\(item.mark) \(item.title)" + (item.detail.isEmpty ? "" : ": \(item.detail)"))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func put(_ item: NetworkCheckItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private func log(groups: Set<NetworkCheckItem.Group>) {
        for item in items where groups.contains(item.group) {
            AppDiagnostics.shared.log("netcheck", "\(item.mark) \(item.title): \(item.detail)")
        }
    }

    // MARK: Checks

    private func runChecks() async {
        put(connectionItem())
        put(vpnItem())
        let token = (UserDefaults.standard.string(forKey: SettingsKeys.kpToken) ?? "").trimmed
        let configured = TorrentSearchService.shared.server
        let apiKey = TorrentSearchService.shared.apiKey
        var servers = SearchMirrors.all
        if !SearchMirrors.isBuiltIn(configured), let own = TorrentSearchQuery.normalizedServer(configured) {
            servers.insert(own, at: 0)
        }
        // Placeholders keep the order of the lines while the answers come in any order.
        put(NetworkCheckItem(id: "provider", group: .network, title: "Провайдер"))
        put(NetworkCheckItem(id: "kp", group: .catalog, title: "Кинопоиск"))
        put(NetworkCheckItem(id: "posters", group: .catalog, title: "Постеры"))
        for server in servers {
            put(NetworkProbes.searchPlaceholder(server))
        }
        put(NetworkCheckItem(id: "engine", group: .torrent, title: "Торрент-движок"))
        for tracker in NetworkProbes.httpTrackers {
            put(NetworkCheckItem(id: tracker.id, group: .torrent, title: tracker.title))
        }
        put(NetworkCheckItem(id: "udp", group: .torrent, title: "UDP-трекеры"))
        put(NetworkCheckItem(id: "dht", group: .torrent, title: "DHT (поиск пиров без трекеров)"))

        await withTaskGroup(of: NetworkCheckItem.self) { group in
            group.addTask { await NetworkProbes.checkProvider() }
            group.addTask { await NetworkProbes.checkKinopoisk(token: token) }
            group.addTask { await NetworkProbes.checkPosters() }
            for server in servers {
                group.addTask { await NetworkProbes.checkSearch(server, apiKey: SearchMirrors.isBuiltIn(server) ? "" : apiKey) }
            }
            group.addTask { await NetworkCheck.engineItem() }
            for tracker in NetworkProbes.httpTrackers {
                group.addTask { await NetworkProbes.checkHTTPTracker(tracker) }
            }
            group.addTask { await NetworkProbes.checkUDPTrackers() }
            group.addTask { await NetworkProbes.checkDHT() }
            for await item in group {
                if Task.isCancelled { break }
                self.put(item)
            }
        }
    }

    private func connectionItem() -> NetworkCheckItem {
        let monitor = NetworkMonitor.shared
        var parts: [String] = []
        switch monitor.connection {
        case .wifi: parts.append("Wi‑Fi")
        case .cellular: parts.append("мобильная сеть")
        case .wired: parts.append("проводная сеть")
        case .other: parts.append("другая сеть")
        case .offline: parts.append("нет сети")
        }
        if monitor.isExpensive && monitor.connection != .cellular { parts.append("платная (режим модема)") }
        if monitor.isConstrained { parts.append("экономия данных включена") }
        parts.append(monitor.supportsIPv6 ? "IPv6 есть" : "без IPv6")
        let state: NetworkCheckItem.State = monitor.connection == .offline ? .failed : (monitor.isConstrained ? .warning : .info)
        return NetworkCheckItem(id: "connection", group: .network, title: "Сеть", state: state, detail: parts.joined(separator: ", "))
    }

    private func vpnItem() -> NetworkCheckItem {
        let interfaces = NetworkProbes.vpnInterfaces()
        let vpn = NetworkMonitor.shared.usesVPN || !interfaces.isEmpty
        let names = interfaces.isEmpty ? "" : " (\(interfaces.joined(separator: ", ")))"
        return NetworkCheckItem(id: "vpn", group: .network, title: "VPN",
                                state: vpn ? .warning : .ok,
                                detail: vpn ? "похоже, включён\(names): для проверки без VPN выключите его" : "не используется")
    }

    private nonisolated static func engineItem() async -> NetworkCheckItem {
        let server = TorrServer.shared
        let running = await server.ping()
        let profile = server.activeProfile ?? server.desiredProfile
        return NetworkCheckItem(id: "engine", group: .torrent, title: "Торрент-движок",
                                state: running ? .ok : .info,
                                detail: (running ? "работает" : "запустится при просмотре") + " · " + profile.summary)
    }

    // MARK: Speed

    private func runSpeedTest() async {
        let server = TorrServer.shared
        func line(_ id: String, _ title: String, _ state: NetworkCheckItem.State, _ detail: String) {
            put(NetworkCheckItem(id: "speed-" + id, group: .speed, title: title, state: state, detail: detail))
        }
        let title = "Открытая раздача Ubuntu"
        guard !server.isPlayerActive else {
            line("main", title, .warning, "закройте плеер: проверка занимает торрент-движок")
            return
        }
        line("main", title, .running, "запуск движка…")
        do {
            try await server.ensureRunning(applyNetworkChanges: true)
        } catch {
            line("main", title, .failed, error.localizedDescription)
            return
        }
        let started = Date()
        let hash: String
        do {
            let status = try await server.add(link: NetworkProbes.speedMagnet, title: "Проверка скорости", poster: nil, saveToDB: false)
            hash = (status.hash?.nonEmpty ?? NetworkProbes.speedHash).lowercased()
        } catch {
            line("main", title, .failed, error.localizedDescription)
            return
        }
        line("main", title, .running, "поиск пиров и получение данных раздачи…")
        let files: [TorrentFile]
        do {
            files = try await server.waitForFiles(hash: hash, timeout: 45) { _ in }
        } catch {
            NetworkCheck.drop(hash)
            if Task.isCancelled { return }
            line("main", title, .failed, "за 45 с не пришли данные раздачи: трекеры и DHT не нашли пиров или соединения с ними блокируются")
            return
        }
        let metadata = Date().timeIntervalSince(started)
        guard let file = files.max(by: { $0.length < $1.length }), file.length > 0,
              let url = server.streamURL(hash: hash, file: file) else {
            NetworkCheck.drop(hash)
            line("main", title, .failed, "в раздаче нет файла")
            return
        }
        let monitor = NetworkMonitor.shared
        let mobile = monitor.connection == .cellular || monitor.isExpensive
        let limit: Int64 = mobile ? 60 << 20 : 300 << 20
        // From the middle part, as when a film is rewound: the start may be cached already.
        let offset = (file.length / 3) / (1 << 20) * (1 << 20)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        line("main", title, .running, "данные получены за \(NetworkProbes.secondsText(metadata)), скачивание до \(NetworkProbes.sizeText(limit))…")

        let rangeRequest = request
        let measured = await withTaskGroup(of: SpeedPart.self, returning: SpeedMeasure.self) { group in
            group.addTask {
                let value = await HTTPProbe.run(rangeRequest, idle: 15, total: 25, limit: limit)
                return SpeedPart.read(value)
            }
            group.addTask {
                let value = await NetworkProbes.sample(hash: hash, seconds: 30)
                return SpeedPart.sample(value)
            }
            var result = SpeedMeasure()
            for await part in group {
                switch part {
                case .read(let value):
                    result.read = value
                    group.cancelAll()
                case .sample(let value):
                    result.sample = value
                }
            }
            return result
        }
        NetworkCheck.drop(hash)
        if Task.isCancelled { return }
        guard let read = measured.read else { return }
        let sample = measured.sample

        let firstByte = read.firstByte ?? read.elapsed
        let downloadTime = max(0.5, read.elapsed - firstByte)
        let average = read.bytes > 0 ? Double(read.bytes) / downloadTime : 0
        let peak = max(sample.maxSpeed, average)
        line("main", title, read.bytes > 0 ? .ok : .failed,
             read.bytes > 0
                ? "скачано \(NetworkProbes.sizeText(read.bytes)) за \(NetworkProbes.secondsText(read.elapsed))"
                : "данные не пришли" + (read.errorText.map { ": \($0)" } ?? ""))
        line("metadata", "Данные раздачи (метаданные)", metadata < 15 ? .ok : .warning, "за \(NetworkProbes.secondsText(metadata))")
        line("peers", "Пиры", sample.maxActive >= 5 ? .ok : (sample.maxActive > 0 ? .warning : .failed),
             "подключено до \(sample.maxActive) из \(sample.maxTotal) найденных, сидов \(sample.maxSeeds)")
        line("first", "Первые данные", firstByte < 5 ? .ok : .warning, "через \(NetworkProbes.secondsText(firstByte))")
        line("rate", "Скорость", NetworkProbes.verdictState(average),
             "в среднем \(NetworkProbes.rateText(average)), максимум \(NetworkProbes.rateText(peak))")
        line("verdict", "Хватит для", NetworkProbes.verdictState(average), NetworkProbes.verdict(average))
    }

    /// Not cancelled with the check: the test torrent must not stay in the engine.
    private nonisolated static func drop(_ hash: String) {
        Task.detached(priority: .utility) {
            await TorrServer.shared.drop(hash: hash)
        }
    }
}

private enum SpeedPart: Sendable {
    case read(HTTPProbe.Result)
    case sample(SpeedSample)
}

private struct SpeedMeasure: Sendable {
    var read: HTTPProbe.Result?
    var sample = SpeedSample()
}

/// A UDP server and how fast it answered (nil: no answer).
struct UDPAnswer: Sendable {
    let name: String
    let rtt: TimeInterval?
}

/// The best numbers the engine reported during the speed test.
struct SpeedSample: Sendable {
    var maxSpeed: Double = 0
    var maxActive = 0
    var maxTotal = 0
    var maxSeeds = 0

    mutating func add(_ status: TSStatus) {
        if let speed = status.downloadSpeed, speed.isFinite { maxSpeed = max(maxSpeed, speed) }
        maxActive = max(maxActive, status.activePeers ?? 0)
        maxTotal = max(maxTotal, status.totalPeers ?? 0)
        maxSeeds = max(maxSeeds, status.connectedSeeders ?? 0)
    }
}

/// The individual checks; they run off the main thread and only return their line.
enum NetworkProbes {
    struct Tracker: Sendable {
        let id: String
        let title: String
        let url: String
    }

    /// Ubuntu desktop: a big, well seeded open torrent.
    static let speedHash = "5b1e0d988fc7a0c9e99bd852071681a59974b39f"
    static var speedMagnet: String {
        "magnet:?xt=urn:btih:\(speedHash)&dn=ubuntu-desktop-amd64.iso"
            + "&tr=https%3A%2F%2Ftorrent.ubuntu.com%2Fannounce&tr=https%3A%2F%2Fipv6.torrent.ubuntu.com%2Fannounce"
    }

    static let httpTrackers = [
        Tracker(id: "tracker-rutracker", title: "Ретрекер rutracker (bt.t-ru.org)", url: "http://bt.t-ru.org/ann?magnet"),
        Tracker(id: "tracker-corbina", title: "Ретрекер corbina.net", url: "http://retracker01-msk-virt.corbina.net:80/announce"),
        Tracker(id: "tracker-opentrackr", title: "opentrackr.org (HTTP)", url: "http://tracker.opentrackr.org:1337/announce")
    ]

    static let udpTrackers: [(host: String, port: UInt16)] = [
        ("tracker.opentrackr.org", 1337),
        ("open.stealth.si", 80),
        ("tracker.torrent.eu.org", 451),
        ("exodus.desync.com", 6969)
    ]

    static let dhtRouters: [(host: String, port: UInt16)] = [
        ("router.bittorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("router.utorrent.com", 6881),
        ("dht.libtorrent.org", 25401)
    ]

    // MARK: Network

    /// Interfaces of a VPN tunnel in the system proxy settings.
    static func vpnInterfaces() -> [String] {
        guard let unmanaged = CFNetworkCopySystemProxySettings() else { return [] }
        let settings = unmanaged.takeRetainedValue() as NSDictionary
        guard let scoped = settings["__SCOPED__"] as? [String: Any] else { return [] }
        let prefixes = ["tap", "tun", "ppp", "ipsec", "utun"]
        return scoped.keys.filter { key in prefixes.contains { key.hasPrefix($0) } }.sorted()
    }

    /// The operator as the internet sees it (without the IP address): shows a VPN or a proxy too.
    static func checkProvider() async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "provider", group: .network, title: "Провайдер", state: .info)
        guard let url = URL(string: "https://ipinfo.io/json") else { return item }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = await HTTPProbe.run(request, idle: 8, total: 12, keepBody: 32 << 10)
        guard result.status == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any] else {
            item.detail = "не удалось определить"
            return item
        }
        let org = (json["org"] as? String)?.nonEmpty ?? "неизвестен"
        let country = (json["country"] as? String)?.nonEmpty
        item.detail = country.map { "\(org), \($0)" } ?? org
        return item
    }

    // MARK: Catalog and search

    static func checkKinopoisk(token: String) async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "kp", group: .catalog, title: "Кинопоиск")
        guard let url = URL(string: "https://kinopoiskapiunofficial.tech/api/v2.2/films/301") else { return item }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-API-KEY") }
        let result = await HTTPProbe.run(request, idle: 12, total: 25)
        let time = secondsText(result.firstByte ?? result.elapsed)
        if let error = result.errorText, result.status == nil {
            item.state = .failed
            item.detail = failureText(result) ?? error
            return item
        }
        switch result.status ?? 0 {
        case 200:
            item.state = .ok
            item.detail = "отвечает за \(time)"
        case 401:
            item.state = token.isEmpty ? .warning : .failed
            item.detail = token.isEmpty ? "сервер доступен (\(time)), но ключ API не задан" : "сервер доступен, но ключ API не принят"
        case 402, 429:
            item.state = .warning
            item.detail = "сервер доступен, лимит запросов на сегодня исчерпан"
        case let code:
            item.state = .failed
            item.detail = "ошибка HTTP \(code)"
        }
        return item
    }

    static func checkPosters() async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: "posters", group: .catalog, title: "Постеры")
        guard let url = URL(string: "https://kinopoiskapiunofficial.tech/images/posters/kp_small/301.jpg") else { return item }
        let result = await HTTPProbe.run(URLRequest(url: url), idle: 12, total: 25)
        if result.status == 200, result.errorText == nil, result.bytes > 0 {
            item.state = .ok
            item.detail = "\(sizeText(result.bytes)) за \(secondsText(result.elapsed))"
        } else {
            item.state = .failed
            item.detail = failureText(result) ?? "ошибка HTTP \(result.status ?? 0)"
        }
        return item
    }

    static func searchPlaceholder(_ server: String) -> NetworkCheckItem {
        let host = SearchMirrors.host(server) ?? server
        let kind = SearchMirrors.isBuiltIn(server) ? (SearchMirrors.domestic.contains(host) ? "зеркало в России" : "основной") : "ваш сервер"
        return NetworkCheckItem(id: "search-" + host, group: .catalog, title: "Поиск: \(host) (\(kind))")
    }

    /// The search the app makes for a film page, timed; a stalled answer shows how much came.
    static func checkSearch(_ server: String, apiKey: String) async -> NetworkCheckItem {
        var item = searchPlaceholder(server)
        let query = TorrentSearchQuery(title: "Матрица", originalTitle: "The Matrix", year: 1999, isSeries: false)
        guard let url = query.url(server: server, apiKey: apiKey) else {
            item.state = .failed
            item.detail = "неверный адрес"
            return item
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result = await HTTPProbe.run(request, idle: 15, total: 45, keepBody: 8 << 20)
        if let failure = failureText(result) {
            item.state = .failed
            item.detail = failure
            return item
        }
        guard result.status == 200 else {
            item.state = .failed
            item.detail = result.status == 429 ? "просит подождать (HTTP 429)" : "ошибка HTTP \(result.status ?? 0)"
            return item
        }
        guard let response = try? JSONDecoder().decode(JackettSearchResponse.self, from: result.body) else {
            item.state = .warning
            item.detail = "неожиданный ответ (\(sizeText(result.bytes)))"
            return item
        }
        item.state = result.elapsed < 8 ? .ok : .warning
        item.detail = "\(sizeText(result.bytes)) за \(secondsText(result.elapsed)), результатов: \(response.items.count)"
        return item
    }

    // MARK: Torrent network

    static func checkHTTPTracker(_ tracker: Tracker) async -> NetworkCheckItem {
        var item = NetworkCheckItem(id: tracker.id, group: .torrent, title: tracker.title)
        guard let url = announceURL(tracker.url, hash: speedHash) else { return item }
        let result = await HTTPProbe.run(URLRequest(url: url), idle: 10, total: 15, keepBody: 64 << 10)
        if let failure = failureText(result) {
            item.state = .failed
            item.detail = failure
            return item
        }
        guard result.status == 200 else {
            item.state = .warning
            item.detail = "доступен, но ответил HTTP \(result.status ?? 0)"
            return item
        }
        let answer = trackerAnswer(result.body)
        item.state = answer.state
        item.detail = answer.text + ", \(secondsText(result.elapsed))"
        return item
    }

    static func checkUDPTrackers() async -> NetworkCheckItem {
        let results = await withTaskGroup(of: UDPAnswer.self, returning: [UDPAnswer].self) { group in
            for tracker in udpTrackers {
                let host = tracker.host
                let port = tracker.port
                group.addTask {
                    let transaction = UInt32.random(in: 1...UInt32.max)
                    let reply = await UDPProbe.exchange(host: host, port: port,
                                                        payload: NetworkProbes.trackerConnect(transaction: transaction), timeout: 6)
                    guard let reply = reply, NetworkProbes.isConnectAnswer(reply.data, transaction: transaction) else {
                        return UDPAnswer(name: host, rtt: nil)
                    }
                    return UDPAnswer(name: host, rtt: reply.rtt)
                }
            }
            var list: [UDPAnswer] = []
            for await value in group { list.append(value) }
            return list
        }
        return udpSummary(id: "udp", title: "UDP-трекеры", results: results,
                          none: "нет ответа: UDP-трафик, похоже, блокируется")
    }

    static func checkDHT() async -> NetworkCheckItem {
        let results = await withTaskGroup(of: UDPAnswer.self, returning: [UDPAnswer].self) { group in
            for router in dhtRouters {
                let host = router.host
                let port = router.port
                group.addTask {
                    let reply = await UDPProbe.exchange(host: host, port: port, payload: NetworkProbes.dhtPing(), timeout: 6)
                    return UDPAnswer(name: host, rtt: reply?.rtt)
                }
            }
            var list: [UDPAnswer] = []
            for await value in group { list.append(value) }
            return list
        }
        return udpSummary(id: "dht", title: "DHT (поиск пиров без трекеров)", results: results,
                          none: "нет ответа: пиры находятся только через трекеры")
    }

    static func udpSummary(id: String, title: String, results: [UDPAnswer], none: String) -> NetworkCheckItem {
        let answered = results.filter { $0.rtt != nil }.count
        let state: NetworkCheckItem.State = answered == 0 ? .failed : (answered * 2 < results.count ? .warning : .ok)
        let list = results.sorted { $0.name < $1.name }
            .map { "\($0.name) " + ($0.rtt.map { secondsText($0) } ?? "—") }
            .joined(separator: ", ")
        let head = answered == 0 ? none : "ответили \(answered) из \(results.count)"
        return NetworkCheckItem(id: id, group: .torrent, title: title, state: state, detail: head + " (" + list + ")")
    }

    /// Reads the engine numbers once a second until cancelled.
    static func sample(hash: String, seconds: Int) async -> SpeedSample {
        var sample = SpeedSample()
        for _ in 0..<seconds {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                break
            }
            if let status = try? await TorrServer.shared.get(hash: hash) {
                sample.add(status)
            }
        }
        return sample
    }

    // MARK: Protocols

    /// An announce of the test torrent (the tracker answers with its peers).
    static func announceURL(_ base: String, hash: String) -> URL? {
        let hex = Array(hash.lowercased())
        guard hex.count == 40 else { return nil }
        var encoded = ""
        for index in stride(from: 0, to: 40, by: 2) {
            encoded += "%" + String(hex[index]) + String(hex[index + 1])
        }
        let peer = "-KT0900-" + String((0..<12).map { _ in "0123456789abcdef".randomElement() ?? "0" })
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: base + separator + "info_hash=\(encoded)&peer_id=\(peer)&port=6881&uploaded=0&downloaded=0&left=1000000&compact=1&numwant=50")
    }

    static func trackerAnswer(_ body: Data) -> (state: NetworkCheckItem.State, text: String) {
        let bytes = [UInt8](body)
        if let at = index(of: Array("14:failure reason".utf8), in: bytes) {
            let reason = bencodedString(bytes, at: at + 17).map { String(decoding: $0.value, as: UTF8.self) } ?? ""
            return (.warning, "доступен, ответ: «\(reason.prefix(80))»")
        }
        if let at = index(of: Array("5:peers".utf8), in: bytes) {
            let start = at + 7
            if start < bytes.count, bytes[start] == UInt8(ascii: "l") {
                return (.ok, "пиров в ответе: \(occurrences(Array("2:ip".utf8), in: bytes))")
            }
            if let peers = bencodedString(bytes, at: start) {
                return (.ok, "пиров в ответе: \(peers.length / 6)")
            }
        }
        if index(of: Array("8:interval".utf8), in: bytes) != nil {
            return (.ok, "отвечает")
        }
        return (.warning, "неожиданный ответ (\(bytes.count) байт)")
    }

    /// BEP 15 connect request.
    static func trackerConnect(transaction: UInt32) -> Data {
        bigEndian(UInt64(0x41727101980)) + bigEndian(UInt32(0)) + bigEndian(transaction)
    }

    static func isConnectAnswer(_ data: Data, transaction: UInt32) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return false }
        return uint32(bytes, at: 0) == 0 && uint32(bytes, at: 4) == transaction
    }

    /// BEP 5 ping query.
    static func dhtPing() -> Data {
        var data = Data("d1:ad2:id20:".utf8)
        data.append(contentsOf: (0..<20).map { _ in UInt8.random(in: 0...255) })
        data.append(contentsOf: Array("e1:q4:ping1:t2:kt1:y1:qe".utf8))
        return data
    }

    static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func uint32(_ bytes: [UInt8], at start: Int) -> UInt32 {
        bytes[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func index(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where bytes[start] == pattern[0] {
            if Array(bytes[start..<start + pattern.count]) == pattern { return start }
        }
        return nil
    }

    static func occurrences(_ pattern: [UInt8], in bytes: [UInt8]) -> Int {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return 0 }
        var count = 0
        for start in 0...(bytes.count - pattern.count) where bytes[start] == pattern[0] {
            if Array(bytes[start..<start + pattern.count]) == pattern { count += 1 }
        }
        return count
    }

    /// "12:abc…" at `start`: the declared length and the bytes present.
    static func bencodedString(_ bytes: [UInt8], at start: Int) -> (length: Int, value: [UInt8])? {
        var position = start
        var length = 0
        var digits = 0
        while position < bytes.count, digits < 9, bytes[position] >= 48, bytes[position] <= 57 {
            length = length * 10 + Int(bytes[position] - 48)
            position += 1
            digits += 1
        }
        guard digits > 0, position < bytes.count, bytes[position] == 58 else { return nil }
        position += 1
        let end = min(bytes.count, position + length)
        return (length, Array(bytes[position..<end]))
    }

    // MARK: Text

    /// Why the request failed, or nil when it did not.
    static func failureText(_ result: HTTPProbe.Result) -> String? {
        guard let code = result.errorCode else { return nil }
        let got = result.bytes > 0 ? " после \(sizeText(result.bytes))" : ""
        switch URLError.Code(rawValue: code) {
        case .timedOut:
            return result.bytes > 0
                ? "ответ оборвался\(got): данные перестали приходить (так операторы замедляют зарубежные серверы)"
                : "нет ответа (таймаут соединения)"
        case .cannotFindHost, .dnsLookupFailed:
            return "адрес сервера не найден (DNS)"
        case .cannotConnectToHost:
            return "сервер не принимает соединение"
        case .networkConnectionLost:
            return "связь оборвалась\(got)"
        case .notConnectedToInternet:
            return "нет интернета"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "ошибка защищённого соединения (TLS)" + got
        default:
            return (result.errorText ?? "ошибка \(code)") + got
        }
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    static func secondsText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) мс" }
        return seconds.formatted(.number.precision(.fractionLength(1))) + " с"
    }

    /// "2,4 МБ/с (19 Мбит/с)".
    static func rateText(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let megabits = value * 8 / 1_000_000
        return TSStatus.rateText(value) + " (" + megabits.formatted(.number.precision(.fractionLength(megabits < 10 ? 1 : 0))) + " Мбит/с)"
    }

    static func verdictState(_ bytesPerSecond: Double) -> NetworkCheckItem.State {
        if bytesPerSecond >= 1_500_000 { return .ok }
        if bytesPerSecond >= 600_000 { return .warning }
        return .failed
    }

    /// What the speed is enough for (typical bitrates of releases).
    static func verdict(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 6_000_000 { return "4K и всего остального" }
        if bytesPerSecond >= 2_500_000 { return "1080p, 4K — не всегда" }
        if bytesPerSecond >= 1_500_000 { return "1080p обычного размера, 720p" }
        if bytesPerSecond >= 600_000 { return "720p; 1080p будет подгружаться" }
        if bytesPerSecond > 0 { return "только лёгких раздач (SD); видео будет останавливаться" }
        return "ничего: данные не приходят"
    }
}

/// One HTTP request that counts what arrives, so a stalled answer still shows how much came.
final class HTTPProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable {
        var status: Int?
        var bytes: Int64 = 0
        /// Seconds from the start to the first byte of the body.
        var firstByte: TimeInterval?
        var elapsed: TimeInterval = 0
        /// Stopped on purpose (the byte or the time limit).
        var stopped = false
        /// URLError code when the request failed.
        var errorCode: Int?
        var errorText: String?
        var body = Data()
    }

    private let lock = NSLock()
    private var result = Result()
    private let started = Date()
    private let limit: Int64
    private let keepBody: Int
    private var continuation: CheckedContinuation<Result, Never>?
    private var task: URLSessionTask?
    private var stopRequested = false

    private init(limit: Int64, keepBody: Int) {
        self.limit = limit
        self.keepBody = keepBody
    }

    /// `idle`: fails when nothing arrives for so long; `total`: stops (without an error) after so long.
    static func run(_ request: URLRequest, idle: TimeInterval, total: TimeInterval, limit: Int64 = .max, keepBody: Int = 0) async -> Result {
        await HTTPProbe(limit: limit, keepBody: keepBody).start(request, idle: idle, total: total)
    }

    private func start(_ request: URLRequest, idle: TimeInterval, total: TimeInterval) async -> Result {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = idle
        config.timeoutIntervalForResource = total + idle + 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        var request = request
        request.timeoutInterval = idle
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.task = task
                let cancelled = stopRequested
                lock.unlock()
                task.resume()
                // The session keeps its delegate until it is invalidated.
                session.finishTasksAndInvalidate()
                if cancelled {
                    stop()
                } else {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + total) { [weak self] in
                        self?.stop()
                    }
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    private func stop() {
        lock.lock()
        stopRequested = true
        if continuation != nil { result.stopped = true }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if result.firstByte == nil { result.firstByte = Date().timeIntervalSince(started) }
        if result.status == nil { result.status = (dataTask.response as? HTTPURLResponse)?.statusCode }
        result.bytes += Int64(data.count)
        if result.body.count < keepBody {
            result.body.append(data.prefix(keepBody - result.body.count))
        }
        let reached = result.bytes >= limit
        lock.unlock()
        if reached { stop() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        result.elapsed = Date().timeIntervalSince(started)
        if result.status == nil { result.status = (task.response as? HTTPURLResponse)?.statusCode }
        if let error = error {
            let code = (error as? URLError)?.code.rawValue ?? URLError.Code.unknown.rawValue
            // Cancelled by the limits: the bytes counted so far are the result.
            if !(result.stopped && code == URLError.Code.cancelled.rawValue) {
                result.errorCode = code
                result.errorText = error.localizedDescription
            }
        }
        let value = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// One UDP datagram and the first answer to it (trackers, DHT).
final class UDPProbe: @unchecked Sendable {
    struct Reply: Sendable {
        let data: Data
        let rtt: TimeInterval
    }

    private let lock = NSLock()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "kinoteka.netcheck.udp")
    private let started = Date()
    private var continuation: CheckedContinuation<Reply?, Never>?

    private init?(host: String, port: UInt16) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
    }

    static func exchange(host: String, port: UInt16, payload: Data, timeout: TimeInterval) async -> Reply? {
        guard let probe = UDPProbe(host: host, port: port) else { return nil }
        return await probe.run(payload: payload, timeout: timeout)
    }

    private func run(payload: Data, timeout: TimeInterval) async -> Reply? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Reply?, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    self.connection.receiveMessage { data, _, _, _ in
                        if let data = data, !data.isEmpty {
                            self.finish(Reply(data: data, rtt: Date().timeIntervalSince(self.started)))
                        } else {
                            self.finish(nil)
                        }
                    }
                    self.connection.send(content: payload, completion: .contentProcessed { error in
                        if error != nil { self.finish(nil) }
                    })
                case .failed, .cancelled:
                    self.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                self.finish(nil)
            }
        }
    }

    private func finish(_ value: Reply?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending = pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: value)
    }
}
