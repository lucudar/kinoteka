import Foundation

// MARK: - TV channels from an M3U playlist

struct Channel: Codable, Hashable, Identifiable {
    var name: String
    var url: String
    var logo: String?
    var group: String?
    var userAgent: String? = nil
    var referrer: String? = nil

    var id: String { url }
}

enum M3UParser {
    static func parse(_ text: String) -> [Channel] {
        var result: [Channel] = []
        var seen = Set<String>()
        var name: String?
        var logo: String?
        var group: String?
        var userAgent: String?
        var referrer: String?

        func reset() {
            name = nil
            logo = nil
            group = nil
            userAgent = nil
            referrer = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmed
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                let attrs = attributes(in: line)
                logo = nonEmpty(attrs["tvg-logo"])
                group = nonEmpty(attrs["group-title"]) ?? group
                name = title(in: line) ?? nonEmpty(attrs["tvg-name"])
            } else if line.hasPrefix("#EXTGRP:") {
                group = nonEmpty(String(line.dropFirst(8)).trimmed)
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = String(line.dropFirst(11))
                if let value = optionValue(option, key: "http-user-agent") { userAgent = value }
                if let value = optionValue(option, key: "http-referrer") ?? optionValue(option, key: "http-referer") { referrer = value }
            } else if line.hasPrefix("#") {
                continue
            } else {
                if line.contains("://"), seen.insert(line).inserted {
                    let channelName = name ?? fallbackName(line)
                    result.append(Channel(name: channelName, url: line, logo: logo, group: group, userAgent: userAgent, referrer: referrer))
                }
                reset()
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let v = value?.trimmed, !v.isEmpty else { return nil }
        return v
    }

    private static func optionValue(_ option: String, key: String) -> String? {
        let prefix = key + "="
        guard option.lowercased().hasPrefix(prefix) else { return nil }
        return nonEmpty(String(option.dropFirst(prefix.count)))
    }

    static func attributes(in line: String) -> [String: String] {
        var dict: [String: String] = [:]
        for g in Rx.allGroups("([A-Za-z0-9_-]+)=\"([^\"]*)\"", in: line, caseSensitive: true) where g.count == 2 {
            dict[g[0].lowercased()] = g[1]
        }
        return dict
    }

    /// Channel name: text after the first comma that is not inside quotes.
    static func title(in line: String) -> String? {
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                return nonEmpty(String(line[line.index(after: index)...]))
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func fallbackName(_ url: String) -> String {
        URL(string: url)?.host ?? "Канал"
    }
}
