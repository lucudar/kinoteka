import Foundation

// MARK: - Links

enum LinkKind {
    case torrent
    case direct
}

enum LinkInspector {
    /// Added to .torrent download links whose address does not say so (for example Jackett
    /// "/dl/..." links). A URL fragment is never sent to the server, so the link keeps working.
    static let torrentMarker = "#torrent"

    static func isInfoHash(_ text: String) -> Bool {
        let s = text.trimmed
        return s.count == 40 && s.allSatisfy { $0.isHexDigit }
    }

    static func kind(of link: String) -> LinkKind {
        let s = link.trimmed
        let lower = s.lowercased()
        if lower.hasPrefix("magnet:") || isInfoHash(s) || lower.hasSuffix(torrentMarker) { return .torrent }
        if let url = URL(string: s), url.pathExtension.lowercased() == "torrent" { return .torrent }
        if lower.contains(".torrent?") { return .torrent }
        return .direct
    }

    /// Marks a search-result link as a torrent when it would otherwise look like a video link.
    static func markTorrent(_ link: String) -> String {
        let s = link.trimmed
        return kind(of: s) == .torrent ? s : s + torrentMarker
    }

    /// The link to hand to the torrent engine.
    static func stripMarker(_ link: String) -> String {
        let s = link.trimmed
        guard s.lowercased().hasSuffix(torrentMarker) else { return s }
        return String(s.dropLast(torrentMarker.count))
    }

    /// Lowercased info-hash of a magnet link or of a bare hash.
    static func infoHash(of link: String) -> String? {
        let s = link.trimmed
        if isInfoHash(s) { return s.lowercased() }
        guard s.lowercased().hasPrefix("magnet:"),
              let g = Rx.groups("xt=urn:btih:([a-z0-9]{32,40})", in: s),
              let hash = g.first, !hash.isEmpty else { return nil }
        return hash.lowercased()
    }

    static func isSupported(_ link: String) -> Bool {
        let s = link.trimmed
        if s.lowercased().hasPrefix("magnet:") || isInfoHash(s) { return true }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "rtmp", "rtsp", "rtp", "udp", "ftp", "smb", "mms"].contains(scheme)
    }

    static func kindText(_ link: String) -> String {
        switch kind(of: link) {
        case .torrent: return "Торрент"
        case .direct:
            let lower = link.lowercased()
            if lower.contains(".m3u8") { return "HLS-поток" }
            return "Прямая ссылка"
        }
    }
}

enum SourceNaming {
    static func defaultName(for link: String) -> String {
        let s = link.trimmed
        if s.lowercased().hasPrefix("magnet:") {
            if let comps = URLComponents(string: s),
               let dn = comps.queryItems?.first(where: { $0.name.lowercased() == "dn" })?.value,
               !dn.isEmpty {
                return dn.replacingOccurrences(of: "+", with: " ")
            }
            return "Торрент"
        }
        if LinkInspector.isInfoHash(s) {
            return "Торрент " + String(s.prefix(8)).lowercased()
        }
        if let url = URL(string: s) {
            let file = url.lastPathComponent
            let host = url.host ?? ""
            if !file.isEmpty && file != "/" {
                return host.isEmpty ? file : "\(file) · \(host)"
            }
            if !host.isEmpty { return host }
        }
        return "Источник"
    }
}
