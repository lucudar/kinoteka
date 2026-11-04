import Foundation

/// A programme of the guide of a built-in channel.
struct TVProgramme: Hashable, Sendable {
    let title: String
    let start: Date
    let end: Date

    /// 0…1: how much of the programme has been on the air.
    func progress(at date: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / total, 0), 1)
    }
}

/// The links of a stream in an answer of «Витрина ТВ» or of the playlist API of Первый канал.
struct TVStreamAnswer: Equatable, Sendable {
    var hls: [String]
    var mpd: [String]
    /// The country the service sees the viewer in ("RU", "US").
    var country: String?
}

/// Reading the answers of the TV services; the requests themselves are made by TVResolver.
enum TVParsing {
    /// The link of the balancer on a player page of «Витрина ТВ», with the placeholders that the
    /// player fills in replaced: the referer is vitrina.tv, the others stay empty.
    static func balancerURL(inPlayerPage html: String, fallbackEgress: String? = nil) -> URL? {
        let text = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
        let pattern = #"(https://media\.mediavitrina\.ru/balancer/v3/[\w-]+/[\w-]+/streams\.json[^"'\s<>\\]*)"#
        for groups in Rx.allGroups(pattern, in: text, caseSensitive: true) {
            guard let raw = groups.first, !raw.contains("PROGRAMME_ID") else { continue }
            if let url = filledBalancer(raw, fallbackEgress: fallbackEgress) { return url }
        }
        return nil
    }

    static func filledBalancer(_ template: String, fallbackEgress: String?) -> URL? {
        var link = template.replacingOccurrences(of: "{{PLAYER_REFERER_HOSTNAME}}", with: "vitrina.tv")
        link = link.replacingOccurrences(of: #"\{\{[A-Za-z0-9_]+\}\}"#, with: "", options: .regularExpression)
        guard var components = URLComponents(string: link) else { return nil }
        var items = (components.queryItems ?? []).filter { !$0.name.isEmpty }
        let hasEgress = items.contains { $0.name == "egress_version_id" && !($0.value ?? "").isEmpty }
        if !hasEgress, let egress = fallbackEgress, !egress.isEmpty {
            items.removeAll { $0.name == "egress_version_id" }
            items.append(URLQueryItem(name: "egress_version_id", value: egress))
        }
        components.queryItems = items
        return components.url
    }

    /// The current player page of every channel in the config of vitrina.tv, by `channel_slug`.
    static func playerPages(inConfig data: Data) -> [String: URL] {
        guard let root = json(data),
              let result = root["result"] as? [String: Any],
              let channels = result["channels"] as? [[String: Any]] else { return [:] }
        var pages: [String: URL] = [:]
        for channel in channels {
            guard let slug = channel["channel_slug"] as? String, pages[slug] == nil,
                  let link = channel["web_player_url"] as? String,
                  let url = URL(string: link) else { continue }
            pages[slug] = url
        }
        return pages
    }

    /// {"country": "RU", "hls": ["…"], "mpd": ["…"]} — nil when there is no link at all.
    static func streamAnswer(_ data: Data) -> TVStreamAnswer? {
        guard let root = json(data) else { return nil }
        func links(_ key: String) -> [String] {
            if let list = root[key] as? [String] { return list.filter { !$0.isEmpty } }
            if let one = root[key] as? String, !one.isEmpty { return [one] }
            return []
        }
        let answer = TVStreamAnswer(hls: links("hls"), mpd: links("mpd"), country: root["country"] as? String)
        return answer.hls.isEmpty && answer.mpd.isEmpty ? nil : answer
    }

    /// Outside Russia «Витрина ТВ» gives a video with a notice instead of the federal channels.
    static func isGeoStub(_ link: String) -> Bool {
        link.lowercased().contains("georestriction")
    }

    /// The beginning of an HLS playlist or of a DASH manifest.
    static func looksLikeStream(_ data: Data) -> Bool {
        var text = String(decoding: data.prefix(4096), as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("#EXTM3U") || head.contains("<MPD")
    }

    /// The programmes of the day, sorted by the start.
    static func programmes(_ data: Data) -> [TVProgramme] {
        guard let root = json(data) else { return [] }
        let list = (root["programmes"] as? [[String: Any]])
            ?? ((root["result"] as? [String: Any])?["programmes"] as? [[String: Any]])
            ?? []
        var result: [TVProgramme] = []
        for item in list {
            guard let raw = item["title"] as? String,
                  let begin = seconds(item["begin_ts"]), let end = seconds(item["end_ts"]), end > begin else { continue }
            let title = programmeTitle(raw)
            guard !title.isEmpty else { continue }
            result.append(TVProgramme(title: title, start: Date(timeIntervalSince1970: begin),
                                      end: Date(timeIntervalSince1970: end)))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// "Новости. 16+" → "Новости": the age rating and the final full stop are dropped.
    static func programmeTitle(_ raw: String) -> String {
        var title = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        title = title.replacingOccurrences(of: #"\s*[\(\[]?\d{1,2}\+[\)\]]?\.?$"#, with: "", options: .regularExpression)
        title = title.trimmed
        if title.hasSuffix("."), !title.hasSuffix("..") { title.removeLast() }
        return title.trimmed
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return TimeInterval(text) }
        return nil
    }

    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: gunzipIfNeeded(data)) as? [String: Any]
    }

    /// Some servers of «Витрина ТВ» send a gzip file without saying so in the headers, and
    /// URLSession then gives the compressed bytes.
    static func gunzipIfNeeded(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return data }
        #if canImport(Darwin)
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return data }
            index += 2 + (Int(bytes[index]) | Int(bytes[index + 1]) << 8)
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        // The deflate stream without the header and the 8 bytes of CRC and size at the end.
        guard index < bytes.count - 8 else { return data }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) else { return data }
        return inflated as Data
        #else
        return data
        #endif
    }
}
