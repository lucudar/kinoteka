import Foundation

/// Public Jacred servers with the same database of releases.
///
/// jac.red is hosted abroad, and Russian mobile networks often slow connections to foreign
/// hosting down until a big answer (a search returns 300–400 KB) stalls. The mirrors hosted in
/// Russia answer there without a VPN, so the search asks them in turn when one does not answer.
enum SearchMirrors {
    static let primary = "https://jac.red"
    /// In the order they are asked; jac-red.ru is updated less often, so it is the last one.
    static let all = [primary, "https://jr.maxvol.pro", "https://jac-red.ru"]
    /// Hosted in Russia: asked first on a mobile network.
    static let domestic: Set<String> = ["jr.maxvol.pro", "jac-red.ru"]

    /// "jac.red/" → "jac.red".
    static func host(_ server: String) -> String? {
        guard let base = TorrentSearchQuery.normalizedServer(server),
              let host = URL(string: base)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// One of the public mirrors (an own Jackett or Jacred is never replaced by them).
    static func isBuiltIn(_ server: String) -> Bool {
        guard let host = host(server) else { return false }
        return all.contains { self.host($0) == host }
    }

    /// The mirror for the address ("jr.maxvol.pro/" → "https://jr.maxvol.pro").
    static func canonical(_ server: String) -> String? {
        guard let host = host(server) else { return nil }
        return all.first { self.host($0) == host }
    }

    /// The servers asked in turn. An own server is the only one. For the public Jacred:
    /// the one that answered when the others did not (`lastGood`), the mirror chosen in the
    /// settings, on a mobile network the up-to-date Russian mirror, then the rest in their order.
    static func order(configured: String, lastGood: String?, preferDomestic: Bool) -> [String] {
        guard let base = TorrentSearchQuery.normalizedServer(configured) else { return [] }
        guard let chosen = canonical(base) else { return [base] }
        var result: [String] = []
        func add(_ server: String?) {
            guard let server = server.flatMap(canonical), !result.contains(server) else { return }
            result.append(server)
        }
        add(lastGood)
        if chosen != primary { add(chosen) }
        if preferDomestic {
            add(all.first { domestic.contains(host($0) ?? "") })
        }
        for server in all { add(server) }
        return result
    }
}
